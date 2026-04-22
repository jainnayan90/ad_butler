# AdButler Project Health Audit

**Date:** 2026-04-21  
**Branch:** week-01-Day-01-05-Authentication  
**Stage:** Week 1 — Auth foundations complete  

---

## Overall Health Score: 74 / 100 — B-

| Category | Score | Grade |
|----------|-------|-------|
| Architecture | 74/100 | B- |
| Performance | 72/100 | C+ |
| Security | 82/100 | B+ |
| Tests | 68/100 | C+ |
| Dependencies | 72/100 | C+ |
| **Overall** | **74/100** | **B-** |

Strong auth security baseline. Score held back by one production crash bug, missing test coverage on security-critical plugs, performance gaps in the sweep path, and hardcoded salts in prod config.

---

## 🔴 Fix Before Merging (3)

### A1. PageController missing `:dashboard` action — 500 on every login
**Category:** Architecture | **File:** `lib/ad_butler_web/controllers/page_controller.ex`  
Router routes `GET /dashboard` to `PageController, :dashboard` but only `home/2` is implemented. Every authenticated user who logs in successfully gets a 500. This is the first thing they see after OAuth.

### A2. Changeset with plaintext access_token logged in worker
**Category:** Security | **File:** `lib/ad_butler/workers/token_refresh_worker.ex:69-72`  
`Logger.error(..., reason: reason)` on `update_meta_connection` failure logs the full `Ecto.Changeset`. The changeset's `changes` map carries the plaintext `access_token` (pre-Cloak-encryption). `filter_parameters` does not scrub Logger metadata.  
Fix: `reason: inspect(changeset.errors)` instead of the full changeset.

### A3. Session salts hardcoded in committed prod config
**Category:** Security | **File:** `config/prod.exs:21-25`  
`session_signing_salt`, `session_encryption_salt`, and `live_view: [signing_salt:]` are committed strings. Rotation requires a code change + redeploy. Move to `runtime.exs` via `System.fetch_env!`.

---

## ⚠️ Fix Soon (8)

### B1. Sweep worker bypasses Accounts context — queries Repo directly
**Category:** Architecture | **File:** `lib/ad_butler/workers/token_refresh_sweep_worker.ex`  
Imports `Ecto.Query`, aliases `Repo`, queries `MetaConnection` raw. Any future soft-delete, status filter, or index added to `Accounts` won't apply to the sweep path.  
Fix: add `Accounts.list_expiring_meta_connections/0` and call it from the worker.

### B2. Missing `token_expires_at` index on meta_connections
**Category:** Performance | **File:** `priv/repo/migrations/`  
Sweep worker filters on `(status, token_expires_at)` — full table scan every 6 hours.  
Fix: `create index(:meta_connections, [:status, :token_expires_at])` (partial `WHERE status = 'active'` preferred).

### B3. Unbounded `Repo.all` in sweep worker
**Category:** Performance | **File:** `lib/ad_butler/workers/token_refresh_sweep_worker.ex:24`  
No `limit` or cursor. Will load every active expiring connection at once at scale.  
Fix: add `|> limit(500)` and process in batches, or use `Repo.stream` in a transaction.

### B4. `RequireAuthenticated` plug has zero tests
**Category:** Tests | **File:** `lib/ad_butler_web/plugs/require_authenticated.ex`  
Guards every authenticated route. Three paths untested: anonymous, deleted user, valid session.  
Fix: add `test/ad_butler_web/plugs/require_authenticated_test.exs`.

### B5. `PlugAttack` rate-limit rule has zero tests
**Category:** Tests | **File:** `lib/ad_butler_web/plugs/plug_attack.ex`  
10 req/60s OAuth throttle never exercised. Regression would silently remove DDoS protection.

### B6. Untested public Accounts functions
**Category:** Tests | **File:** `lib/ad_butler/accounts.ex`  
`get_user/1`, `get_user!/1`, `get_user_by_email/1` — all called in production paths, none tested.

