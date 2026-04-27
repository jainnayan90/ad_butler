defmodule AdButler.Analytics do
  @moduledoc """
  Context for managing materialized view refreshes and `insights_daily` partition lifecycle.

  Called by `MatViewRefreshWorker` and `PartitionManagerWorker` — workers must not
  call `Repo` directly.
  """

  require Logger

  alias AdButler.Repo

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

  # --- private ---

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
