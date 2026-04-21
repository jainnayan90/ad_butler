# Triage: Week 1 Review Fixes

**Source**: `.claude/plans/week-1-review-fixes/reviews/week-1-review-fixes-review.md`  
**Decision**: Fix everything — 25 items approved, 0 skipped  
**Guidance**: Just fix everything selected — no special instructions

---

## Fix Queue

### BLOCKERs (1)

- [ ] **B1** `create_meta_connection/2` missing `on_conflict` — returning user gets auth error
  - `lib/ad_butler/accounts.ex:32-36`
  - Add `on_conflict: {:replace, [:access_token, :token_expires_at, :scopes, :status, :updated_at]}, conflict_target: [:user_id, :meta_user_id], returning: true` to `Repo.insert/1`

### WARNINGs — Code (4)

- [ ] **W1** `{:cancel, :unauthorized}` atom reason inconsistent with JSON storage
  - `lib/ad_butler/workers/token_refresh_worker.ex:63-64`
  - Change `:unauthorized` and `:token_revoked` to string literals: `{:cancel, "unauthorized"}`, `{:cancel, "token_revoked"}`

- [ ] **W2** `schedule_next_refresh/2` silently drops `{:error, _}` from `Oban.insert/1`
  - `lib/ad_butler/workers/token_refresh_worker.ex:77-80`
  - Pattern-match result; log at `:error` on failure

- [ ] **W3** `update_meta_connection` result ignored on revoke/cancel path
  - `lib/ad_butler/workers/token_refresh_worker.ex:57`
  - Log warning when the DB call returns `{:error, _}`

- [ ] **W4** Session cookie missing `http_only`, `secure`, `encryption_salt`
  - `lib/ad_butler_web/endpoint.ex:7-12`
  - Add `http_only: true`, `secure: Mix.env() == :prod`, `encryption_salt: <new secret>`

### WARNINGs — Tests (4)

- [ ] **W5** `get_meta_connection/1` (non-bang) has zero test coverage
  - `test/ad_butler/accounts_test.exs`
  - Add test: `assert nil == Accounts.get_meta_connection("00000000-0000-0000-0000-000000000000")`

- [ ] **W6** `exchange_code/3` and `get_me/1` have no unit tests
  - `test/ad_butler/meta/client_test.exs`
  - Add describe blocks for happy + error paths (`:token_exchange_failed`, `:user_info_failed`, non-200 status)

- [ ] **W7** No test for re-auth `meta_connection` constraint in `auth_controller_test.exs`
  - `test/ad_butler_web/controllers/auth_controller_test.exs`
  - Add test: second OAuth callback for same Meta user → `redirected_to("/dashboard")` (after B1 fix)

- [ ] **W8** `parse_rate_limit_header/2` bare `with` swallows malformed JSON silently
  - `lib/ad_butler/meta/client.ex:228-232`
  - Add `else _ -> :ok` with a `:debug` Logger call, or add comment marking swallow as intentional

### Security (10)

- [ ] **S1** No `force_ssl`/HSTS in prod
  - `config/runtime.exs`
  - Add `config :ad_butler, AdButlerWeb.Endpoint, force_ssl: [hsts: true, rewrite_on: [:x_forwarded_proto]]` inside `if config_env() == :prod`

- [ ] **S2** Raw Meta response bodies leak via `inspect(reason)` in Oban exception telemetry
  - `lib/ad_butler/application.ex:60`
  - Replace `inspect(reason)` with `inspect(exception_kind(reason))` or sanitize via a helper like `log_safe_reason/1`

- [ ] **S3** OAuth state has no TTL (persists for full session lifetime)
  - `lib/ad_butler_web/controllers/auth_controller.ex:28`
  - Store `{state, System.system_time(:second)}`; in `verify_state/2` reject if age > 600s

- [ ] **S4** `get_me/1` fabricates `<id>@facebook.com` fallback email — can collide with unique index
  - `lib/ad_butler/meta/client.ex:147`
  - Remove fallback; allow `email: nil`; update `User.changeset` to not require email if meta_user_id present (or require email scope in OAuth)

- [ ] **S5** `meta_user_id` not validated in `User.changeset` — nil allowed in conflict_target
  - `lib/ad_butler/accounts/user.ex:19-25`
  - Add `validate_required([:email, :meta_user_id])` and `validate_format(:meta_user_id, ~r/^\d+$/)`

- [ ] **S6** `/dashboard` unprotected — no `require_authenticated_user` plug
  - `lib/ad_butler_web/router.ex`
  - Add authenticated pipeline and move `/dashboard` route inside it

- [ ] **S7** `live_socket_id` set but no broadcast-on-logout yet
  - `lib/ad_butler_web/controllers/auth_controller.ex:60` (new logout action needed)
  - Create `logout/2` action that calls `AdButlerWeb.Endpoint.broadcast("users_sessions:#{user_id}", "disconnect", %{})` then clears session

- [ ] **S8** `schedule_refresh/2` has no upper bound on `days`
  - `lib/ad_butler/workers/token_refresh_worker.ex:79`
  - Change to `days = min(max(div(expires_in_seconds, 86_400) - 10, 1), 60)`

- [ ] **S9** Add runtime assertion: CLOAK_KEY must not be all-zero bytes in prod
  - `config/runtime.exs`
  - After `Base.decode64!(System.fetch_env!("CLOAK_KEY"))`, raise if all bytes are zero

- [ ] **S10** No Content-Security-Policy header in browser pipeline
  - `lib/ad_butler_web/router.ex:10`
  - Update `put_secure_browser_headers` call with CSP map

### Suggestions (6)

- [ ] **Sug1** `verify_state/2` uses `if stored && ...` — non-idiomatic Elixir
  - `lib/ad_butler_web/controllers/auth_controller.ex:80`
  - Replace with `case` pattern-matching on `nil` vs value

- [ ] **Sug2** Magic numbers in `schedule_next_refresh/2` — extract to module attributes
  - `lib/ad_butler/workers/token_refresh_worker.ex:77`
  - `@seconds_per_day 86_400`, `@refresh_buffer_days 10`, `@min_refresh_days 1`

- [ ] **Sug3** Telemetry handler uses same message for `:discarded` and `:cancelled`
  - `lib/ad_butler/application.ex:37`
  - Split into two clauses: `Logger.error` for `:discarded`, `Logger.warning` for `:cancelled`

- [ ] **Sug4** `timeout/1` callback has no test
  - `test/ad_butler/workers/token_refresh_worker_test.exs`
  - `assert TokenRefreshWorker.timeout(%Oban.Job{}) == :timer.seconds(30)`

- [ ] **Sug5** `schedule_refresh/2` test only checks `scheduled_at != nil`
  - `test/ad_butler/workers/token_refresh_worker_test.exs`
  - Assert scheduled time is approximately `now + days * 86_400s`

- [ ] **Sug6** `client_test.exs` `async: false` has no explanatory comment
  - `test/ad_butler/meta/client_test.exs`
  - Add `# async: false — ETS table :meta_rate_limits is process-global`

---

## Skipped
_(none)_

## Deferred
_(none — all findings approved)_
