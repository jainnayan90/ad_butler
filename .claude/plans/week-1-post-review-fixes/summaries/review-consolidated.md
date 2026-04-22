# Consolidated Review Summary

**Strategy**: Compress
**Input**: 5 files, ~8.7k tokens
**Output**: ~3.2k tokens (63% reduction)

---

## BLOCKERS (Production Safety)

### Deployment Blockers — Must Fix Before Ship

**B1 — Database SSL disabled in production** (`config/runtime.exs:57`)
- Production DB connections are unencrypted
- Fix: Enable `ssl: true` with peer verification
  ```elixir
  ssl: true,
  ssl_opts: [verify: :verify_peer, cacerts: :public_key.cacerts_get()]
  ```

**B2 — Duplicate and conflicting `force_ssl` config** (`config/prod.exs:13-18` AND `config/runtime.exs:45-46`)
- Runtime overwrites prod at boot, dropping localhost exclude list
- Breaks internal/health-check traffic
- Fix: Remove from prod.exs; consolidate in runtime.exs with full exclude list

**B3 — Insecure cookie flag set at compile time** (`lib/ad_butler_web/endpoint.ex:14`)
- `secure: Mix.env() == :prod` evaluated at compile time
- Risk: artifacts built with `MIX_ENV != prod` promoted to production have `secure: false`
- Fix: Ensure all production builds use `MIX_ENV=prod` or move to runtime.exs

---

### Critical Functional Blockers

**1. `schedule_next_refresh/2` failure silently returns `:ok`** (confirmed by elixir.md + oban.md)
- **Location**: `token_refresh_worker.ex:43`, `schedule_next_refresh/2`
- **Impact**: Successfully-refreshed tokens can be orphaned forever if scheduling fails (DB contention, unique constraint race)
- **Current behavior**: Logs error but returns `:ok` to Oban (no retry)
- **Unique constraint block**: `unique: [period: {23, :hours}]` prevents re-scheduling for 23 hours, no recovery path
- **Fix**: Return `{:error, :schedule_failed}` from `perform/1` to trigger Oban retry. On retry, token is fresh so refresh is a no-op and scheduling should succeed.

**2. `require_authenticated_user` plug doesn't verify user exists** (confirmed by elixir.md + security.md)
- **Location**: `router.ex:45-53`
- **Issues**:
  - Only checks if `user_id` session key exists, not if user row still exists in DB
  - Deleted/banned users still reach protected routes until cookie expiry
  - Does not assign `current_user` to conn.assigns (required by all authenticated LiveViews)
  - Private router function can't be tested; should be module plug
- **Fix**: Extract to `AdButlerWeb.Plugs.RequireAuthenticated` module plug that:
  - Loads user from DB by session `:user_id`
  - Drops session and redirects if not found
  - Assigns `:current_user` for downstream handlers

**3. Hard-coded 60-day token TTL ignores actual `expires_in` from Meta** (confirmed by elixir.md + testing.md)
- **Location**: `auth_controller.ex:10`, `@meta_long_lived_token_ttl_seconds = 60 * 24 * 60 * 60`
- **Problem**: Meta exchange response includes `expires_in` but controller ignores it
- **Impact**: `token_expires_at` stored wrong for initial connections; `schedule_next_refresh` uses stale data on first job run
- **Fix**: Use `expires_in` from exchange response instead of constant

**4. Inner case result discarded silently** (`token_refresh_worker.ex:61-78`)
- **Issue**: `{:error, err}` branch returns `Logger.warning/2` (which is `:ok`), falls through unconditionally
- **Consequence**: Unused return value; Credo will flag; functionally correct but misleading
- **Fix**: Use `_ = case ...` or extract to helper function

---

## WARNINGS

**W1 — OAuth state validation conflates two failure modes** (`auth_controller.ex:87`)
- Uses `if` with `&&` to check both expiry (600s TTL) and value mismatch
- Impossible to log/handle them differently
- Fix: Use `cond` with separate branches, avoids short-circuit Credo issues

**W2 — Business logic in controller** (`auth_controller.ex:43-44`)
- Token exchange + user info fetching belong in `Accounts` module, not controller
- Controller should call something like `Accounts.authenticate_via_meta/2`

**W3 — Inconsistent credential loading** (`auth_controller.ex:39-40,44`)
- Controller reads `meta_app_id`/`meta_app_secret` and passes to `Client.exchange_code/3`
- But `Client.refresh_token/1` reads them internally
- Fix: Move credential loading into `exchange_code/3` to match `refresh_token/1` pattern

**W4 — Timeout marginal for cold Meta API calls** (`token_refresh_worker.ex`)
- Current: 30 seconds
- Meta Graph API can take 10–20s under load
- Fix: Use `:timer.seconds(60)` or `:timer.minutes(2)`

**W5 — Max attempts too low for infrastructure-critical task** (`token_refresh_worker.ex`)
- Current: 3 attempts
- Multi-hour Meta outage exhausts retries in ~5 min
- Fix: Raise to 5, or create dedicated `token_refresh` queue

