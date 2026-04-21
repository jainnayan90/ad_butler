# Review: week-1-security-fixes (Pass 2)

**Verdict: PASS WITH WARNINGS**
**Date**: 2026-04-21
**Agents**: elixir-reviewer · security-analyzer · testing-reviewer · oban-specialist

---

## Prior Findings — All Resolved

| Finding | Status |
|---------|--------|
| C1 — XFF List.first() attacker-controlled | ✅ RESOLVED |
| C2 — Same-user fast-exit skipped session rotation | ✅ RESOLVED |
| W1 — Sweep worker missing unique constraint | ✅ RESOLVED |
| W2 — Jitter range exceeded 23h uniqueness window | ✅ RESOLVED |
| W3 — Sweep worker test async:false unjustified | ✅ RESOLVED |
| W4 — accounts_test async:false too broad | ✅ RESOLVED |
| W5 — auth_controller_test on_exit deletes not restores | ✅ RESOLVED |
| W6 — Missing already-expired connection edge case | ✅ RESOLVED |

---

## New Findings

| # | Severity | Area | File | Description |
|---|----------|------|------|-------------|
| W1 | WARNING | Code quality | plug_attack.ex:11 | Nested `case` for client_ip; extract to private helpers |
| W2 | WARNING | Tests | accounts_authenticate_via_meta_test.exs | Only happy path covered; no error-path tests |
| W3 | WARNING | Config | config/config.exs:18 | Dead `live_view_signing_salt` app-key (Phoenix reads only endpoint key) |
| S1 | SUGGESTION | Security | plug_attack.ex:25 | Rate-limit bucket has no route discriminator; shared across all OAuth routes |
| S2 | SUGGESTION | Code quality | auth_controller.ex:82 | Redundant `delete_session(:oauth_state)` — immediately wiped by `clear_session()` |
| PRE | PRE-EXISTING | Oban | token_refresh_worker.ex:55 | `{:error, :schedule_failed}` after successful DB update triggers unnecessary retry |

---

## Warnings

### W1 — Nested `case` in `plug_attack.ex` should be private helpers

**File**: `lib/ad_butler_web/plugs/plug_attack.ex:11-23`

Two nested `case` expressions make the rule body hard to read. PlugAttack macro rules support `defp` helpers in the same module:

```elixir
defp client_ip(conn) do
  case Plug.Conn.get_req_header(conn, "fly-client-ip") do
    [ip | _] -> ip
    [] -> xff_ip(conn)
  end
end

defp xff_ip(conn) do
  case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
    [forwarded | _] ->
      forwarded |> String.split(",") |> Enum.map(&String.trim/1) |> List.last()
    [] ->
      conn.remote_ip |> :inet.ntoa() |> to_string()
  end
end
```

Then the rule body becomes: `throttle(client_ip(conn), ...)`.

### W2 — `accounts_authenticate_via_meta_test.exs` only tests the happy path

**File**: `test/ad_butler/accounts_authenticate_via_meta_test.exs`

Single test covers new-user creation. Missing:
- `exchange_code` 4xx → verify `{:error, _}` returned (not raised)
- `get_me` failure
- Existing user upsert — confirm token/name/email replaced, not duplicated

### W3 — Dead `live_view_signing_salt` app-key in `config/config.exs`

**File**: `config/config.exs:18`

```elixir
# Phoenix never reads this key — remove it:
config :ad_butler,
  live_view_signing_salt: "27ZZYgxL"   # dead

# Phoenix reads this key:
config :ad_butler, AdButlerWeb.Endpoint,
  live_view: [signing_salt: "27ZZYgxL"]  # active
```

Same dead key exists in `config/prod.exs`. On future rotations it's easy to update one and forget the other, creating false confidence.

---

## Suggestions

### S1 — Rate-limit bucket shared across all OAuth routes

**File**: `lib/ad_butler_web/plugs/plug_attack.ex:25`

Bucket key is `client_ip` with no route discriminator. A flood on `/auth/logout` blocks `/auth/meta/callback` for users behind the same NAT. Consider `{client_ip, conn.request_path}` as the throttle key, with a tighter limit (~5/min) on the callback route.

### S2 — Redundant `delete_session(:oauth_state)` in `verify_state/2`

**File**: `lib/ad_butler_web/controllers/auth_controller.ex:82`

`verify_state/2` returns `{:ok, delete_session(conn, :oauth_state)}` but the caller immediately runs `clear_session()` which wipes everything. The `delete_session` call is harmless but misleading — it implies precision that doesn't exist. Simplify to `{:ok, conn}`.

---

## Pre-existing (not introduced by this branch)

### PRE — `token_refresh_worker.ex` returns `{:error, :schedule_failed}` after successful DB update

**File**: `lib/ad_butler/workers/token_refresh_worker.ex:55` (unchanged in this branch)

When the token is successfully refreshed in the DB but `schedule_next_refresh` fails, the worker returns `{:error, :schedule_failed}`. Oban retries the entire job, calling `refresh_token` again — unnecessary if the token was already updated. Fix: return `:ok` (or `{:cancel, "sweep will recover"}`) when the primary operation succeeded. **Not introduced by this branch; track separately.**

---

## Security Verification Summary

Both critical fixes confirmed correct:
- **XFF**: `fly-client-ip` (stripped by Fly at edge) → `List.last()` of XFF (proxy-appended) → `conn.remote_ip`. Correct for Fly.io.
- **Session**: `clear_session() |> configure_session(renew: true)` on every successful OAuth callback. Complete session fixation protection for signed-cookie sessions.

All other security checks clean: `^` pinning, no `String.to_atom`, no `raw/1`, CSRF guard in browser pipeline, session cookie flags (`http_only`, `secure: Mix.env() == :prod`, `same_site: "Lax"`), salt rotation valid.
