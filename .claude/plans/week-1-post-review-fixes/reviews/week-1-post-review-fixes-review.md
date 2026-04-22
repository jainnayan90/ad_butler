# Review: week-1-post-review-fixes

**Verdict**: REQUIRES CHANGES  
**Agents**: elixir-reviewer, security-analyzer, testing-reviewer, oban-specialist, deployment-validator  
**Findings**: 3 deploy blockers · 4 critical · 4 high security · 7 warnings · 4 critical test gaps

---

## Deploy Blockers (must fix before ship)

**B1 (PRE-EXISTING) — DB SSL disabled** `config/runtime.exs:57`
`ssl: true` was already commented out. Not introduced by this PR but exposed by the deploy review.

**B2 (NEW — introduced by P3-T8) — Conflicting `force_ssl` configs**
`config/prod.exs:14` has `force_ssl: [rewrite_on: [:x_forwarded_proto]]` (pre-existing).
`config/runtime.exs:45-46` now also has `force_ssl: [hsts: true, rewrite_on: ...]` (added this session).
`runtime.exs` overwrites `prod.exs` at boot, silently dropping `prod.exs`'s localhost exclude list. Health-check traffic from localhost gets HTTPS-redirected.
Fix: Remove `force_ssl` from `prod.exs` and keep the full config in `runtime.exs`, adding `exclude: ["localhost", "127.0.0.1"]`.

**B3 (PRE-EXISTING design) — `secure: Mix.env() == :prod` evaluated at compile time**
`endpoint.ex:14`. Safe only if all prod builds guarantee `MIX_ENV=prod`. Document or enforce.

---

## Critical Functional Issues

**C1 (confirmed by 2 agents) — `schedule_next_refresh/2` failure silently returns `:ok`**
`token_refresh_worker.ex:43` — `perform/1` discards the return of `schedule_next_refresh/2`. When `Oban.insert/1` fails, the token is refreshed but never re-scheduled, and the 23-hour uniqueness window blocks manual recovery.
Fix: Return `{:error, :schedule_failed}` from `perform/1` so Oban retries the job.

**C2 (confirmed by 2 agents) — `require_authenticated_user` doesn't verify user exists in DB**
`router.ex:45-53` — trusts the session `:user_id` without loading the `User` row. Deleted/banned users reach `/dashboard` until cookie expiry. Also missing `assign(:current_user, ...)` — every authenticated LiveView will need to re-query.
Fix: Extract to a module plug (`AdButlerWeb.Plugs.RequireAuthenticated`) that loads the user, drops session on failure, and assigns `current_user`.

**C3 (confirmed by 2 agents) — Hard-coded 60-day token TTL ignores Meta's `expires_in`**
`auth_controller.ex:10` — `@meta_long_lived_token_ttl_seconds` is ignored by the exchange response. The stored `token_expires_at` is wrong for initial connections, causing `schedule_next_refresh` to miscalculate on the first job run.
Fix: Read `expires_in` from the `exchange_code` response (same as `refresh_token` already does).

**C4 — Inner `case` result silently discarded in revoke branch**
`token_refresh_worker.ex:61-78` — `Logger.warning/2` return (`:ok`) falls through unconditionally. Credo will flag unused return.
Fix: `_ = case ...` or extract to helper.

---

## High Security Issues

**H1 — Session salts committed to git history**
`endpoint.ex:10-11`, `config.exs:23` — `signing_salt`, `encryption_salt`, `live_view.signing_salt` are all in the repo. With a leaked `SECRET_KEY_BASE`, sessions can be forged. Rotation requires a code change.
Fix: Load from env in `runtime.exs`; rotate current values.

**H2 — OAuth callback allows login-CSRF**
`auth_controller.ex:38-61` — `state` only proves same browser started the flow; doesn't prevent an attacker initiating the flow on a victim's browser. Callback also silently overwrites existing `:user_id`.
Fix: Treat callback as account-link if session already has `:user_id`; add rate limiting.

**H3 — Hard-coded `configure_session(renew: true) |> clear_session()` on login is ambiguous**
`auth_controller.ex:56-61` — both calls mutate session; flash/CSRF lifecycle ambiguous.
Fix: Use `configure_session(renew: true)` alone, then `put_session` calls.

**H4 (PRE-EXISTING) — `signing_salt` / `encryption_salt` hardcoded**
Already in `endpoint.ex` before this PR. See H1 — same fix.

---

## Warnings

- **W1** `auth_controller.ex:87` — `if age <= 600 && secure_compare(...)` conflates expiry vs mismatch; use `cond`
- **W2** `auth_controller.ex:43-44` — OAuth flow logic in controller; belongs in `Accounts.authenticate_via_meta/2`
- **W3** `auth_controller.ex:39-40` — `exchange_code/3` takes credentials as params; `refresh_token/1` reads them internally — inconsistent
- **W4** Worker `timeout/1` = 30s — marginal for cold Meta API (10-20s common); recommend 60s
- **W5** `max_attempts: 3` too low for Meta outages; consider 5 or dedicated queue
- **W6** No `Oban.Plugins.Cron` — no sweep to recover orphaned connections
- **W7** `PHX_HOST` silently defaults to `"example.com"` — should raise
- **W8** `CLOAK_KEY` guard crashes dev (guard is `!= :test`); move Vault config to prod-only

---

## Test Coverage Gaps

1. **`AuthController.logout/2`** — zero tests; both authenticated and unauthenticated paths untested
2. **State TTL expiry** — only mismatch tested, not `issued_at = System.system_time(:second) - 700`
3. **Worker edge cases** — `@max_refresh_days` 60-day clamp, `:token_revoked` branch, generic `{:error, reason}` path, scheduling failure path
4. **Minor hygiene** — hardcoded `"999002"` meta_user_id in accounts_test (use `sequence/2`); reference time race in schedule_refresh test; no found-case for `get_meta_connection/1`

---

## Acceptable / No Action Needed

- `encryption_salt` hardcoded in endpoint.ex: standard Phoenix pattern for salts; no secret
- Test Cloak key change to 32-byte ASCII: good hygiene improvement ✓
- `SameSite=Lax`: correct for OAuth redirects ✓
- State TTL ordering (`age <= 600 && secure_compare`): no timing-oracle concern ✓
- `http_only: true`: correct ✓
