defmodule AdButler.Workers.BudgetLeakAuditorWorker do
  @moduledoc """
  Oban worker that audits a single ad account for budget leak signals.

  Runs 5 heuristics against the last 48 hours of insights data, deduplicates
  findings by `(ad_id, kind)` while unresolved, and inserts an `AdHealthScore`
  row for every ad processed (even when no heuristic fires).

  Enqueued by `AuditSchedulerWorker` once per active ad account every 6 hours.
  """
  use Oban.Worker,
    queue: :audit,
    max_attempts: 3,
    unique: [period: 21_600, fields: [:args, :queue, :worker], keys: [:ad_account_id]]

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

  require Logger

  alias AdButler.Ads
  alias AdButler.Analytics

  @weights %{
    "dead_spend" => 40,
    "cpa_explosion" => 35,
    "bot_traffic" => 15,
    "placement_drag" => 7,
    "stalled_learning" => 3
  }

  @doc "Audits the ad account identified by `ad_account_id` for budget leak signals."
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"ad_account_id" => ad_account_id}}) do
    case Ads.unsafe_get_ad_account_for_sync(ad_account_id) do
      nil ->
        Logger.warning("budget_leak_auditor: ad_account not found, skipping",
          ad_account_id: ad_account_id
        )

        :ok

      ad_account ->
        audit_account(ad_account)
    end
  end

  # ---------------------------------------------------------------------------
  # Private — main audit flow
  # ---------------------------------------------------------------------------

  defp audit_account(ad_account) do
    insights = Ads.unsafe_list_insights_since(ad_account.id, 48)
    grouped = Enum.group_by(insights, & &1.ad_id)
    ad_set_map = Ads.unsafe_build_ad_set_map(ad_account.id)
    stalled_ad_sets = Ads.unsafe_list_stalled_learning_ad_set_ids(ad_account.id)
    baselines = Ads.unsafe_list_30d_baselines(Map.keys(grouped))

    with {:ok, detected_by_ad} <-
           run_all_heuristics(grouped, ad_account.id, ad_set_map, stalled_ad_sets, baselines),
         :ok <- insert_health_scores(detected_by_ad, ad_account.id) do
      Logger.info("budget_leak_auditor complete",
        ad_account_id: ad_account.id,
        ads_audited: map_size(detected_by_ad)
      )

      :ok
    else
      {:error, reason} ->
        Logger.error("budget_leak_auditor: audit failed",
          ad_account_id: ad_account.id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp insert_health_scores(detected_by_ad, _ad_account_id) when map_size(detected_by_ad) == 0,
    do: :ok

  defp insert_health_scores(detected_by_ad, _ad_account_id) do
    bucket = six_hour_bucket()
    now = DateTime.utc_now()

    entries =
      Enum.map(detected_by_ad, fn {ad_id, detected_kinds} ->
        score = compute_leak_score(detected_kinds)

        %{
          id: Ecto.UUID.generate(),
          ad_id: ad_id,
          computed_at: bucket,
          # Repo.insert_all bypasses Ecto changeset — Decimal.new/1 needed for the decimal column.
          # Score is capped 0..100 by compute_leak_score/1 so validate_number is not needed here.
          leak_score: Decimal.new(score),
          leak_factors: Map.new(detected_kinds, &{&1, Map.get(@weights, &1, 0)}),
          inserted_at: now
        }
      end)

    Analytics.bulk_insert_health_scores(entries)
  end

  defp run_all_heuristics(grouped, ad_account_id, ad_set_map, stalled_ad_sets, baselines) do
    ad_ids = Map.keys(grouped)
    open_findings = Analytics.unsafe_list_open_finding_keys(ad_ids)

    Enum.reduce_while(grouped, {:ok, %{}}, fn {ad_id, rows}, {:ok, acc} ->
      case run_heuristics(
             ad_id,
             rows,
             ad_account_id,
             ad_set_map,
             stalled_ad_sets,
             baselines,
             open_findings
           ) do
        {:ok, fired} -> {:cont, {:ok, Map.put(acc, ad_id, fired)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp run_heuristics(
         ad_id,
         rows,
         ad_account_id,
         ad_set_map,
         stalled_ad_sets,
         baselines,
         open_findings
       ) do
    checks = [
      {"dead_spend", check_dead_spend(ad_id, rows, ad_account_id)},
      {"cpa_explosion", check_cpa_explosion(ad_id, rows, ad_account_id, baselines)},
      {"bot_traffic", check_bot_traffic(ad_id, rows, ad_account_id)},
      {"placement_drag", check_placement_drag(ad_id, rows, ad_account_id, ad_set_map)},
      {"stalled_learning",
       check_stalled_learning(ad_id, rows, ad_account_id, ad_set_map, stalled_ad_sets)}
    ]

    Enum.reduce_while(checks, {:ok, []}, fn {kind, result}, {:ok, acc} ->
      apply_check(kind, result, acc, ad_id, open_findings)
    end)
  end

  defp apply_check(_kind, :skip, acc, _ad_id, _open_findings), do: {:cont, {:ok, acc}}

  defp apply_check(kind, {:emit, attrs}, acc, ad_id, open_findings) do
    case maybe_emit_finding(ad_id, kind, attrs, open_findings) do
      # Both newly-created and already-open findings count toward the health score signal.
      {:ok, _} -> {:cont, {:ok, [kind | acc]}}
      :skipped -> {:cont, {:ok, [kind | acc]}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Private — heuristics
  # ---------------------------------------------------------------------------

  # Heuristic 1: Dead Spend
  # Trigger: spend > $5 AND conversions == 0 AND reach uplift < 5% of max_reach
  defp check_dead_spend(ad_id, rows, ad_account_id) do
    total_spend = Enum.sum(Enum.map(rows, & &1.spend_cents))
    total_conversions = Enum.sum(Enum.map(rows, & &1.conversions))
    reaches = Enum.map(rows, & &1.reach_count)
    max_reach = Enum.max(reaches, fn -> 0 end)
    min_reach = Enum.min(reaches, fn -> 0 end)
    reach_uplift = max_reach - min_reach

    if total_spend > 500 and total_conversions == 0 and
         (max_reach == 0 or reach_uplift < max_reach * 0.05) do
      dollars = div(total_spend, 100)
      cents = rem(total_spend, 100) |> abs()
      spend_str = "$#{dollars}.#{String.pad_leading(Integer.to_string(cents), 2, "0")}"

      {:emit,
       %{
         ad_id: ad_id,
         ad_account_id: ad_account_id,
         kind: "dead_spend",
         severity: "high",
         title: "Dead spend detected",
         body: "Ad has spent #{spend_str} with zero conversions in 48 hours",
         evidence: %{spend_cents: total_spend, period_hours: 48, conversions: 0}
       }}
    else
      :skip
    end
  end

  # Heuristic 2: CPA Explosion
  # Trigger: 3-day CPA > 2.5x 30-day baseline AND conversions > 0 AND baseline > 0
  defp check_cpa_explosion(ad_id, rows, ad_account_id, baselines) do
    spend_3d = Enum.sum(Enum.map(rows, & &1.spend_cents))
    conversions_3d = Enum.sum(Enum.map(rows, & &1.conversions))
    baseline = Map.get(baselines, ad_id)

    cond do
      conversions_3d == 0 ->
        :skip

      baseline == nil ->
        :skip

      not (is_integer(baseline.cpa_cents) and baseline.cpa_cents > 0) ->
        :skip

      true ->
        baseline_cpa = baseline.cpa_cents
        cpa_3d = div(spend_3d, conversions_3d)

        # Integer multiplication avoids float — equivalent to cpa_3d / baseline_cpa > 2.5
        if cpa_3d * 10 > baseline_cpa * 25 do
          ratio = Float.round(cpa_3d / baseline_cpa, 2)

          {:emit,
           %{
             ad_id: ad_id,
             ad_account_id: ad_account_id,
             kind: "cpa_explosion",
             severity: "high",
             title: "CPA explosion detected",
             body: "3-day CPA is #{Float.round(ratio, 1)}x the 30-day baseline",
             evidence: %{cpa_3d_cents: cpa_3d, cpa_30d_cents: baseline_cpa, ratio: ratio}
           }}
        else
          :skip
        end
    end
  end

  # Heuristic 3: Bot-shaped Traffic
  # Trigger: CTR > 5% AND conversion_rate < 0.3% AND dominant placement is risky
  # Guard: impressions < 1000 → skip (not enough data)
  defp check_bot_traffic(ad_id, rows, ad_account_id) do
    total_impressions = Enum.sum(Enum.map(rows, & &1.impressions))

    if total_impressions < 1000 do
      :skip
    else
      total_clicks = Enum.sum(Enum.map(rows, & &1.clicks))
      total_conversions = Enum.sum(Enum.map(rows, & &1.conversions))

      dominant = dominant_placement(rows)
      risky_placement = dominant in ["audience_network", "reels"]

      # Integer comparisons — equivalent to ctr > 0.05 and conversion_rate < 0.003
      if total_clicks * 100 > total_impressions * 5 and
           total_conversions * 1000 < total_clicks * 3 and
           risky_placement do
        ctr = Float.round(total_clicks / total_impressions, 4)
        conversion_rate = Float.round(total_conversions / total_clicks, 4)

        {:emit,
         %{
           ad_id: ad_id,
           ad_account_id: ad_account_id,
           kind: "bot_traffic",
           severity: "medium",
           title: "Bot-shaped traffic detected",
           body: "High CTR with very low conversion rate on #{dominant} placement",
           evidence: %{
             ctr: ctr,
             conversion_rate: conversion_rate,
             dominant_placement: dominant
           }
         }}
      else
        :skip
      end
    end
  end

  # Heuristic 4: Placement Drag
  # Trigger: max(placement_cpa) / min(placement_cpa) > 3x across placement groups
  defp check_placement_drag(ad_id, rows, ad_account_id, ad_set_map) do
    with ad_set_id when ad_set_id != nil <- Map.get(ad_set_map, ad_id),
         [_, _ | _] = placements <- aggregate_placement_cpas(rows) do
      cpas = Enum.map(placements, &elem(&1, 1))
      max_cpa = Enum.max(cpas)
      min_cpa = Enum.min(cpas)

      # Integer comparison — equivalent to max_cpa / min_cpa > 3
      if min_cpa > 0 and max_cpa * 10 > min_cpa * 30 do
        {best_name, _} = Enum.min_by(placements, &elem(&1, 1))
        {worst_name, _} = Enum.max_by(placements, &elem(&1, 1))

        {:emit,
         %{
           ad_id: ad_id,
           ad_account_id: ad_account_id,
           kind: "placement_drag",
           severity: "medium",
           title: "Placement drag detected",
           body:
             "#{worst_name} placement has #{Float.round(max_cpa / min_cpa, 1)}x higher CPA than #{best_name}",
           evidence: %{
             best_placement: best_name,
             best_cpa: min_cpa,
             worst_placement: worst_name,
             worst_cpa: max_cpa
           }
         }}
      else
        :skip
      end
    else
      _ -> :skip
    end
  end

  defp aggregate_placement_cpas(rows) do
    rows
    |> Enum.flat_map(fn row ->
      case row.by_placement_jsonb do
        map when is_map(map) -> Map.to_list(map)
        _ -> []
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {name, entries} ->
      spend = Enum.sum(Enum.map(entries, &(Map.get(&1, "spend_cents") || 0)))
      conversions = Enum.sum(Enum.map(entries, &(Map.get(&1, "conversions") || 0)))
      cpa = if conversions > 0, do: div(spend, conversions), else: nil
      {name, cpa}
    end)
    |> Enum.filter(fn {_, cpa} -> cpa != nil end)
  end

  # Heuristic 5: Stalled Learning
  # Trigger: ad_set in LEARNING > 7 days AND conversions < 50 in 7d
  defp check_stalled_learning(ad_id, rows, ad_account_id, ad_set_map, stalled_ad_sets) do
    ad_set_id = Map.get(ad_set_map, ad_id)

    if ad_set_id != nil and MapSet.member?(stalled_ad_sets, ad_set_id) do
      conversions_7d = Enum.sum(Enum.map(rows, & &1.conversions))

      if conversions_7d < 50 do
        {:emit,
         %{
           ad_id: ad_id,
           ad_account_id: ad_account_id,
           kind: "stalled_learning",
           severity: "low",
           title: "Stalled learning phase",
           body:
             "Ad set has been in LEARNING for over 7 days with only #{conversions_7d} conversions",
           evidence: %{ad_set_id: ad_set_id, conversions_7d: conversions_7d}
         }}
      else
        :skip
      end
    else
      :skip
    end
  end

  # ---------------------------------------------------------------------------
  # Private — deduplication + emission
  # ---------------------------------------------------------------------------

  defp maybe_emit_finding(ad_id, kind, attrs, open_findings) do
    # open_findings MapSet is a performance optimization — avoids per-finding SELECT.
    # The partial unique index `findings_ad_id_kind_unresolved_index` (migration
    # 20260427000002) remains the authoritative dedup guard for concurrent workers.
    if MapSet.member?(open_findings, {ad_id, kind}) do
      :skipped
    else
      case Analytics.create_finding(attrs) do
        {:ok, finding} ->
          Logger.info("finding created", ad_id: ad_id, kind: kind, finding_id: finding.id)
          {:ok, finding}

        {:error, reason} ->
          Logger.error("finding creation failed",
            ad_id: ad_id,
            kind: kind,
            reason: inspect(reason)
          )

          {:error, reason}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private — scoring
  # ---------------------------------------------------------------------------

  defp compute_leak_score(detected_kinds) do
    detected_kinds
    |> Enum.map(&Map.get(@weights, &1, 0))
    |> Enum.sum()
    |> min(100)
  end

  # ---------------------------------------------------------------------------
  # Private — helpers
  # ---------------------------------------------------------------------------

  defp dominant_placement(rows) do
    rows
    |> Enum.flat_map(&placement_impressions/1)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {name, counts} -> {name, Enum.sum(counts)} end)
    |> Enum.max_by(&elem(&1, 1), fn -> {"unknown", 0} end)
    |> elem(0)
  end

  defp placement_impressions(%{by_placement_jsonb: map}) when is_map(map) do
    Enum.map(map, fn {name, data} -> {name, Map.get(data, "impressions") || 0} end)
  end

  defp placement_impressions(_), do: []

  defp six_hour_bucket do
    now = DateTime.utc_now()
    bucket_hour = div(now.hour, 6) * 6
    DateTime.new!(DateTime.to_date(now), Time.new!(bucket_hour, 0, 0, 0))
  end
end
