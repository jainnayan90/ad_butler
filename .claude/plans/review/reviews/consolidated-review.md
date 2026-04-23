# Code Review: module_documentation_and_audit_fixes vs main

**Date:** 2026-04-23
**Verdict: REQUIRES CHANGES**
**Score: 4 Critical · 5 Warnings · 5 Suggestions**

---

## Critical (must fix before merge)

### C1 — `PublisherPool` never routes to worker 0
`lib/ad_butler/messaging/publisher_pool.ex`

`:atomics.new/2` starts the counter at `0`. The first `add_get` returns `1`, so `rem(1, pool_size)` = 1 — worker 0 is permanently skipped. With 5 workers, only workers 1–4 receive traffic.

Fix: seed the counter at `pool_size - 1` before the Supervisor starts so the first call resolves to index 0:
```elixir
counter = :atomics.new(1, signed: false)
:atomics.put(counter, 1, pool_size - 1)
```

### C2 — `SyncAllConnectionsWorker.perform/1` ignores `Repo.transaction` result
`lib/ad_butler/workers/sync_all_connections_worker.ex`

The return value of `Repo.transaction/2` is discarded and `:ok` returned unconditionally. If the transaction raises or rolls back, Oban marks the job successful — no retry occurs and the connections silently go un-inserted.

Fix:
```elixir
case Repo.transaction(fn -> ... end, timeout: :timer.minutes(2)) do
  {:ok, _} -> :ok
  {:error, reason} -> {:error, reason}
end
```

### C3 — `SyncAllConnectionsWorker` holds a DB connection for the full stream with no timeout
`lib/ad_butler/workers/sync_all_connections_worker.ex`

`Repo.stream` inside `Repo.transaction` holds a pool checkout for the entire cursor + batch-insert loop. No timeout is passed to `Repo.transaction`, so with a large connections table this can block a DB pool slot for longer than the Oban job timeout (2 min), causing cascading pool exhaustion. Add `timeout: :timer.minutes(2)` to the `Repo.transaction` call (same value as the job timeout).

### C4 — `AMQPBasicFiniteStub` — `:finite_stub_agent` not unregistered on test failure
`test/mix/tasks/replay_dlq_test.exs`

`Process.register(agent, :finite_stub_agent)` is called in two test bodies. If a test crashes (exit/raise), the atom stays registered to a dead PID. The next test's `start_supervised!` creates a new agent, then `Process.register/2` raises `{:error, :already_registered}` — surfacing as a confusing test failure unrelated to the actual bug.

Fix: in the `setup` block, add:
```elixir
on_exit(fn ->
  try do Process.unregister(:finite_stub_agent) catch _, _ -> :ok end
end)
```

---

## Warnings

### W1 — `callback/2` crashes 500 on list-shaped params (security)
`lib/ad_butler_web/controllers/auth_controller.ex`

`/auth/meta/callback?error_description[]=y` causes Plug to parse `error_description` as a list. `String.slice(description, 0, 200)` raises `FunctionClauseError`. Add `is_binary/1` guards to the callback clauses, or add a catch-all that returns 400.

### W2 — `parse_budget/1` has no float clause — Meta API returns floats
`lib/ad_butler/sync/metadata_pipeline.ex`

Meta's Graph API can return budget values as floats (e.g. `1000.0`). `parse_budget/1` handles `nil | integer | binary` but not float — a float input raises `FunctionClauseError` and fails the entire batch. Add:
```elixir
def parse_budget(v) when is_float(v), do: round(v)
```

### W3 — `RABBITMQ_POOL_SIZE` crashes boot on malformed env var
`config/runtime.exs`

`String.to_integer(System.get_env("RABBITMQ_POOL_SIZE", "5"))` raises `ArgumentError` at boot if the env var is set to `""` or a non-numeric string (common CI/CD accident). Replace with `Integer.parse` and an explicit raise with a helpful message.