### B7. DB round-trip on every authenticated request
**Category:** Performance + Architecture | **File:** `lib/ad_butler_web/plugs/require_authenticated.ex:16`  
`Accounts.get_user/1` (= `Repo.get/2`) runs synchronously per request. Acceptable now; becomes a bottleneck with LiveView reconnects and connection pool pressure.  
Fix (short-term): ETS-backed cache with short TTL; (long-term): signed token with embedded immutable fields.

### B8. Accounts context calls Meta.Client concrete module — bypasses mock dispatch
**Category:** Architecture | **File:** `lib/ad_butler/accounts.ex:12-13`  
`authenticate_via_meta/1` calls `Meta.Client.exchange_code/1` and `Meta.Client.get_me/1` directly, while `TokenRefreshWorker` uses `Application.get_env(:meta_client)` indirection. Two different mocking mechanisms in play.  
Fix: use `meta_client()` helper in `Accounts` consistently.

---

## 💡 Suggestions (9)

| # | Category | Finding |
|---|----------|---------|
| S1 | Architecture | `Meta.Client` is 258 lines mixing OAuth + Graph API + rate-limit parsing — split into `Meta.Auth` and `Meta.Graph` before Day 2 |
| S2 | Architecture | Session salts read via `Application.compile_env!` — rotation requires rebuild; move to `runtime.exs` |
| S3 | Performance | No dedicated Finch pool for Meta API — shared default pool causes contention under 10+ concurrent Oban workers |
| S4 | Performance | Both Oban workers use `default` queue — add dedicated `token_refresh` queue (concurrency 5) to isolate sweep bursts |
| S5 | Tests | `Meta.Client` callbacks `list_campaigns/3`, `list_ad_sets/3`, `list_ads/3`, `get_creative/2`, `refresh_token/1` tested only via mocks — no live-client tests |
| S6 | Tests | ETS `"act_123"` entry leaks between tests — add `on_exit` cleanup in `client_test.exs` |
| S7 | Tests | Three `ConnCase` files missing `async: true` (`error_html`, `error_json`, `page_controller`) |
| S8 | Deps | `postgrex >= 0.0.0` and `lazy_html >= 0.1.0` unconstrained — pin to `~> 0.22` and `~> 0.1` |
| S9 | Deps | `phoenix_live_view ~> 1.1.0` too tight — change to `~> 1.1` to allow minor upgrades |

---

## Cross-Category Correlations

| Finding | Categories affected |
|---------|-------------------|
| `RequireAuthenticated` untested + DB-per-request | Tests + Performance + Security |
| ETS rate-limit table unbounded | Architecture + Security + Performance |
| Hardcoded salts in prod | Security + Architecture |
| Sweep worker direct Repo | Architecture + Performance |
| `Meta.Client` mock inconsistency | Architecture + Tests |

---

## Action Plan

### Immediate (before first user)
1. Add `PageController.dashboard/2` (A1) — 5 min fix
2. Fix changeset logging in worker (A2) — 2 min
3. Move session salts to `runtime.exs` (A3)

### This week
4. Add `token_expires_at` index migration (B2)
5. Add `Accounts.list_expiring_meta_connections/0`, update sweep worker (B1 + B3)
6. Add `RequireAuthenticated` and `PlugAttack` tests (B4 + B5)
7. Add missing `Accounts` function tests (B6)
8. Unify Meta.Client dispatch in `Accounts` (B8)

### Before Week 2 features
9. Split `Meta.Client` into `Meta.Auth` + `Meta.Graph` (S1)
10. Add dedicated `token_refresh` Oban queue (S4)
11. Tighten dep version constraints (S8, S9)
12. Add `mix sobelow --exit medium` to CI

---

## What's Working Well

- OAuth security baseline is solid (CSRF state, secure_compare, TTL, session renewal)
- Cloak AES-256-GCM + `redact: true` on access_token
- Oban workers are idempotent with correct string-keyed args
- `ClientBehaviour` + `ClientMock` pattern is clean
- All FK indexes present; no N+1 patterns in current code
- CSP, CSRF, HSTS, SameSite all active
- 58 tests, 0 failures
