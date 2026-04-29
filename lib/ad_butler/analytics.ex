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
