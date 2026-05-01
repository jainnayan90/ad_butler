defmodule AdButler.Analytics do
  @moduledoc """
  Context for analytics data — materialized view refreshes, `insights_daily` partition
  lifecycle, findings, and ad health scores.

  Called by `MatViewRefreshWorker`, `PartitionManagerWorker`, and `BudgetLeakAuditorWorker`.
  Workers must not call `Repo` directly. All user-facing finding queries scope to the
  requesting user's MetaConnection IDs so one user can never access another's data.
  """

  import Ecto.Query

  require Logger

  alias AdButler.Accounts.User
  alias AdButler.Ads
  alias AdButler.Analytics.{AdHealthScore, Finding}
  alias AdButler.Repo

  # ---------------------------------------------------------------------------
  # Findings — user-facing (scoped)
  # ---------------------------------------------------------------------------

  @doc """
  Returns a page of findings for `user` and the total count matching the filters.

  Options:
  - `:page` — 1-based page number (default: `1`)
  - `:per_page` — records per page (default: `50`)
  - `:severity` — filter to `"low"`, `"medium"`, or `"high"`
  - `:kind` — filter to a specific kind (e.g. `"dead_spend"`)
  - `:ad_account_id` — filter to a specific ad account UUID
  """
  @spec paginate_findings(User.t(), keyword()) :: {[Finding.t()], non_neg_integer()}
  def paginate_findings(%User{} = user, opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 50)

    base =
      Finding
      |> scope_findings(user)
      |> apply_finding_filters(opts)

    total = Repo.aggregate(base, :count)

    items =
      base
      |> order_by([f], desc: f.inserted_at)
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()

    {items, total}
  end

  @doc "Returns all `Finding.id` values owned by `user` (via the `AdAccount` → `MetaConnection` chain)."
  @spec list_finding_ids_for_user(User.t()) :: [binary()]
  def list_finding_ids_for_user(%User{} = user) do
    Finding
    |> scope_findings(user)
    |> select([f], f.id)
    |> Repo.all()
  end

  @doc "Returns the finding with `id` scoped to `user`. Raises `Ecto.NoResultsError` if not found or not owned."
  @spec get_finding!(User.t(), binary()) :: Finding.t()
  def get_finding!(%User{} = user, id) do
    Finding
    |> scope_findings(user)
    |> Repo.get!(id)
  end

  @doc """
  Returns up to `limit` high- and medium-severity findings for `user` since `since`,
  plus the total count of matching findings.

  Scoped to the user's ad accounts — one user cannot see another's findings.
  Returns `{findings, total_count}`.
  """
  @spec list_high_medium_findings_since(User.t(), DateTime.t(), pos_integer()) ::
          {[Finding.t()], non_neg_integer()}
  def list_high_medium_findings_since(%User{} = user, %DateTime{} = since, limit \\ 50) do
    base =
      Finding
      |> scope_findings(user)
      |> where([f], f.severity in ["high", "medium"] and f.inserted_at >= ^since)

    total = Repo.aggregate(base, :count, :id)

    findings =
      base
      |> order_by([f], desc: f.inserted_at)
      |> limit(^limit)
      |> Repo.all()

    {findings, total}
  end

  @doc "Returns `{:ok, finding}` for the finding with `id` scoped to `user`, or `{:error, :not_found}` if missing, not owned, or `id` is not a valid UUID."
  @spec get_finding(User.t(), binary()) :: {:ok, Finding.t()} | {:error, :not_found}
  def get_finding(%User{} = user, id) do
    case Finding |> scope_findings(user) |> Repo.get(id) do
      nil -> {:error, :not_found}
      finding -> {:ok, finding}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  @doc """
  Marks a finding as acknowledged by `user`. Sets `acknowledged_at` and
  `acknowledged_by_user_id`. Idempotent — re-acknowledging overwrites with current time.

  Returns `{:ok, Finding.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}`.
  """
  @spec acknowledge_finding(User.t(), binary()) ::
          {:ok, Finding.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}
  def acknowledge_finding(%User{} = user, finding_id) do
    with {:ok, finding} <- get_finding(user, finding_id) do
      finding
      |> Finding.acknowledge_changeset(user.id)
      |> Repo.update()
    end
  end

  # ---------------------------------------------------------------------------
  # Findings — internal (no scope, called by auditor worker)
  # ---------------------------------------------------------------------------

  @doc "Creates a finding from `attrs`. Internal use only — no tenant scope check."
  @spec create_finding(map()) :: {:ok, Finding.t()} | {:error, Ecto.Changeset.t()}
  def create_finding(attrs) do
    %Finding{}
    |> Finding.create_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Returns the open (unresolved) finding for `(ad_id, kind)`, or `nil` if none exists.
  Internal use — called by the auditor worker for deduplication.
  """
  @spec get_unresolved_finding(binary(), String.t()) :: Finding.t() | nil
  def get_unresolved_finding(ad_id, kind) do
    Repo.one(
      from f in Finding,
        where: f.ad_id == ^ad_id and f.kind == ^kind and is_nil(f.resolved_at),
        limit: 1
    )
  end

  @doc """
  UNSAFE — returns every finding row's `id`, `title`, and `body`. No tenant
  scope. Used by the cross-tenant `EmbeddingsRefreshWorker` to compute source
  text for each finding. Internal worker use only — never expose to
  user-facing surfaces.
  """
  @spec unsafe_list_all_findings_for_embedding() :: [
          %{id: binary(), title: String.t(), body: String.t() | nil}
        ]
  def unsafe_list_all_findings_for_embedding do
    Repo.all(from f in Finding, select: %{id: f.id, title: f.title, body: f.body})
  end

  @doc "Returns a MapSet of {ad_id, kind} tuples for all open (unresolved) findings for the given ad_ids. INTERNAL — not tenant-scoped, worker-only. Never call from user-facing code."
  @spec unsafe_list_open_finding_keys([binary()]) :: MapSet.t()
  def unsafe_list_open_finding_keys([]), do: MapSet.new()

  def unsafe_list_open_finding_keys(ad_ids) do
    from(f in Finding,
      where: f.ad_id in ^ad_ids and is_nil(f.resolved_at),
      select: {f.ad_id, f.kind}
    )
    |> Repo.all()
    |> MapSet.new()
  end

  # ---------------------------------------------------------------------------
  # AdHealthScore — internal (no scope, called by auditor worker)
  # ---------------------------------------------------------------------------

  @doc """
  Inserts a new health score row for `ad_id`. Append-only — never updates existing rows.
  Each call inserts a new row.
  Returns `{:ok, AdHealthScore.t()} | {:error, Ecto.Changeset.t()}`.
  """
  @spec insert_ad_health_score(map()) :: {:ok, AdHealthScore.t()} | {:error, Ecto.Changeset.t()}
  def insert_ad_health_score(attrs) do
    %AdHealthScore{}
    |> AdHealthScore.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:leak_score, :leak_factors, :inserted_at]},
      conflict_target: [:ad_id, :computed_at]
    )
  end

  @doc "Bulk-upserts health scores. DB errors raise; Oban retries the job."
  @spec bulk_insert_health_scores([map()]) :: :ok
  def bulk_insert_health_scores([]), do: :ok

  def bulk_insert_health_scores(entries) do
    {count, _} =
      Repo.insert_all(
        AdHealthScore,
        entries,
        on_conflict: {:replace, [:leak_score, :leak_factors, :inserted_at]},
        conflict_target: [:ad_id, :computed_at]
      )

    if count == 0 do
      Logger.warning("bulk_insert_health_scores: 0 rows written", count: length(entries))
    end

    :ok
  end

  @doc """
  Bulk-upserts fatigue scores. Mirrors `bulk_insert_health_scores/1` but only
  touches the fatigue columns on conflict so a parallel `BudgetLeakAuditorWorker`
  write at the same `computed_at` bucket is preserved.

  **`:metadata` is replaced unconditionally** on conflict (it is in the
  `on_conflict` replace list). Callers must always set `:metadata` on every
  entry — leaving it `nil` clears any cached value (e.g. the honeymoon baseline
  read by `get_ad_honeymoon_baseline/1`). When no metadata is being added, pass
  `%{}` to preserve the dict shape and let the next caller populate it.
  """
  @spec bulk_insert_fatigue_scores([map()]) :: :ok
  def bulk_insert_fatigue_scores([]), do: :ok

  def bulk_insert_fatigue_scores(entries) do
    {count, _} =
      Repo.insert_all(
        AdHealthScore,
        entries,
        on_conflict: {:replace, [:fatigue_score, :fatigue_factors, :metadata, :inserted_at]},
        conflict_target: [:ad_id, :computed_at]
      )

    if count == 0 do
      Logger.warning("bulk_insert_fatigue_scores: 0 rows written", count: length(entries))
    end

    :ok
  end

  @doc """
  Returns the most recent `AdHealthScore` for `ad_id`, or `nil` if none exists.

  **UNSAFE — no tenant scope.** Callers MUST verify that the requesting user owns
  the ad before invoking this function. The required invariant: call `get_finding/2`
  or `get_finding!/2` first and only proceed on success — those functions enforce
  the tenant scope that this function intentionally skips.
  """
  @spec unsafe_get_latest_health_score(binary()) :: AdHealthScore.t() | nil
  def unsafe_get_latest_health_score(ad_id) do
    Repo.one(
      from s in AdHealthScore,
        where: s.ad_id == ^ad_id,
        order_by: [desc: s.computed_at],
        limit: 1
    )
  end

  # ---------------------------------------------------------------------------
  # Creative fatigue helpers — internal (no scope, called by predictor worker)
  # ---------------------------------------------------------------------------

  @honeymoon_min_impressions 1000
  @honeymoon_window_days 3

  @doc """
  Returns `%{ad_id => [insights_daily_row]}` for the given ad_ids over the
  last `window_days` days (rows where `impressions > 0`, ordered ascending by
  `date_start`). Single bulk query — group in Elixir to collapse the per-ad
  N+1 in the predictor worker.

  **UNSAFE — no tenant scope.** Callers must scope `ad_ids` upstream
  (e.g. via `Ads.unsafe_list_ad_ids_for_account/1`).
  """
  @spec unsafe_list_insights_window_for_ads([binary()], pos_integer()) ::
          %{binary() => [map()]}
  def unsafe_list_insights_window_for_ads([], _window_days), do: %{}

  def unsafe_list_insights_window_for_ads(ad_ids, window_days)
      when is_list(ad_ids) and is_integer(window_days) and window_days > 0 do
    cutoff = Date.add(Date.utc_today(), -(window_days - 1))

    rows =
      Repo.all(
        from i in "insights_daily",
          where:
            i.ad_id in type(^ad_ids, {:array, :binary_id}) and i.date_start >= ^cutoff and
              i.impressions > 0,
          order_by: [asc: i.date_start],
          select: %{
            ad_id: i.ad_id,
            date_start: i.date_start,
            impressions: i.impressions,
            clicks: i.clicks,
            reach_count: i.reach_count,
            frequency: i.frequency
          }
      )

    Enum.group_by(rows, &cast_uuid(&1.ad_id), &Map.delete(&1, :ad_id))
  end

  defp cast_uuid(<<_::binary-size(16)>> = bin), do: Ecto.UUID.cast!(bin)
  defp cast_uuid(uuid) when is_binary(uuid), do: uuid

  @doc """
  Returns the honeymoon CTR baseline for `ad_id` — the average CTR over the
  first `#{@honeymoon_window_days}` days the ad accumulated more than
  `#{@honeymoon_min_impressions}` impressions.

  Read-only. Cache lookup runs first against the latest `AdHealthScore`'s
  `metadata["honeymoon_baseline"]`; on miss, computes from `insights_daily`
  and returns the freshly-computed value. The caller persists the cache by
  including `:metadata` in the next `bulk_insert_fatigue_scores/1` entry —
  this keeps the function pure and avoids a write fan-out.

  Returns `{:error, :insufficient_data}` when fewer than
  `#{@honeymoon_window_days}` qualifying days exist.

  Baseline CTR is `SUM(clicks) / SUM(impressions)` across the window — this
  weights the average by impressions rather than treating each day equally,
  matching how downstream predictive checks compare projected CTR.
  """
  @spec get_ad_honeymoon_baseline(binary()) ::
          {:ok, %{baseline_ctr: float(), window_dates: [Date.t()]}}
          | {:error, :insufficient_data}
  def get_ad_honeymoon_baseline(ad_id) do
    case cached_honeymoon_baseline(ad_id) do
      {:ok, _} = ok -> ok
      :miss -> compute_honeymoon_baseline(ad_id)
    end
  end

  @doc """
  Same as `get_ad_honeymoon_baseline/1` but consults the cache first and falls
  back to deriving the baseline from a pre-fetched list of `insights_daily`
  rows (the slice provided by `unsafe_list_insights_window_for_ads/2`) instead
  of running its own query.

  **Caller invariant:** `rows` must be the slice for `ad_id` only — the cache
  read is keyed by `ad_id` but the row-based fallback does not re-check ad
  ownership. Pass mismatched rows and the baseline reflects the wrong ad.

  Cache hit always wins. On miss, returns `{:error, :insufficient_data}` if the
  pre-fetched slice doesn't contain enough qualifying days — the predictor
  worker silently degrades for that ad until the cache is populated by a
  subsequent run that picks up the baseline from a wider DB query.
  """
  @spec get_ad_honeymoon_baseline(binary(), [map()]) ::
          {:ok, %{baseline_ctr: float(), window_dates: [Date.t()]}}
          | {:error, :insufficient_data}
  def get_ad_honeymoon_baseline(ad_id, rows) when is_list(rows) do
    case cached_honeymoon_baseline(ad_id) do
      {:ok, _} = ok -> ok
      :miss -> compute_honeymoon_baseline_from_rows(rows)
    end
  end

  defp compute_honeymoon_baseline_from_rows(rows) do
    qualifying =
      rows
      |> Enum.filter(fn r -> r.impressions > @honeymoon_min_impressions end)
      |> Enum.sort_by(& &1.date_start, Date)
      |> Enum.take(@honeymoon_window_days)

    if Enum.count(qualifying) < @honeymoon_window_days do
      {:error, :insufficient_data}
    else
      total_impressions = Enum.sum_by(qualifying, & &1.impressions)
      total_clicks = Enum.sum_by(qualifying, & &1.clicks)

      {:ok,
       %{
         baseline_ctr: Float.round(total_clicks / total_impressions, 6),
         window_dates: Enum.map(qualifying, & &1.date_start)
       }}
    end
  end

  defp cached_honeymoon_baseline(ad_id) do
    with %AdHealthScore{metadata: %{"honeymoon_baseline" => cached}} <-
           unsafe_get_latest_health_score(ad_id),
         %{"baseline_ctr" => ctr, "window_dates" => dates}
         when is_number(ctr) and is_list(dates) <- cached,
         {:ok, parsed_dates} <- parse_window_dates(dates) do
      # Force float — JSON-decoded numbers may be integer when the cached value
      # rounds to a whole number. Downstream comparisons assume float CTR.
      {:ok, %{baseline_ctr: ctr * 1.0, window_dates: parsed_dates}}
    else
      _ -> :miss
    end
  end

  defp parse_window_dates(dates) do
    Enum.reduce_while(dates, {:ok, []}, fn d, {:ok, acc} ->
      case Date.from_iso8601(d) do
        {:ok, date} -> {:cont, {:ok, [date | acc]}}
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  @regression_window_days 14
  @regression_min_days 10

  @doc """
  Fits a multiple linear regression of daily CTR on three features over the
  last #{@regression_window_days} days for `ad_id`:

      CTR ~ β₀ + β_day · day_index + β_freq · frequency + β_reach · cumulative_reach

  - `day_index` runs 0..N-1 across the observed days (0 = oldest).
  - `frequency` is the per-day Meta-reported frequency; `nil`/`0` rows count as `0.0`.
  - `cumulative_reach` is `SUM(reach_count) OVER (ORDER BY date_start)` within the
    14-day window. `insights_daily` has no native cumulative_reach column.

  Days with zero impressions are dropped (CTR undefined). Returns
  `{:error, :insufficient_data}` when fewer than #{@regression_min_days} usable
  days remain, or when the 4×4 normal equations are singular (collinear features —
  e.g. flat frequency + cumulative_reach == reach_count × day_index).

  `projected_ctr_3d` extrapolates `day_index` forward 3 days and projects
  `frequency` and `cumulative_reach` via their own per-feature OLS slopes; this
  keeps the prediction internally consistent rather than holding the latest
  observed values constant.

  `slope_per_day` is the `β_day` coefficient. `r_squared` is clamped to `[0, 1]`.
  Coefficients are solved via Gauss-Jordan elimination with partial pivoting on
  the 4×5 augmented matrix `[XᵀX | Xᵀy]` — the fixed 4-feature dimension makes
  a manual solver simpler than pulling in a numerics dep.
  """
  @spec fit_ctr_regression(binary()) ::
          {:ok,
           %{
             slope_per_day: float(),
             intercept: float(),
             projected_ctr_3d: float(),
             r_squared: float()
           }}
          | {:error, :insufficient_data}
  def fit_ctr_regression(ad_id) do
    fit_ctr_regression(ad_id, fetch_regression_rows(ad_id))
  end

  @doc """
  Same as `fit_ctr_regression/1` but fits over a pre-fetched list of
  `insights_daily` rows (filter `impressions > 0`, ordered ascending by
  `date_start`). Used by the predictor worker to collapse the per-ad N+1
  on the 14-day window into a single bulk fetch.

  **Caller invariant:** `rows` must be the slice for `ad_id` and nothing
  else — this function does not re-scope. Mixing rows from multiple ads
  fits the regression to wrong data with no error. The standard caller is
  `unsafe_list_insights_window_for_ads/2 |> Map.get(ad_id, [])`.
  """
  @spec fit_ctr_regression(binary(), [map()]) ::
          {:ok,
           %{
             slope_per_day: float(),
             intercept: float(),
             projected_ctr_3d: float(),
             r_squared: float()
           }}
          | {:error, :insufficient_data}
  def fit_ctr_regression(_ad_id, rows) when is_list(rows) do
    if Enum.count(rows) < @regression_min_days do
      {:error, :insufficient_data}
    else
      do_fit_regression(rows)
    end
  end

  defp fetch_regression_rows(ad_id) do
    cutoff = Date.add(Date.utc_today(), -(@regression_window_days - 1))

    Repo.all(
      from i in "insights_daily",
        where:
          i.ad_id == type(^ad_id, :binary_id) and i.date_start >= ^cutoff and
            i.impressions > 0,
        order_by: [asc: i.date_start],
        select: %{
          date_start: i.date_start,
          impressions: i.impressions,
          clicks: i.clicks,
          reach_count: i.reach_count,
          frequency: i.frequency
        }
    )
  end

  defp do_fit_regression(rows) do
    n = length(rows)
    ctrs = Enum.map(rows, fn r -> r.clicks / r.impressions end)
    freqs = Enum.map(rows, &row_frequency/1)
    cumulative_reach = rows |> Enum.map(& &1.reach_count) |> running_sum()
    day_indices = Enum.map(0..(n - 1), &(&1 * 1.0))

    x_rows =
      Enum.zip([day_indices, freqs, cumulative_reach])
      |> Enum.map(fn {d, f, r} -> [1.0, d, f, r] end)

    case solve_normal_equations(x_rows, ctrs) do
      {:ok, [beta0, beta_day, beta_freq, beta_reach] = betas} ->
        preds = Enum.map(x_rows, &dot(&1, betas))
        mean_y = Enum.sum(ctrs) / n
        ss_tot = Enum.reduce(ctrs, 0.0, fn y, acc -> acc + :math.pow(y - mean_y, 2) end)

        ss_res =
          Enum.zip_reduce(ctrs, preds, 0.0, fn y, p, acc -> acc + :math.pow(y - p, 2) end)

        r_squared = if ss_tot == 0.0, do: 0.0, else: 1.0 - ss_res / ss_tot

        freq_proj = extrapolate_forward(day_indices, freqs, 3)
        reach_proj = extrapolate_forward(day_indices, cumulative_reach, 3)
        day_proj = n - 1 + 3
        projected = beta0 + beta_day * day_proj + beta_freq * freq_proj + beta_reach * reach_proj

        {:ok,
         %{
           slope_per_day: Float.round(beta_day, 8),
           intercept: Float.round(beta0, 8),
           projected_ctr_3d: Float.round(projected, 8),
           r_squared: Float.round(clamp(r_squared, 0.0, 1.0), 6)
         }}

      {:error, :singular} ->
        # Highly collinear features (e.g. flat frequency + cumulative_reach
        # perfectly proportional to day_index). Treat as insufficient — the
        # caller's r² gate would have rejected the fit anyway.
        {:error, :insufficient_data}
    end
  end

  defp row_frequency(%{frequency: nil}), do: 0.0
  defp row_frequency(%{frequency: %Decimal{} = d}), do: Decimal.to_float(d)
  defp row_frequency(%{frequency: f}) when is_number(f), do: f * 1.0

  defp running_sum(values) do
    {acc, _} =
      Enum.map_reduce(values, 0, fn v, sum ->
        new_sum = sum + v
        {new_sum * 1.0, new_sum}
      end)

    acc
  end

  defp dot(a, b), do: Enum.zip_reduce(a, b, 0.0, fn x, y, acc -> acc + x * y end)

  defp clamp(x, lo, _hi) when x < lo, do: lo
  defp clamp(x, _lo, hi) when x > hi, do: hi
  defp clamp(x, _lo, _hi), do: x

  # Per-feature OLS extrapolation: project value at x = (n-1) + offset.
  defp extrapolate_forward(xs, ys, offset) do
    n = length(xs)

    cond do
      n == 0 ->
        0.0

      n == 1 ->
        List.first(ys) * 1.0

      true ->
        x_mean = Enum.sum(xs) / n
        y_mean = Enum.sum(ys) / n

        num =
          Enum.zip_reduce(xs, ys, 0.0, fn x, y, acc -> acc + (x - x_mean) * (y - y_mean) end)

        den = Enum.reduce(xs, 0.0, fn x, acc -> acc + :math.pow(x - x_mean, 2) end)
        slope = if den == 0.0, do: 0.0, else: num / den
        intercept = y_mean - slope * x_mean
        slope * (n - 1 + offset) + intercept
    end
  end

  # XᵀX β = Xᵀy solved via Gauss-Jordan on the 4×5 augmented matrix.
  defp solve_normal_equations(x_rows, ys) do
    k = 4
    xtx = build_xtx(x_rows, k)
    xty = build_xty(x_rows, ys, k)

    augmented =
      xtx
      |> Enum.zip(xty)
      |> Enum.map(fn {row, b} -> row ++ [b] end)

    case gauss_jordan(augmented, k) do
      {:ok, reduced} -> {:ok, Enum.map(reduced, &List.last/1)}
      err -> err
    end
  end

  defp build_xtx(x_rows, k) do
    for i <- 0..(k - 1), do: Enum.map(0..(k - 1), &xtx_cell(x_rows, i, &1))
  end

  defp xtx_cell(x_rows, i, j) do
    Enum.reduce(x_rows, 0.0, fn row, acc -> acc + Enum.at(row, i) * Enum.at(row, j) end)
  end

  defp build_xty(x_rows, ys, k) do
    for i <- 0..(k - 1), do: xty_cell(x_rows, ys, i)
  end

  defp xty_cell(x_rows, ys, i) do
    Enum.zip_reduce(x_rows, ys, 0.0, fn row, y, acc -> acc + Enum.at(row, i) * y end)
  end

  defp gauss_jordan(matrix, k) do
    Enum.reduce_while(0..(k - 1), {:ok, matrix}, &eliminate_column/2)
  end

  defp eliminate_column(col, {:ok, m}) do
    {pivot_idx, pivot_abs} = find_pivot(m, col)

    if pivot_abs < 1.0e-12 do
      {:halt, {:error, :singular}}
    else
      {:cont, {:ok, do_eliminate(m, col, pivot_idx)}}
    end
  end

  defp find_pivot(m, col) do
    m
    |> Enum.with_index()
    |> Enum.drop(col)
    |> Enum.map(fn {row, idx} -> {idx, abs(Enum.at(row, col))} end)
    |> Enum.max_by(&elem(&1, 1))
  end

  defp do_eliminate(m, col, pivot_idx) do
    swapped = swap_rows(m, col, pivot_idx)
    pivot_row = Enum.at(swapped, col)
    pivot_val = Enum.at(pivot_row, col)
    norm = Enum.map(pivot_row, &(&1 / pivot_val))

    swapped
    |> List.replace_at(col, norm)
    |> Enum.with_index()
    |> Enum.map(fn {row, idx} -> reduce_row(row, idx, col, norm) end)
  end

  defp reduce_row(row, idx, idx, _norm), do: row

  defp reduce_row(row, _idx, col, norm) do
    factor = Enum.at(row, col)
    Enum.zip_with(row, norm, fn a, b -> a - factor * b end)
  end

  defp swap_rows(m, i, i), do: m

  defp swap_rows(m, i, j) do
    ri = Enum.at(m, i)
    rj = Enum.at(m, j)

    m
    |> List.replace_at(i, rj)
    |> List.replace_at(j, ri)
  end

  defp compute_honeymoon_baseline(ad_id) do
    rows =
      Repo.all(
        from i in "insights_daily",
          where:
            i.ad_id == type(^ad_id, :binary_id) and
              i.impressions > ^@honeymoon_min_impressions,
          order_by: [asc: i.date_start],
          limit: ^@honeymoon_window_days,
          select: %{
            date_start: i.date_start,
            impressions: i.impressions,
            clicks: i.clicks
          }
      )

    if Enum.count(rows) < @honeymoon_window_days do
      {:error, :insufficient_data}
    else
      total_impressions = Enum.sum_by(rows, & &1.impressions)
      total_clicks = Enum.sum_by(rows, & &1.clicks)

      {:ok,
       %{
         baseline_ctr: Float.round(total_clicks / total_impressions, 6),
         window_dates: Enum.map(rows, & &1.date_start)
       }}
    end
  end

  @doc """
  Fits a simple linear regression on daily CTR for `ad_id` over the last
  `window_days` days and returns the slope in **percentage-points per day**.

  CTR per day is computed from `clicks / impressions` directly (rather than the
  stored `ctr_numeric`) so days with zero impressions contribute a 0.0 datapoint
  and don't break the fit. Returns `0.0` when fewer than 2 days of data exist —
  the predictor heuristic guards on a minimum-day threshold separately.

  Reads `insights_daily` directly. The 7-day matview omits per-day granularity,
  so a per-row query is required for slope.
  """
  @spec compute_ctr_slope(binary(), pos_integer()) :: float()
  def compute_ctr_slope(ad_id, window_days) when window_days >= 2 do
    cutoff = Date.add(Date.utc_today(), -(window_days - 1))

    rows =
      Repo.all(
        from i in "insights_daily",
          where: i.ad_id == type(^ad_id, :binary_id) and i.date_start >= ^cutoff,
          order_by: [asc: i.date_start],
          select: %{
            date_start: i.date_start,
            impressions: i.impressions,
            clicks: i.clicks
          }
      )

    case rows do
      [] ->
        0.0

      [_] ->
        0.0

      rows ->
        ctrs = Enum.map(rows, &row_ctr/1)
        # slope per day in fraction units; multiply by 100 for percentage points
        Float.round(simple_linear_slope(ctrs) * 100.0, 4)
    end
  end

  defp row_ctr(%{impressions: i, clicks: c}) when i > 0, do: c / i
  defp row_ctr(_), do: 0.0

  @doc """
  Returns the average daily frequency for `ad_id` over the last 7 days, or `nil`
  if no qualifying rows exist (frequency NULL or 0 means Meta hadn't computed it).

  Reads `insights_daily` directly — `ad_insights_7d` aggregates impressions/clicks
  but not frequency. Returns a float for downstream comparison.
  """
  @spec get_7d_frequency(binary()) :: float() | nil
  def get_7d_frequency(ad_id) do
    cutoff = Date.add(Date.utc_today(), -6)

    avg =
      Repo.one(
        from i in "insights_daily",
          where:
            i.ad_id == type(^ad_id, :binary_id) and i.date_start >= ^cutoff and
              not is_nil(i.frequency) and i.frequency > 0,
          select: avg(i.frequency)
      )

    case avg do
      nil -> nil
      %Decimal{} = d -> d |> Decimal.to_float() |> Float.round(4)
    end
  end

  @doc """
  Returns the percent change in CPM between the most recent 7 days and the
  prior 7-day window (days 8–14 ago) for `ad_id`, or `nil` when either window
  has zero spend or zero impressions.

  Each window's CPM is `SUM(spend_cents) * 1000 / SUM(impressions)`. Reads
  `insights_daily` directly — the 7d matview only captures the most recent
  window so we can't get the prior week from it.

  Positive return values indicate CPM rose; negative values indicate it fell.
  """
  @spec get_cpm_change_pct(binary()) :: float() | nil
  def get_cpm_change_pct(ad_id) do
    today = Date.utc_today()
    recent_cutoff = Date.add(today, -6)
    prior_start = Date.add(today, -13)
    prior_end = Date.add(today, -7)

    rows =
      Repo.all(
        from i in "insights_daily",
          where:
            i.ad_id == type(^ad_id, :binary_id) and i.date_start >= ^prior_start and
              i.date_start <= ^today,
          select: %{
            date_start: i.date_start,
            spend_cents: i.spend_cents,
            impressions: i.impressions
          }
      )

    {recent, prior} =
      Enum.split_with(rows, fn r -> Date.compare(r.date_start, recent_cutoff) != :lt end)

    prior =
      Enum.filter(prior, fn r ->
        Date.compare(r.date_start, prior_start) != :lt and
          Date.compare(r.date_start, prior_end) != :gt
      end)

    with {:ok, recent_cpm} <- avg_cpm(recent),
         {:ok, prior_cpm} <- avg_cpm(prior) do
      Float.round((recent_cpm - prior_cpm) / prior_cpm * 100.0, 2)
    else
      _ -> nil
    end
  end

  defp avg_cpm(rows) do
    total_spend = Enum.sum_by(rows, & &1.spend_cents)
    total_impressions = Enum.sum_by(rows, & &1.impressions)

    cond do
      total_impressions == 0 -> {:error, :insufficient}
      total_spend == 0 -> {:error, :insufficient}
      true -> {:ok, total_spend * 1000 / total_impressions}
    end
  end

  # Closed-form OLS slope. xs are 0..n-1 (regular daily samples).
  defp simple_linear_slope(ys) do
    n = length(ys)
    xs = Enum.to_list(0..(n - 1))
    sum_x = Enum.sum(xs)
    sum_y = Enum.sum(ys)
    sum_xy = Enum.zip_reduce(xs, ys, 0.0, fn x, y, acc -> acc + x * y end)
    sum_xx = xs |> Enum.map(&(&1 * &1)) |> Enum.sum()
    denom = n * sum_xx - sum_x * sum_x
    if denom == 0, do: 0.0, else: (n * sum_xy - sum_x * sum_y) / denom
  end

  # ---------------------------------------------------------------------------
  # Materialized views + partition lifecycle
  # ---------------------------------------------------------------------------

  @doc ~S[Refreshes the materialized view for the given period (`"7d"` or `"30d"`).
Returns `{:error, "unknown view: ..."}` for unknown period strings.
Raises `Postgrex.Error` or `DBConnection.ConnectionError` on database failure.]
  @spec refresh_view(String.t()) :: :ok | {:error, String.t()}
  def refresh_view("7d"), do: do_refresh("ad_insights_7d")
  def refresh_view("30d"), do: do_refresh("ad_insights_30d")

  def refresh_view(view) do
    {:error, "unknown view: #{view}"}
  end

  @doc "Creates next 2 weekly `insights_daily` partitions (idempotent)."
  @spec create_future_partitions() :: :ok
  def create_future_partitions do
    today = Date.utc_today()

    Enum.each([7, 14], fn days_ahead ->
      target = Date.add(today, days_ahead)
      ws = week_start(target)
      we = Date.add(ws, 7)
      pname = partition_name(ws)
      safe_pname = safe_identifier!(pname)

      # ws/we come from Date arithmetic — Date.to_iso8601 always returns YYYY-MM-DD
      Repo.query!("""
      CREATE TABLE IF NOT EXISTS "#{safe_pname}"
      PARTITION OF insights_daily
      FOR VALUES FROM ('#{Date.to_iso8601(ws)}') TO ('#{Date.to_iso8601(we)}')
      """)

      Logger.info("insights partition created or already exists",
        partition: pname,
        week_start: ws
      )
    end)
  end

  @doc "Detaches `insights_daily` partitions older than 13 months."
  @spec detach_old_partitions() :: :ok
  def detach_old_partitions do
    cutoff = Date.add(Date.utc_today(), -395)

    list_partition_names()
    |> Enum.each(&maybe_detach_partition(&1, cutoff))
  end

  @doc """
  Logs a critical error if fewer than 2 future `insights_daily` partitions exist.
  Returns `:ok` regardless.
  """
  @spec check_future_partition_count() :: :ok
  def check_future_partition_count do
    today = Date.utc_today()

    future_count =
      list_partition_names()
      |> Enum.count(fn relname ->
        case parse_week_start(relname) do
          {:ok, ws} -> Date.compare(ws, today) != :lt
          :error -> false
        end
      end)

    if future_count < 2 do
      Logger.error(
        "insights partitions critical: fewer than 2 future partitions",
        count: future_count
      )
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp scope_findings(queryable, %User{} = user) do
    ad_account_ids = Ads.list_ad_account_ids_for_user(user)
    where(queryable, [f], f.ad_account_id in ^ad_account_ids)
  end

  defp apply_finding_filters(queryable, opts) do
    Enum.reduce(opts, queryable, fn
      {:severity, s}, q when is_binary(s) and s != "" ->
        where(q, [f], f.severity == ^s)

      {:kind, k}, q when is_binary(k) and k != "" ->
        where(q, [f], f.kind == ^k)

      {:ad_account_id, id}, q when is_binary(id) and id != "" ->
        where(q, [f], f.ad_account_id == ^id)

      _, q ->
        q
    end)
  end

  defp do_refresh(view_name) do
    safe_name = safe_identifier!(view_name)

    {duration_us, _} =
      :timer.tc(fn ->
        Repo.query!(~s[REFRESH MATERIALIZED VIEW CONCURRENTLY "#{safe_name}"])
      end)

    Logger.info("materialized view refreshed",
      view: view_name,
      duration_ms: div(duration_us, 1000)
    )

    :ok
  end

  defp list_partition_names do
    %{rows: rows} =
      Repo.query!("""
      SELECT child.relname
      FROM pg_inherits
      JOIN pg_class child ON child.oid = pg_inherits.inhrelid
      JOIN pg_class parent ON parent.oid = pg_inherits.inhparent
      WHERE parent.relname = 'insights_daily'
      """)

    Enum.map(rows, fn [relname] -> relname end)
  end

  defp maybe_detach_partition(relname, cutoff) do
    case parse_week_start(relname) do
      {:ok, ws} when is_struct(ws, Date) ->
        if Date.compare(ws, cutoff) == :lt do
          Repo.query!(
            ~s[ALTER TABLE insights_daily DETACH PARTITION "#{safe_identifier!(relname)}"]
          )

          Logger.info("insights partition detached", partition: relname, week_start: ws)
        end

      _ ->
        :ok
    end
  end

  defp safe_identifier!(name) do
    unless Regex.match?(~r/\A[a-zA-Z0-9_]+\z/, name),
      do: raise(ArgumentError, "unsafe partition identifier: #{inspect(name)}")

    name
  end

  defp week_start(date) do
    day_of_week = Date.day_of_week(date, :monday)
    Date.add(date, -(day_of_week - 1))
  end

  defp partition_name(ws) do
    year = ws.year
    week = iso_week(ws)
    "insights_daily_#{year}_W#{String.pad_leading(Integer.to_string(week), 2, "0")}"
  end

  defp iso_week(date) do
    {_year, week} = :calendar.iso_week_number({date.year, date.month, date.day})
    week
  end

  defp parse_week_start(relname) do
    case Regex.run(~r/\Ainsights_daily_(\d{4})_[Ww](\d{2})\z/, relname) do
      [_, year_str, week_str] ->
        year = String.to_integer(year_str)
        week = String.to_integer(week_str)
        jan4 = Date.new!(year, 1, 4)
        jan4_dow = Date.day_of_week(jan4, :monday)
        week1_monday = Date.add(jan4, -(jan4_dow - 1))
        {:ok, Date.add(week1_monday, (week - 1) * 7)}

      nil ->
        :error
    end
  end
end
