# Review: week-1-security-fixes

**Verdict: REQUIRES CHANGES**
**Date**: 2026-04-21
**Agents**: elixir-reviewer · security-analyzer · testing-reviewer · oban-specialist · iron-law-judge

---

## Issue Summary

| # | Severity | Area | File | Description |
|---|----------|------|------|-------------|
| C1 | CRITICAL | Security | plug_attack.ex:9 | XFF `List.first()` is attacker-controlled — rate limit bypassable |
| C2 | CRITICAL | Security | auth_controller.ex:41 | Same-user fast-exit skips `clear_session()` — partial session fixation |
| W1 | WARNING | Oban | token_refresh_sweep_worker.ex:2 | Sweep worker has no `unique:` — concurrent runs possible |
| W2 | WARNING | Oban | token_refresh_sweep_worker.ex:43 | 24h jitter exceeds 23h uniqueness window — duplicate jobs possible |
| W3 | WARNING | Tests | token_refresh_sweep_worker_test.exs:2 | `async: false` not justified — no global state used |
| W4 | WARNING | Tests | accounts_test.exs:2 | `async: false` too broad — all tests slowed for one describe block |
| W5 | WARNING | Tests | auth_controller_test.exs:16 | `on_exit` deletes env vars instead of restoring original values |
| W6 | WARNING | Tests | token_refresh_sweep_worker_test.exs | Missing edge case: already-expired connections |
| S1 | SUGGESTION | Config | config.exs:28 | `live_view_signing_salt` app-key is unused; endpoint reads only the nested key |
| S2 | SUGGESTION | Security | plug_attack.ex:14 | Single rate-limit bucket for all OAuth routes; consider per-route keys |
| S3 | SUGGESTION | Oban | sweep_worker_test.exs | No test verifies `scheduled_at > utc_now` for jitter behaviour |

---

## Critical Issues

### C1 — XFF `List.first()` is attacker-controlled (CONFIRMED by 3 agents)

**File**: `lib/ad_butler_web/plugs/plug_attack.ex:9-12`

Fly.io *appends* its verified hop to `X-Forwarded-For` — it does not replace the header. The leftmost value is whatever the client sends. `List.first()` picks the client-controlled value; an attacker rotates it freely and never fills their bucket.

```
Client sends:         X-Forwarded-For: 1.2.3.4
Fly appends:          X-Forwarded-For: 1.2.3.4, <real-client-ip>
List.first picks:     1.2.3.4   ← attacker-controlled
```

**Fix — prefer `fly-client-ip` (Fly strips client-supplied values), fallback to `List.last()` of XFF:**

```elixir
client_ip =
  case Plug.Conn.get_req_header(conn, "fly-client-ip") do
    [ip | _] -> ip
    [] ->
      case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
        [value | _] -> value |> String.split(",") |> Enum.map(&String.trim/1) |> List.last()
        [] -> conn.remote_ip |> :inet.ntoa() |> to_string()
      end
  end
```

### C2 — Same-user fast-exit bypasses session rotation

**File**: `lib/ad_butler_web/controllers/auth_controller.ex:41-49`

```elixir
if get_session(conn, :user_id) == user.id do
  redirect(conn, to: ~p"/dashboard")   # ← no clear_session, no renew
else
  conn
  |> clear_session()
  |> configure_session(renew: true)
  ...
end
```

If an attacker fixates a session and the victim is already authenticated (same user ID), the callback takes the fast path without rotating the session. The fixated cookie remains valid.

**Fix**: Remove the fast-exit branch entirely. Always rotate:

```elixir
conn
|> clear_session()
|> configure_session(renew: true)
|> put_session(:user_id, user.id)
|> put_session(:live_socket_id, "users_sessions:#{user.id}")
|> redirect(to: ~p"/dashboard")
```

---

## Warnings

### W1 — Sweep worker missing `unique:` constraint

**File**: `lib/ad_butler/workers/token_refresh_sweep_worker.ex:2`

No uniqueness guard. Cron fires every 6 hours. If a sweep is still `retryable` when the next tick fires, two sweeps run concurrently. Child jobs are deduplicated by `TokenRefreshWorker`, so correctness is preserved — but there is unnecessary duplicate load.

