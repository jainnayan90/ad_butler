# Review: Publisher Connection Leak Fix + Health Controller Cache + Migration

**Date**: 2026-04-23  
**Verdict**: REQUIRES CHANGES  
**Breakdown**: 2 blockers · 3 warnings · 2 suggestions

Files reviewed: `lib/ad_butler/messaging/publisher.ex`, `lib/ad_butler_web/controllers/health_controller.ex`, `priv/repo/migrations/20260422000000_add_index_meta_connections_status.exs`, `test/ad_butler/messaging/publisher_test.exs`, `test/ad_butler/messaging/rabbitmq_topology_test.exs`

---

## BLOCKERS

### B1: `:persistent_term` cache makes 503 test return 200 — deterministic failure
**Source**: Testing Reviewer  
**Location**: `test/ad_butler_web/controllers/health_controller_test.exs:17-23`

The 200-ok test calls `cached_db_ping/0`, which on success writes `System.os_time(:second)` to `:persistent_term.put(:health_db_last_ok, now)`. The 503 test runs within the same second (sequential, `async: false`), cache hit returns `{:ok, :cached}`, controller returns 200. The `Application.put_env(:ad_butler, :db_ping_fn, ...)` override is never reached because the cache short-circuits before `db_ping/0` is called.

**Fix**:
```elixir
test "returns 503 when DB is unavailable", %{conn: conn} do
  :persistent_term.erase(:health_db_last_ok)  # bust cache
  Application.put_env(:ad_butler, :db_ping_fn, fn -> {:error, :timeout} end)
  on_exit(fn -> Application.delete_env(:ad_butler, :db_ping_fn) end)
  conn = get(conn, ~p"/health/readiness")
  assert response(conn, 503) == "unavailable"
end
```

---

### B2: Publisher test race — `publish/1` called before GenServer processes `:connect`
**Source**: Testing Reviewer  
**Location**: `test/ad_butler/messaging/publisher_test.exs:16`

`Publisher.init/1` sends `:connect` to itself and returns immediately. `start_supervised/1` returns as soon as `init/1` returns — before `:connect` is processed by the mailbox. `channel` is still `nil`, so `publish/1` returns `{:error, :not_connected}`, failing the assertion intermittently (timing-dependent).

**Fix**: Add a `Publisher.await_connected/1` function backed by a `GenServer.call` (which enqueues behind the `:connect` handler), or add a simple ready-check loop in test setup:
```elixir
# Simple approach: poll until connected
Enum.each(1..20, fn _ ->
  if GenServer.call(Publisher, :state).channel == nil, do: Process.sleep(50)
end)
```
A cleaner long-term fix is exposing `Publisher.connected?/0` as a public API.

---

## WARNINGS

### W1: `terminate/2` strict 4-key pattern — silent leak on state shape mismatch
**Source**: Elixir Reviewer  
**Location**: `lib/ad_butler/messaging/publisher.ex:101`

If the state map ever gains or loses keys, `terminate/2` raises `FunctionClauseError` — OTP swallows it silently, leaking the AMQP connection with no log. Currently safe since `init` always returns the full 4-key map, but fragile.

**Fix**:
```elixir
def terminate(_reason, state) do
  if ref = Map.get(state, :conn_ref), do: Process.demonitor(ref, [:flush])
  if ref = Map.get(state, :channel_ref), do: Process.demonitor(ref, [:flush])
  close_amqp_channel(Map.get(state, :channel))
  close_amqp_connection(Map.get(state, :conn))
end
```

---

### W2: `persistent_term.put` thundering herd on cache expiry
**Source**: Elixir Reviewer  
**Location**: `lib/ad_butler_web/controllers/health_controller.ex:29`

`persistent_term.put` triggers a global stop-the-world GC. On cache expiry, multiple concurrent probes race through the `_` branch — each calls `db_ping()` and `persistent_term.put`, causing N sequential GC pauses and N DB round-trips. Acceptable for Fly's 1 probe/5s default, but brittle under aggressive probe configs or load testing. Document the assumption or serialize with an ETS sentinel.

---

### W3: Topology test comment overstates DLX coverage
**Source**: Testing Reviewer  
**Location**: `test/ad_butler/messaging/rabbitmq_topology_test.exs:28`

Comment says DLX routing is "validated end-to-end by the DLQ routing test below" — but that test only asserts the exchange *exists* via passive declare; it doesn't publish a NACK'd message and verify it appears on the DLQ. The comment should say "existence only" or be removed.

---

## Confirmed Correct

- Demonitor-before-close order: correct — `[:flush]` drains queued `:DOWN` messages before closing, so no spurious `:DOWN` re-triggers reconnect
- Channel closed before connection: correct AMQP convention
- `try/catch` on close helpers: appropriate for external library calls that may exit
- Migration `@disable_ddl_transaction true` + `@disable_migration_lock true`: correct pair for `concurrently: true`; comment about partial index recovery is accurate
- `publisher_test.exs` `on_exit` closing conn only: safe — AMQP channels close implicitly when connection closes

---

## SUGGESTIONS

- **S1**: Add `Publisher.connected?/0` public API — eliminates sleep-polling in tests and enables readiness checks in other contexts
- **S2**: Add a reconnect path integration test: kill the Publisher's connection from the test side, assert `publish/1` succeeds again after `@reconnect_delay_ms`

---

## PRE-EXISTING (not in diff)

- `do_connect/1` inlines a `try/catch` for `AMQP.Connection.close` that duplicates the new `close_amqp_connection/1` helper — one-line note