**W6 — No recovery cron for orphaned connections** (oban.md)
- No `Oban.Plugins.Cron` configured
- If scheduling fails or a connection lacks a scheduled job, no sweep job exists
- Fix: Configure cron plugin with periodic requeue of stale connections

**W7 — `PHX_HOST` silently defaults to `"example.com"`** (`runtime.exs:77`)
- Should be required environment variable
- Fix: `System.get_env("PHX_HOST") || raise "PHX_HOST is required"`

**W8 — `CLOAK_KEY` crashes dev without config** (`config/runtime.exs`)
- Guard is `config_env() != :test` so dev also needs the env var
- Fix: Move Vault runtime config to prod only; add static dev key in `config/dev.exs`

**W9 — Session salts committed to repo** (`endpoint.ex:10-11`, `config/config.exs:23`)
- `signing_salt`, `encryption_salt`, `live_view.signing_salt` are in git history
- Anyone with repo access + leaked `SECRET_KEY_BASE` can forge sessions
- Fix: Load from environment in `runtime.exs`; rotate current values since already exposed

**W10 — OAuth callback allows login-CSRF and session fixation** (`auth_controller.ex:38-61`)
- `state` only proves same browser started flow, not that flow is legitimate
- Attacker can initiate flow on victim's browser, victim authenticates as attacker
- Callback silently overwrites existing `:user_id` (account linking without user consent)
- Fix: Treat callback as account-link if session already has `:user_id`; add rate limiting (see M4); require POST+CSRF to initiate flow

**W11 — Redundant session operations on login** (`auth_controller.ex:56-61`)
- Both `configure_session(renew: true)` AND `clear_session()` mutate the session
- Makes flash/CSRF lifecycle ambiguous
- Fix: Use `configure_session(renew: true) |> put_session(:user_id, user.id) |> put_session(:live_socket_id, ...)`

---

## TEST COVERAGE GAPS (Critical Paths Untested)

**1. `AuthController.logout/2` — zero coverage**
- No `describe "DELETE /auth/logout"` in auth_controller_test.exs
- Both authenticated and unauthenticated branches untested
- Function drops session and broadcasts `"disconnect"`

**2. State TTL expiry path** (`auth_controller_test.exs`)
- Only state-invalid test uses mismatched string, not expired `issued_at`
- Fix: Inject `issued_at = System.system_time(:second) - 700` to cover expiry

**3. `TokenRefreshWorker` edge cases** (confirmed by testing.md + oban.md)
- 60-day upper-bound clamp (`@max_refresh_days`) — no test passes `expires_in >= 70 * 86_400`
- `:unauthorized` DB-update failure path (revoked-status update errors)
- Generic `{:error, reason}` path (non-rate-limit, non-unauthorized transient failures)
- Scheduling failure path (exposes the silent `:ok` return)
- `expires_in: 0` (clamped to 1 day) and `expires_in: 70 * 86_400` (clamped to 60 days)
- `:token_revoked` branch (only `:unauthorized` tested despite shared clause)

**4. Minor test hygiene issues**
- Hardcoded `meta_user_id: "999002"` in accounts_test.exs:141 (use `sequence/2`)
- Race condition in `schedule_refresh/2` test (capture reference time *before* insert)
- `get_meta_connection/1` describe only tests not-found; add found-case
- `create_or_update_user/1` with `email: nil` not tested (Meta.Client.get_me returns nil)

---

## SUGGESTIONS (Compress: Group Similar)

**Code Quality (5 items)**
- Add fallback clause to `TokenRefreshWorker.perform/2` to handle invalid args (prevents FunctionClauseError)
- Normalize cancel reason strings (`cancel_reason/1` helper)
- Compare `status` as `Ecto.Enum` type instead of string in queries
- Wrap `mocks.ex` in `defmodule AdButler.Mocks` for dialyzer hygiene
- Add `# Req <2.0 vs >=2.0` comment explaining header format handling in meta/client.ex

**Oban Configuration (2 items)**
- Add `dispatch_cooldown: 500` to `:default` queue to smooth token expiry bursts
- Add fallback clause pattern for args validation

---

## Coverage by File

| File | Represented | Key Issues |
|---|---|---|
| testing.md | Yes | 4 critical gaps, 4 warnings, 3 suggestions |
| elixir.md | Yes | 3 critical (hard-coded TTL, schedule failure, auth plug), 4 warnings, 3 suggestions |
| oban.md | Yes | 1 critical (schedule failure confirmed), 4 warnings, 3 suggestions |
| deploy.md | Yes | **3 blockers (B1, B2, B3)**, 3 warnings |
| security.md | Yes | 4 high-severity findings, 5 medium findings |

---

## Deconflicted Findings

- **`schedule_next_refresh` failure** — consolidated from elixir.md + oban.md; oban.md provided impact analysis
- **`TokenRefreshWorker` test coverage** — consolidated from testing.md + oban.md coverage gaps
- **`require_authenticated_user` deficiencies** — consolidated from elixir.md + security.md H2
- **Hard-coded TTL problem** — confirmed by elixir.md + testing.md; elixir.md provided full context