### W4 — `FetchAdAccountsWorker` retries full Meta API fetch on `:not_connected`
`lib/ad_butler/workers/fetch_ad_accounts_worker.ex`

If `PublisherPool.publish/1` returns `{:error, :not_connected}`, the job returns `{:error, :not_connected}` and Oban retries — re-calling Meta's API and burning rate-limit quota on each retry. Consider returning `{:snooze, 60}` on `:not_connected` to wait for AMQP reconnection before retrying.

### W5 — `await_connected/1` can fail with timeout when channel is already open
`lib/ad_butler/messaging/publisher_pool.ex`

`max(deadline - monotonic_now, 0)` can produce `0`. A `GenServer.call` with timeout `0` exits immediately before the server can reply, even when the channel is open. Add a floor of 50ms, or fast-path `connected?` when remaining ≤ 0.

---

## Suggestions

### S1 — `bulk_strip_and_filter` atom-key requirement is implicit
`lib/ad_butler/ads.ex`

`__schema__(:fields)` returns atom keys. A caller passing string-keyed maps silently drops all rows with only a Logger warning. Document the atom-key contract in the function's `@doc`, or add a runtime `is_atom(k)` assertion on the first map.

### S2 — `stream_active_meta_connections` chunk_size default mismatch
`lib/ad_butler/workers/sync_all_connections_worker.ex`

Called without `chunk_size:`, so `Repo.stream` uses the default 500 rows/page while `Stream.chunk_every(200)` batches into 200. Functional but confusing. Pass `chunk_size: 200` explicitly so the two numbers align.

### S3 — `wait_for_queue_depth` 500ms deadline may be too tight for CI
`test/mix/tasks/replay_dlq_test.exs`

RabbitMQ routing under CI load can exceed 500ms. Standard practice is 1500–2000ms. Raise the default deadline or extract `@wait_deadline_ms 1500` module attribute.

### S4 — N+1 batch fix not directly tested
`test/ad_butler/sync/metadata_pipeline_test.exs`

The metadata pipeline now calls `get_meta_connections_by_ids/1` once per batch (fixing N+1). No test asserts query count, so a future refactor could silently reintroduce N+1. Add an Ecto telemetry or `assert_called_once` assertion, or add a comment cross-referencing the fix.

### S5 — `RABBITMQ_POOL_SIZE` undocumented in deployment artifacts
No entry in `fly.toml [env]` block or deploy runbook. Add a commented-out line:
```toml
# RABBITMQ_POOL_SIZE = "5"  # optional, defaults to 5 workers
```

---

## Pre-existing (not introduced by this branch)

- **H1 (Security):** `access_token` passed as `params:` (URL query string) in 5 Meta API GET endpoints — `refresh_token` fix closed one endpoint only. Move all to `Authorization: Bearer` header.
- **M1 (Security):** `get_meta_connection/1` / `get_meta_connection!/1` are not user-scoped (IDOR risk if called from web context in future).
- **Oban:** `Oban.insert_all/1` changeset failures silently dropped with no count check.
- **Testing:** Magic-number `<= 215` in auth_controller truncation test (should be `<= 213` = 13 prefix + 200 chars).

---

## Verified Pass

- OAuth CSRF state: 256-bit entropy, `secure_compare`, 600s TTL, deleted on every outcome ✓
- Flash XSS: `put_flash` content auto-escaped by HEEx ✓
- Session fixation: `configure_session(renew: true)` on login, `drop: true` on logout ✓
- Live socket disconnect on logout ✓
- Rate limiting: OAuth callback behind `:rate_limited` (PlugAttack) ✓
- Session salt: 32-byte minimum enforced at build time ✓
- `refresh_token` moved from GET+params to POST+form ✓
- Token log hygiene: `safe_reason`, `@derive Inspect`, `:filter_parameters` all correct ✓
- `PublisherPool.init` reads runtime env correctly (not compile-time leak) ✓
- Dockerfile: multi-stage, non-root user, healthcheck, DB SSL verify_peer ✓