**Fix**:
```elixir
use Oban.Worker,
  queue: :default,
  max_attempts: 3,
  unique: [period: {6, :hours}, fields: [:worker]]
```

### W2 — Jitter range exceeds uniqueness window

**File**: `lib/ad_butler/workers/token_refresh_sweep_worker.ex:43`

`:rand.uniform(86_400)` = 0–86400 seconds (up to 24h). `TokenRefreshWorker` unique period is 23h, anchored to `inserted_at`. A job jittered to 23h+ is outside the uniqueness window when the next sweep runs 6h later — a second job is inserted.

**Fix**: Reduce to `:rand.uniform(3_600)` (1 hour). Sufficient to prevent thundering herd; well within the 23h window.

### W3 — Sweep worker test unnecessarily `async: false`

**File**: `test/ad_butler/workers/token_refresh_sweep_worker_test.exs:2`

No `Application.put_env`, no `Req.Test.stub`, no ETS global state. All isolation comes from the Ecto SQL sandbox. Change to `async: true`.

### W4 — `accounts_test.exs` `async: false` blast radius too broad

**File**: `test/ad_butler/accounts_test.exs:2`

Only the `authenticate_via_meta/1` describe block uses `Application.put_env` (global state). The other 10 tests touch only the DB. Extracting `authenticate_via_meta` tests into a separate module (`AdButler.AccountsAuthTest, async: false`) restores concurrency for the main test module.

### W5 — `auth_controller_test.exs` `on_exit` deletes instead of restoring

**File**: `test/ad_butler_web/controllers/auth_controller_test.exs:16-21`

`config/test.exs` may set `meta_app_id` etc. already. `Application.delete_env` in `on_exit` would remove values that existed before the test. Should use the same `restore_or_delete` pattern introduced in `client_test.exs`.

### W6 — Missing edge case: already-expired connections

**File**: `test/ad_butler/workers/token_refresh_sweep_worker_test.exs`

`token_expires_at < ^threshold` also matches past dates (expired connections). No test covers `token_expires_at` in the past. Add:

```elixir
test "enqueues refresh job for already-expired connection" do
  conn = insert(:meta_connection,
    status: "active",
    token_expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
  )
  assert :ok = perform_job(TokenRefreshSweepWorker, %{})
  assert_enqueued worker: AdButler.Workers.TokenRefreshWorker,
    args: %{"meta_connection_id" => conn.id}
end
```

---

## Suggestions

### S1 — `live_view_signing_salt` app-key appears unused

**File**: `config/config.exs:18` and `config/prod.exs`

`config :ad_butler, live_view_signing_salt: "..."` is set alongside `config :ad_butler, AdButlerWeb.Endpoint, live_view: [signing_salt: "..."]`. Phoenix reads the endpoint key; the top-level app key creates a silent drift risk on future rotations (rotate one, forget the other).

### S2 — Single rate-limit bucket for all OAuth routes

**File**: `lib/ad_butler_web/plugs/plug_attack.ex`

Both `/auth/meta` (start) and `/auth/meta/callback` share one bucket. A composite `{path, ip}` key or separate rules per endpoint would tighten limits on the more sensitive callback endpoint.

### S3 — Sweep worker test doesn't verify jitter scheduling

**File**: `test/ad_butler/workers/token_refresh_sweep_worker_test.exs`

`perform_job/2` bypasses actual job insertion. Consider a supplemental test calling `Oban.insert/1` directly and asserting `scheduled_at > DateTime.utc_now()`.

---

## Passing (no issues)

- `clear_session() |> configure_session(renew: true) |> put_session(...)` order is correct (cookie sessions)
- Salt rotation is valid — salts are HKDF inputs, not secrets; leaking them without `SECRET_KEY_BASE` is harmless
- `runtime.exs` guard change (`== :prod`) is correct and safe
- `validate_length` removal has no gap — `~r/^[1-9]\d{0,19}$/` enforces max 20 chars
- OAuth state uses 256-bit entropy, `secure_compare`, 10-min TTL, single-use delete — adequate
- All Ecto queries use `^` pinning correctly
- No `String.to_atom` with user input; no `raw/1` with untrusted content
- `schedule_in: integer` for Oban is correct (treated as seconds)
- `restore_or_delete/2` pattern in `client_test.exs` is correct
