defmodule AdButler.Meta.RateLimitStore do
  @moduledoc """
  GenServer that owns the `:meta_rate_limits` ETS table used by `AdButler.Meta.Client`.

  The table is public and read-concurrent so the HTTP client can write and read
  without going through this process. This GenServer's sole job is to create the
  table on startup and run a periodic cleanup that evicts stale entries (older
  than 1 hour) every 5 minutes.
  """
  use GenServer

  @table :meta_rate_limits
  @cleanup_interval :timer.minutes(5)
  @entry_ttl_seconds 3_600

  @doc "Starts the RateLimitStore GenServer, creating the ETS table and scheduling the first cleanup."
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: :auto
    ])

    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cutoff = DateTime.add(DateTime.utc_now(), -@entry_ttl_seconds, :second)

    stale =
      :ets.foldl(
        fn {key, {_, _, _, ts}}, acc ->
          if DateTime.before?(ts, cutoff), do: [key | acc], else: acc
        end,
        [],
        @table
      )

    Enum.each(stale, &:ets.delete(@table, &1))
    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
