# Review: Week 1 Review Fixes

**Verdict**: REQUIRES CHANGES  
**Date**: 2026-04-21  
**Agents**: elixir-reviewer · security-analyzer · testing-reviewer · oban-specialist · iron-law-judge  
**Tests**: 31 pass ✓

---

## BLOCKERs (1)

### B1 — `create_meta_connection/2` has no `on_conflict` — returning user crashes on re-auth
**Files**: `lib/ad_butler/accounts.ex:32-36`  
**Confirmed by**: elixir-reviewer + iron-law-judge (independent)

`Repo.insert/1` has no `on_conflict` option. `MetaConnection` has `unique_constraint([:user_id, :meta_user_id])`. A user who authenticates a second time hits that constraint and gets `{:error, changeset}`, which propagates through the `with` chain to `"Authentication failed"`. This silently breaks every returning user.

```elixir
def create_meta_connection(user, attrs) do
  %MetaConnection{user_id: user.id}
  |> MetaConnection.changeset(attrs)
  |> Repo.insert(
    on_conflict: {:replace, [:access_token, :token_expires_at, :scopes, :status, :updated_at]},
    conflict_target: [:user_id, :meta_user_id],
    returning: true
  )
end
```

---

## WARNINGs (8)

### W1 — `{:cancel, :unauthorized}` atom reason inconsistent with JSON storage
**File**: `token_refresh_worker.ex:63-64`  
**Agents**: elixir-reviewer + oban-specialist

`perform_job/2` in tests works in-process (atoms), but Oban stores job errors as JSON. The cancelled job's `errors` column gets `":unauthorized"` (Elixir inspect) instead of `"unauthorized"`. Fix: use string literals.

```elixir
{:cancel, "unauthorized"}  # not {:cancel, :unauthorized}
```

### W2 — `schedule_next_refresh/2` silently breaks the scheduling chain on insert failure
**File**: `token_refresh_worker.ex:77-80`  
**Agent**: oban-specialist

If `Oban.insert/1` fails (DB pressure), self-scheduling breaks permanently with no log and no retry. Pattern-match the result and log on failure.

### W3 — `update_meta_connection` result ignored on revoke path
**File**: `token_refresh_worker.ex:57`  
**Agent**: oban-specialist

Job is cancelled regardless of whether the revoke update succeeds. If the DB call fails, the connection stays `active` but no job will ever fix it. At minimum, log a warning on `{:error, _}`.

### W4 — Session cookie missing `http_only`, `secure`, `encryption_salt`
**File**: `lib/ad_butler_web/endpoint.ex:7-12`  
**Agent**: security-analyzer (H1)

Session now carries `:user_id` and `:live_socket_id`. Without `http_only: true`, `secure: true` (prod), and `encryption_salt`, the session is signed-only and readable client-side.

### W5 — `get_meta_connection/1` (non-bang) has zero test coverage
**File**: `lib/ad_butler/accounts.ex:28-29`  
**Agent**: testing-reviewer

New public function with no test for the `nil` path. One-liner to add in `accounts_test.exs`.

### W6 — `exchange_code/3` and `get_me/1` have no unit tests
**File**: `test/ad_butler/meta/client_test.exs`  
**Agent**: testing-reviewer

Both new `Meta.Client` functions are only covered by controller integration tests (happy path). Error branches — `:token_exchange_failed`, `:user_info_failed`, timeout — are uncovered.

### W7 — No test for re-auth `meta_connection` constraint in `auth_controller_test.exs`
**Agent**: testing-reviewer (W2)

The B1 blocker above has no test coverage. Until B1 is fixed, this path fails silently. After fixing, add a test with a stubbed Meta API that triggers `create_meta_connection` twice for the same user.

### W8 — `parse_rate_limit_header/2` bare `with` swallows decode/shape errors silently
**File**: `lib/ad_butler/meta/client.ex:228-232`  
**Agent**: elixir-reviewer

No `else` clause — malformed JSON or unexpected response shape is discarded identically to a missing header. Add a `:debug` log or explicit comment.

---

## Security Findings (deferred to Week 2 hardening)

| ID | Severity | Issue | Location |
|----|----------|-------|----------|
| S1 | High | No force_ssl/HSTS in prod | `runtime.exs` |
| S2 | Med | Raw Meta response bodies leak into Oban exception telemetry via `inspect` | `application.ex:60` |
| S3 | Med | OAuth state has no TTL (full session lifetime) | `auth_controller.ex` |
| S4 | Med | `get_me/1` fabricates `<id>@facebook.com` email — can collide with unique index | `meta/client.ex:147` |
| S5 | Med | `meta_user_id` not validated in `User.changeset` — nil allowed in conflict_target | `user.ex:19-25` |
| S6 | Med | `/dashboard` unprotected — no `require_authenticated_user` plug | `router.ex` |
| S7 | Med | `live_socket_id` set but no broadcast-on-logout yet | `auth_controller.ex:60` |
| S8 | Low | `schedule_refresh/2` has no upper bound on `days` | `token_refresh_worker.ex:79` |
| S9 | Low | Add runtime assertion: CLOAK_KEY must not be all-zero bytes in prod | `runtime.exs` |
| S10 | Low | No Content-Security-Policy header | `router.ex` |

---

## Suggestions (defer unless quick wins)

- **verify_state/2**: replace `if stored && Plug.Crypto.secure_compare(...)` with a `case` with explicit `nil ->` clause (idiomatic Elixir)
- **Magic numbers in `schedule_next_refresh/2`**: extract `@seconds_per_day`, `@refresh_buffer_days`, `@min_refresh_days`
- **Telemetry handler**: split `:discarded` vs `:cancelled` into separate log messages with different severities
- **`timeout/1`**: add trivial test `assert TokenRefreshWorker.timeout(%Oban.Job{}) == 30_000`
- **`schedule_refresh/2` test**: assert scheduled time delta, not just `!= nil`
- **`client_test.exs`**: add `async: false` rationale comment

---

## Pre-Existing (not changed in this diff)

- ETS unbounded growth in `rate_limit_store.ex` — acknowledged with comment, pre-existing architectural debt
- `async: false` in `client_test.exs` without comment — pre-existing
