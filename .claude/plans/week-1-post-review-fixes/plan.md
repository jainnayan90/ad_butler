# Plan: Week 1 Post-Review Fixes

**Source**: `.claude/plans/week-1-review-fixes/reviews/week-1-review-fixes-triage.md`  
**Findings**: 1 BLOCKER · 8 WARNINGs · 10 Security · 6 Suggestions (25 total)  
**Phases**: 3 · **Tasks**: 25

---

## Phase 1: Correctness [7 tasks]

> Fix the re-auth crash (BLOCKER), Oban worker correctness issues,
> and a silent error-swallow in the rate-limit header parser.
> All changes isolated to `accounts.ex`, `token_refresh_worker.ex`,
> `application.ex`, and `meta/client.ex`.

- [x] [P1-T1] **B1** Add upsert to `create_meta_connection/2` — `on_conflict: {:replace, [...]}, conflict_target: [:user_id, :meta_user_id], returning: true`

- [x] [P1-T2] **W1** Replace `{:cancel, :unauthorized}` / `{:cancel, :token_revoked}` with string literals via `Atom.to_string/1` — `token_refresh_worker.ex`

- [x] [P1-T3] **W2** Pattern-match result of `schedule_refresh/1` in `schedule_next_refresh/2`; log `:error` on failure — `token_refresh_worker.ex`

- [x] [P1-T4] **W3** Pattern-match result of `update_meta_connection` on revoke branch; log `:warning` on `{:error, _}` — `token_refresh_worker.ex`

- [x] [P1-T5] **W8** Add `else _ -> :ok` to bare `with` in `parse_rate_limit_header/2` — `meta/client.ex`

- [x] [P1-T6] **Sug2** Extracted magic numbers: `@seconds_per_day`, `@refresh_buffer_days`, `@min_refresh_days`, `@max_refresh_days` — `token_refresh_worker.ex`

- [x] [P1-T7] **Sug3** Split telemetry handler: `Logger.error` for `:discarded`, `Logger.warning` for `:cancelled` — `application.ex`

---

## Phase 2: Test Coverage [6 tasks]

> Add missing tests for new public functions and fixed paths.
> Phase 1 must complete first (W7 test requires B1 fix in place).

- [x] [P2-T1] **W5** Added `get_meta_connection/1` nil test — `test/ad_butler/accounts_test.exs`

- [x] [P2-T2] **W6** Added `exchange_code/3` and `get_me/1` describes (happy + error + missing email) — `test/ad_butler/meta/client_test.exs`

- [x] [P2-T3] **W7** Added second OAuth callback upsert test — `test/ad_butler_web/controllers/auth_controller_test.exs`

- [x] [P2-T4] **Sug4** Added `timeout/1` test; also fixed `{:cancel, :unauthorized}` → `{:cancel, "unauthorized"}` assertion — `test/ad_butler/workers/token_refresh_worker_test.exs`

- [x] [P2-T5] **Sug5** Updated `schedule_refresh/2` test with `assert_in_delta` time check — `test/ad_butler/workers/token_refresh_worker_test.exs`

- [x] [P2-T6] **Sug6** Added `# async: false — :meta_rate_limits ETS table is process-global` comment — `test/ad_butler/meta/client_test.exs`

---

## Phase 3: Security Hardening [12 tasks]

> Harden session cookies, add authentication pipeline, add logout,
> remove the fake-email fallback, add HSTS/CSP, and add remaining
> validations and guards. Multiple files touched.

- [x] [P3-T1] **W4** Added `http_only: true`, `secure: Mix.env() == :prod`, `encryption_salt` to `@session_options` — `endpoint.ex`

- [x] [P3-T2] **Sug1** Replaced `if stored && ...` with `case` in `verify_state/2`; explicit `nil ->` and catch-all clauses — `auth_controller.ex`

- [x] [P3-T3] **S3** Store `{state, System.system_time(:second)}` in session; reject if age > 600s — `auth_controller.ex`

- [x] [P3-T4] **S4+S5** Added `email` scope; removed `|| "#{id}@facebook.com"` fallback; added `validate_required([:email, :meta_user_id])` and `validate_format(:meta_user_id, ~r/^\d+$/)` — `auth_controller.ex`, `meta/client.ex`, `accounts/user.ex`

- [x] [P3-T5] **S2** Replaced `inspect(reason)` with `log_safe_reason/1` in `application.ex` exception handler

- [x] [P3-T6] **S8** Added `@max_refresh_days 60` upper bound in `schedule_next_refresh/2` — `token_refresh_worker.ex`

- [x] [P3-T7] **S6+S7** Added `:authenticated` pipeline with `require_authenticated_user` plug; moved `/dashboard` behind it; added `logout/2` action with live socket broadcast — `router.ex`, `auth_controller.ex`

- [x] [P3-T8] **S1** Added `force_ssl: [hsts: true, rewrite_on: [:x_forwarded_proto]]` in prod block — `config/runtime.exs`

- [x] [P3-T9] **S9** Added `byte_size(cloak_key) != 32` guard after `Base.decode64!` — `config/runtime.exs`

- [x] [P3-T10] **S10** Added CSP map to `put_secure_browser_headers` in browser pipeline — `router.ex`

- [x] [P3-T11] **S7 (live_socket)** Logout broadcasts `"users_sessions:#{user_id}"` disconnect before clearing session — `auth_controller.ex`

- [x] [P3-T12] **S9 (test guard)** Replaced all-zero Cloak key with `"ad_butler_test_key_for_testing!!"` (32-byte ASCII) — `config/test.exs`

---

## Verification (per phase)

After each phase: `mix compile --warnings-as-errors && mix format --check-formatted`  
After Phase 2: `mix test test/ad_butler/ test/ad_butler_web/`  
After Phase 3: `mix test` (full suite)

---

## Risks

1. **P3-T3 (state TTL)** changes the session value format from a binary string to a `{string, integer}` tuple. Any in-flight session at deploy time will fail `verify_state/2` (old binary won't pattern-match the new format). Deploy with short rolling window or clear sessions before deploying.

2. **P3-T4 (email scope)** adds `email` to the OAuth scope — users who previously authorized without `email` will see a new permissions prompt on re-auth. Acceptable UX trade-off to remove the fake-email fallback.

3. **P3-T7 (/dashboard auth plug)** will break the existing `GET /dashboard` test in `PageController` if one exists. Verify `page_controller_test.exs` and update to use authenticated session.

4. **P3-T1 (encryption_salt)** — the value in the plan above is a placeholder. Generate a unique value with `mix phx.gen.secret 32` before committing.
