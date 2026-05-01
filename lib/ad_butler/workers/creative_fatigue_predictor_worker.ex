defmodule AdButler.Workers.CreativeFatiguePredictorWorker do
  @moduledoc """
  Oban worker that scores a single ad account for creative fatigue.

  Mirrors `BudgetLeakAuditorWorker`: enqueued once per active ad account every 6
  hours by `AuditSchedulerWorker`, idempotent within that window via
  `unique`, dedups findings on `(ad_id, kind)` while unresolved, and writes a
  fatigue row to `ad_health_scores` for each ad inspected.

  Heuristics are filled in across W7D2–W7D4 plus the W8D2 predictive layer:

    * `heuristic_frequency_ctr_decay/1` — frequency > 3.5 AND ctr_slope < -0.1 (W7D2)
    * `heuristic_quality_drop/1` — quality_ranking dropped within 7d (W7D3)
    * `heuristic_cpm_saturation/1` — 7d/prior-7d CPM change > 20% (W7D4)
    * `heuristic_predicted_fatigue/1` — regression-based forecast: r² >= 0.5 AND
      projected_ctr_3d < 0.6 × honeymoon baseline (W8D2)

  The predictive layer carries weight 25 — below the 50 finding threshold on its
  own, so it requires at least one present-tense heuristic to combine with
  before a finding is emitted. When the predictive signal contributes to a
  finding, the title is prefixed with "Predicted fatigue:" and `evidence.predicted`
  is set to `true` with `evidence.forecast_window_end` pinned to today + 3 days.
  """
  use Oban.Worker,
    queue: :fatigue_audit,
    max_attempts: 3,
    unique: [period: 21_600, fields: [:args, :queue, :worker], keys: [:ad_account_id]]

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

  require Logger

  alias AdButler.Ads
  alias AdButler.Analytics
  alias AdButler.Workers.AuditHelpers

  # Findings are created when the combined fatigue score crosses this floor.
  @finding_threshold 50

  # Frequency threshold above which the audience is judged saturated. Conservative —
  # Meta's own dashboards flag > 4 as a warning. Lower threshold to widen recall.
  @frequency_threshold 3.5
  # CTR slope threshold in percentage-points per day. -0.1 pp/day = ~0.7 pp drop over
  # 7 days, which is a meaningful decline for most CTR baselines.
  @ctr_slope_threshold -0.1

  # Weights — sum capped at 100 by `compute_fatigue_score/1` in W7D4-T3.
  # Kept at module scope so the Findings body renderer (W7D5-T2) can introspect.
  @weights %{
    "frequency_ctr_decay" => 35,
    "quality_drop" => 30,
    "cpm_saturation" => 25,
    "predicted_fatigue" => 25
  }

  # Predictive layer thresholds (W8D2). r² gate keeps weak fits out — a slope on
  # noise still has a slope. CTR-drop gate triggers when the projected CTR falls
  # below 60% of the ad's honeymoon baseline — anchored on a per-ad history rather
  # than an absolute floor so high-CTR and low-CTR ads use comparable bars.
  @predicted_r_squared_threshold 0.5
  @predicted_ctr_drop_ratio 0.6
  @predicted_forecast_days 3

  @doc "Returns the per-heuristic weight map."
  @spec weights() :: %{String.t() => non_neg_integer()}
  def weights, do: @weights

  @doc "Audits the ad account identified by `ad_account_id` for creative fatigue signals."
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"ad_account_id" => ad_account_id}}) do
    case Ads.unsafe_get_ad_account_for_sync(ad_account_id) do
      nil ->
        Logger.warning("creative_fatigue_predictor: ad_account not found, skipping",
          ad_account_id: ad_account_id
        )

        :ok

      ad_account ->
        audit_account(ad_account)
    end
  end

  # ---------------------------------------------------------------------------
  # Heuristic — frequency + CTR decay (W7D2)
  # ---------------------------------------------------------------------------

  @doc """
  Heuristic 1: returns `{:emit, factors}` when 7d avg frequency exceeds the
  saturation threshold AND the 7d CTR slope is decaying past the threshold.

  Returns `:skip` when either signal is below threshold or `get_7d_frequency/1`
  finds no usable data (ad never ran, or every day had nil/0 frequency).

  Factors map carries the actual computed values for downstream evidence
  rendering. The numeric thresholds live as module attributes — bumping them is
  a one-line review.
  """
  @spec heuristic_frequency_ctr_decay(binary()) ::
          {:emit, %{frequency: float(), ctr_slope: float()}} | :skip
  def heuristic_frequency_ctr_decay(ad_id) do
    case Analytics.get_7d_frequency(ad_id) do
      nil ->
        :skip

      freq when freq > @frequency_threshold ->
        slope = Analytics.compute_ctr_slope(ad_id, 7)

        if slope < @ctr_slope_threshold do
          {:emit, %{frequency: freq, ctr_slope: slope}}
        else
          :skip
        end

      _freq ->
        :skip
    end
  end

  # ---------------------------------------------------------------------------
  # Heuristic — quality ranking drop (W7D3)
  # ---------------------------------------------------------------------------

  # Meta's quality_ranking enum, ordered most→least desirable. A move from a
  # better tier to a worse tier within the lookback window fires the heuristic.
  @ranking_order %{
    "above_average" => 3,
    "average" => 2,
    "below_average_35_percent" => 1,
    "below_average_20_percent" => 1,
    "below_average_10_percent" => 1,
    "unknown" => nil
  }
  @quality_drop_lookback_days 7

  @doc """
  Heuristic 2: returns `{:emit, factors}` when the latest `quality_ranking` is
  below an earlier ranking captured within the last #{@quality_drop_lookback_days}
  days. Earlier rankings of `nil` / `"unknown"` are ignored (Meta hadn't computed
  the tier yet).

  Factors include the original tier, the current tier, and the original date.
  """
  @spec heuristic_quality_drop(binary()) ::
          {:emit, %{from: String.t(), to: String.t(), from_date: String.t()}} | :skip
  def heuristic_quality_drop(ad_id) do
    snapshots = Ads.unsafe_get_quality_ranking_history(ad_id)
    detect_quality_drop(snapshots)
  end

  defp detect_quality_drop([]), do: :skip
  defp detect_quality_drop([_]), do: :skip

  defp detect_quality_drop(snapshots) do
    cutoff = Date.add(Date.utc_today(), -@quality_drop_lookback_days)
    [latest | older] = Enum.reverse(snapshots)
    latest_rank = latest["quality_ranking"]
    latest_score = Map.get(@ranking_order, latest_rank)

    if is_nil(latest_score) do
      :skip
    else
      find_drop(latest_rank, latest_score, older, cutoff)
    end
  end

  defp find_drop(_latest_rank, _latest_score, [], _cutoff), do: :skip

  # Caller passes `older` from `Enum.reverse(snapshots)`, so it is ordered
  # newest-to-oldest. Once a snapshot falls before the cutoff window, all
  # subsequent ones do too — early-`:skip` is safe.
  defp find_drop(latest_rank, latest_score, [snapshot | rest], cutoff) do
    rank = snapshot["quality_ranking"]
    score = Map.get(@ranking_order, rank)
    snap_date = parse_iso_date(snapshot["date"])

    cond do
      score == nil ->
        find_drop(latest_rank, latest_score, rest, cutoff)

      snap_date == nil or Date.compare(snap_date, cutoff) == :lt ->
        :skip

      score > latest_score ->
        {:emit,
         %{
           from: rank,
           to: latest_rank,
           from_date: snapshot["date"]
         }}

      true ->
        find_drop(latest_rank, latest_score, rest, cutoff)
    end
  end

  defp parse_iso_date(nil), do: nil

  defp parse_iso_date(date) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, d} -> d
      _ -> nil
    end
  end

  defp parse_iso_date(_), do: nil

  # ---------------------------------------------------------------------------
  # Heuristic — CPM saturation (W7D4)
  # ---------------------------------------------------------------------------

  @cpm_change_threshold_pct 20.0

  @doc """
  Heuristic 3: returns `{:emit, %{cpm_change_pct: float()}}` when the most
  recent 7-day CPM is more than #{@cpm_change_threshold_pct}% higher than the
  prior 7-day window. `:skip` when either window lacks spend/impressions.
  """
  @spec heuristic_cpm_saturation(binary()) :: {:emit, %{cpm_change_pct: float()}} | :skip
  def heuristic_cpm_saturation(ad_id) do
    case Analytics.get_cpm_change_pct(ad_id) do
      nil -> :skip
      pct when pct > @cpm_change_threshold_pct -> {:emit, %{cpm_change_pct: pct}}
      _ -> :skip
    end
  end

  # ---------------------------------------------------------------------------
  # Heuristic — predictive regression (W8D2)
  # ---------------------------------------------------------------------------

  @doc """
  Heuristic 4: returns `{:emit, factors}` when `Analytics.fit_ctr_regression/1`
  produces an r² of at least #{@predicted_r_squared_threshold} and the projected
  3-day-out CTR falls below #{Float.round(@predicted_ctr_drop_ratio * 100, 0)}%
  of the ad's honeymoon baseline.

  Returns `:skip` whenever either input is `:insufficient_data` (fewer than 10
  usable days, or singular feature matrix), or when one of the gates fails.

  Factors carry the slope, projected CTR, baseline CTR, r², and the iso8601
  forecast window end so finding evidence can render the projection without
  re-running the regression.
  """
  @spec heuristic_predicted_fatigue(binary()) ::
          {:emit,
           %{
             slope_per_day: float(),
             projected_ctr_3d: float(),
             baseline_ctr: float(),
             r_squared: float(),
             forecast_window_end: String.t()
           }}
          | :skip
  def heuristic_predicted_fatigue(ad_id) do
    decide_predicted(
      Analytics.fit_ctr_regression(ad_id),
      Analytics.get_ad_honeymoon_baseline(ad_id)
    )
  end

  @doc """
  Same as `heuristic_predicted_fatigue/1` but operates on a pre-fetched 14-day
  slice of `insights_daily` rows. Used by `audit_account/1` after a single
  bulk fetch to collapse the per-ad N+1.
  """
  @spec heuristic_predicted_fatigue(binary(), [map()]) ::
          {:emit, map()} | :skip
  def heuristic_predicted_fatigue(ad_id, rows) when is_list(rows) do
    decide_predicted(
      Analytics.fit_ctr_regression(ad_id, rows),
      Analytics.get_ad_honeymoon_baseline(ad_id, rows)
    )
  end

  defp decide_predicted({:ok, regression}, {:ok, baseline}) do
    drop_threshold = baseline.baseline_ctr * @predicted_ctr_drop_ratio

    if regression.r_squared >= @predicted_r_squared_threshold and
         regression.projected_ctr_3d < drop_threshold do
      forecast_end = Date.add(Date.utc_today(), @predicted_forecast_days)

      {:emit,
       %{
         slope_per_day: regression.slope_per_day,
         projected_ctr_3d: regression.projected_ctr_3d,
         baseline_ctr: baseline.baseline_ctr,
         r_squared: regression.r_squared,
         forecast_window_end: Date.to_iso8601(forecast_end)
       }}
    else
      :skip
    end
  end

  defp decide_predicted(_, _), do: :skip

  # ---------------------------------------------------------------------------
  # Private — main audit flow
  # ---------------------------------------------------------------------------

  defp audit_account(ad_account) do
    ad_ids = Ads.unsafe_list_ad_ids_for_account(ad_account.id)
    open_findings = Analytics.unsafe_list_open_finding_keys(ad_ids)
    insights_by_ad = Analytics.unsafe_list_insights_window_for_ads(ad_ids, 14)
    bucket = AuditHelpers.six_hour_bucket()

    case build_entries(ad_ids, ad_account.id, open_findings, insights_by_ad, bucket) do
      {:ok, entries} ->
        Analytics.bulk_insert_fatigue_scores(entries)

        Logger.info("creative_fatigue_predictor complete",
          ad_account_id: ad_account.id,
          ads_audited: length(ad_ids),
          ads_with_signals: length(entries)
        )

        :ok

      {:error, reason} ->
        Logger.error("creative_fatigue_predictor: audit failed",
          ad_account_id: ad_account.id,
          reason: reason
        )

        {:error, reason}
    end
  end

  # Mirrors `BudgetLeakAuditorWorker.apply_check/5`: a `{:error, reason}` from
  # `maybe_emit_finding/5` halts and propagates so Oban retries the whole batch.
  # Score entries are still emitted on `:skipped` (dedup) — the upsert is idempotent
  # so retries do not lose score data.
  defp build_entries(ad_ids, ad_account_id, open_findings, insights_by_ad, bucket) do
    Enum.reduce_while(ad_ids, {:ok, []}, fn ad_id, {:ok, acc} ->
      ad_rows = Map.get(insights_by_ad, ad_id, [])

      case audit_one_ad(ad_id, ad_account_id, open_findings, ad_rows, bucket) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp audit_one_ad(ad_id, ad_account_id, open_findings, ad_rows, bucket) do
    case run_all_heuristics(ad_id, ad_rows) do
      [] ->
        {:ok, nil}

      triggered ->
        score = compute_fatigue_score(triggered)
        factors = build_factors_map(triggered)
        metadata = build_metadata(ad_id, ad_rows)

        case maybe_emit_finding(ad_id, ad_account_id, score, factors, open_findings) do
          {:error, reason} ->
            {:error, reason}

          _ok_or_skipped ->
            {:ok, build_entry(ad_id, score, factors, metadata, bucket)}
        end
    end
  end

  # Always populates `:metadata` so `bulk_insert_fatigue_scores/1`'s
  # unconditional `:metadata` replace doesn't clear the cached honeymoon
  # baseline (W2). When the baseline can't be derived, we still write `%{}`
  # so a future run can populate it without first having to deal with `nil`.
  defp build_metadata(ad_id, ad_rows) do
    case Analytics.get_ad_honeymoon_baseline(ad_id, ad_rows) do
      {:ok, baseline} ->
        %{
          "honeymoon_baseline" => %{
            "baseline_ctr" => baseline.baseline_ctr,
            "window_dates" => Enum.map(baseline.window_dates, &Date.to_iso8601/1)
          }
        }

      {:error, _} ->
        %{}
    end
  end

  defp build_entry(ad_id, score, factors, metadata, bucket) do
    %{
      id: Ecto.UUID.generate(),
      ad_id: ad_id,
      computed_at: bucket,
      fatigue_score: Decimal.new(score),
      fatigue_factors: factors,
      metadata: metadata,
      inserted_at: DateTime.utc_now()
    }
  end

  defp run_all_heuristics(ad_id, ad_rows) do
    [
      {"frequency_ctr_decay", heuristic_frequency_ctr_decay(ad_id)},
      {"quality_drop", heuristic_quality_drop(ad_id)},
      {"cpm_saturation", heuristic_cpm_saturation(ad_id)},
      {"predicted_fatigue", heuristic_predicted_fatigue(ad_id, ad_rows)}
    ]
    |> Enum.flat_map(fn
      {kind, {:emit, factors}} -> [{kind, factors}]
      {_kind, :skip} -> []
    end)
  end

  defp compute_fatigue_score(triggered) do
    triggered
    |> Enum.map(fn {kind, _factors} -> Map.get(@weights, kind, 0) end)
    |> Enum.sum()
    |> min(100)
  end

  defp build_factors_map(triggered) do
    Map.new(triggered, fn {kind, factors} ->
      stringified = Map.new(factors, fn {k, v} -> {to_string(k), v} end)
      {kind, %{"weight" => Map.get(@weights, kind, 0), "values" => stringified}}
    end)
  end

  defp maybe_emit_finding(ad_id, ad_account_id, score, factors, open_findings) do
    cond do
      score < @finding_threshold ->
        :skip

      MapSet.member?(open_findings, {ad_id, "creative_fatigue"}) ->
        # Dedup mirror of BudgetLeakAuditor — open finding already exists.
        :skipped

      true ->
        attrs = %{
          ad_id: ad_id,
          ad_account_id: ad_account_id,
          kind: "creative_fatigue",
          severity: severity_for_score(score),
          title: render_finding_title(factors),
          body: render_finding_body(factors),
          evidence: build_evidence(factors)
        }

        handle_create_result(Analytics.create_finding(attrs), ad_id)
    end
  end

  # When the predictive layer contributes, surface the projection at evidence
  # top level so consumers (Findings UI, chat tools) can render the forecast
  # without traversing the per-heuristic factor tree.
  defp build_evidence(factors) do
    case Map.get(factors, "predicted_fatigue") do
      %{"values" => %{"forecast_window_end" => end_date}} ->
        Map.merge(factors, %{
          "predicted" => true,
          "forecast_window_end" => end_date
        })

      _ ->
        factors
    end
  end

  defp render_finding_title(factors) do
    if Map.has_key?(factors, "predicted_fatigue") do
      "Predicted fatigue: ad showing fatigue signals"
    else
      "Ad showing fatigue signals"
    end
  end

  defp handle_create_result({:ok, finding}, ad_id) do
    Logger.info("finding created",
      ad_id: ad_id,
      kind: "creative_fatigue",
      finding_id: finding.id
    )

    {:ok, finding}
  end

  defp handle_create_result({:error, %Ecto.Changeset{} = changeset}, ad_id) do
    if AuditHelpers.dedup_constraint_error?(changeset) do
      # Concurrent worker raced past the MapSet pre-check — treat as dedup.
      :skipped
    else
      Logger.error("finding creation failed",
        ad_id: ad_id,
        kind: "creative_fatigue",
        reason: changeset.errors
      )

      {:error, changeset}
    end
  end

  defp handle_create_result({:error, reason}, ad_id) do
    Logger.error("finding creation failed",
      ad_id: ad_id,
      kind: "creative_fatigue",
      reason: reason
    )

    {:error, reason}
  end

  defp severity_for_score(score) when score >= 70, do: "high"
  defp severity_for_score(score) when score >= 50, do: "medium"
  defp severity_for_score(_), do: "low"

  defp render_finding_body(factors) do
    summary =
      factors
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map_join(", ", &format_factor_label/1)

    case Map.get(factors, "predicted_fatigue") do
      %{"values" => v} ->
        "Triggered heuristics: #{summary}. " <> format_predictive_clause(v)

      _ ->
        "Triggered heuristics: #{summary}"
    end
  end

  defp format_predictive_clause(values) do
    proj = Map.get(values, "projected_ctr_3d")
    base = Map.get(values, "baseline_ctr")
    r2 = Map.get(values, "r_squared")
    end_date = Map.get(values, "forecast_window_end")

    "Forecast: CTR projected to #{format_pct(proj, 3)} by #{end_date} " <>
      "vs honeymoon baseline #{format_pct(base, 3)} (r² #{format_pct(r2 || 0.0, 2)})."
  end

  defp format_pct(nil, _), do: "n/a"
  defp format_pct(value, decimals), do: "#{Float.round(value * 100, decimals)}%"

  defp format_factor_label("frequency_ctr_decay"), do: "frequency + CTR decay"
  defp format_factor_label("quality_drop"), do: "quality ranking drop"
  defp format_factor_label("cpm_saturation"), do: "CPM saturation"
  defp format_factor_label("predicted_fatigue"), do: "predictive regression"
  defp format_factor_label(other), do: other
end
