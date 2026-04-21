defmodule AdButler.Meta.RateLimitStore do
  use GenServer

  # ETS table entries are never pruned; add a periodic cleanup if cardinality grows unbounded.
  @table :meta_rate_limits

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end
end
