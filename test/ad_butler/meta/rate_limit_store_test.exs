defmodule AdButler.Meta.RateLimitStoreTest do
  use ExUnit.Case, async: false

  alias AdButler.Meta.RateLimitStore

  @table :meta_rate_limits

  setup do
    # RateLimitStore is started by the application supervision tree in all envs.
    # Clean the table between tests to avoid cross-test pollution.
    :ets.delete_all_objects(@table)
    :ok
  end

  test "application supervision creates the :meta_rate_limits ETS table" do
    assert :ets.info(@table) != :undefined
  end

  test "cleanup removes stale entries (ts > 1 hour ago)" do
    stale_ts = DateTime.add(DateTime.utc_now(), -3_601, :second)
    :ets.insert(@table, {"stale_account", {5, 10, 20, stale_ts}})

    pid = Process.whereis(RateLimitStore)
    send(pid, :cleanup)
    # Flush: get_state blocks until the GenServer processes all prior messages
    :sys.get_state(pid)

    assert :ets.lookup(@table, "stale_account") == []
  end

  test "cleanup keeps fresh entries (ts < 1 hour ago)" do
    fresh_ts = DateTime.add(DateTime.utc_now(), -60, :second)
    :ets.insert(@table, {"fresh_account", {5, 10, 20, fresh_ts}})

    pid = Process.whereis(RateLimitStore)
    send(pid, :cleanup)
    :sys.get_state(pid)

    assert :ets.lookup(@table, "fresh_account") != []
  end
end
