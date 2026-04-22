# Triage: week-1-post-review-fixes

**Source**: `week-1-post-review-fixes-review.md`  
**Triaged**: 2026-04-21  
**Decision**: Fix all findings using review's suggested approaches

---

## Fix Queue

### Deploy Blockers

- [ ] [B1] Enable DB SSL in `config/runtime.exs` prod block — `ssl: true, ssl_opts: [verify: :verify_peer, cacerts: :public_key.cacerts_get()]`
- [ ] [B2] Remove `force_ssl` from `config/prod.exs`; consolidate in `config/runtime.exs` with `exclude: ["localhost", "127.0.0.1"]`
- [ ] [B3] Document/enforce `MIX_ENV=prod` for all production builds; consider adding runtime warning if `Mix.env() != :prod` in prod config

### Critical Functional

- [ ] [C1] Return `{:error, :schedule_failed}` from `perform/1` when `schedule_next_refresh/2` fails — `token_refresh_worker.ex:43`
- [ ] [C2] Extract `require_authenticated_user` to `AdButlerWeb.Plugs.RequireAuthenticated` module plug: load `User` from DB by session `:user_id`, drop session + redirect on nil, assign `current_user` — `router.ex:45`
- [ ] [C3] Read `expires_in` from `Client.exchange_code/3` response and pass it to `create_meta_connection/2` instead of the hard-coded `@meta_long_lived_token_ttl_seconds` — `auth_controller.ex:10`
- [ ] [C4] Use `_ = case ...` for the inner `update_meta_connection` case in the revoke branch — `token_refresh_worker.ex:61`

### High Security

- [ ] [H1] Move `signing_salt`, `encryption_salt`, `live_view.signing_salt` to env vars in `runtime.exs`; generate new values with `mix phx.gen.secret 32`; note existing values in git history as compromised
- [ ] [H2] Treat callback as account-link (attach MetaConnection to existing user) if session already has `:user_id`; add `PlugAttack`/`Hammer` rate limit on `/auth/meta` and `/auth/meta/callback` — `auth_controller.ex:38`
- [ ] [H3] Replace `configure_session(renew: true) |> clear_session()` with `configure_session(renew: true) |> put_session(:user_id, user.id) |> put_session(:live_socket_id, ...)` — `auth_controller.ex:56`
- [ ] [H4] Change `meta_user_id` format to `~r/^[1-9]\d{0,19}$/` and add `validate_length(:meta_user_id, max: 20)` — `accounts/user.ex:24`

### Test Gaps

- [ ] [T1] Add `describe "DELETE /auth/logout"` to `auth_controller_test.exs` — cover authenticated branch (session cleared, broadcast sent) and unauthenticated branch (redirects to /)
- [ ] [T2] Add state TTL expiry test to `auth_controller_test.exs`: inject `{state, System.system_time(:second) - 700}` in session → assert redirects with "Invalid OAuth state"
- [ ] [T3] Add worker edge case tests to `token_refresh_worker_test.exs`:
  - 60-day clamp: `expires_in: 71 * 86_400` → scheduled_at within 60 days
  - `:token_revoked` cancel path
  - Generic `{:error, :meta_server_error}` → Oban retry
  - Scheduling failure path (mock `Oban.insert` to return error)
- [ ] [T4] Fix `meta_user_id: "999002"` hardcode in `accounts_test.exs:141` → use `sequence/2`; capture reference time before `schedule_refresh/2` call in worker test

### Warnings — Auth Controller Architecture

- [ ] [W1] Replace `if age <= 600 && secure_compare(...)` with `cond` with separate clauses for expired vs mismatched state — `auth_controller.ex:87`
- [ ] [W2] Extract OAuth token exchange + user info into `Accounts.authenticate_via_meta/2` (or similar context function) — keep controller thin
- [ ] [W3] Move `meta_app_id`/`meta_app_secret` loading inside `Client.exchange_code/3` to match `Client.refresh_token/1` pattern

### Warnings — Oban Config + Reliability

- [ ] [W4] Increase `timeout/1` from 30s to 60s in `token_refresh_worker.ex:28`
- [ ] [W5] Increase `max_attempts` from 3 to 5 in `token_refresh_worker.ex:3`
- [ ] [W6] Configure `Oban.Plugins.Cron` with a periodic sweep job to re-enqueue connections with no pending refresh job

### Warnings — Config/Env Hardening

- [ ] [W7] Change `PHX_HOST` fallback in `runtime.exs:77` to `|| raise "PHX_HOST environment variable is required"`
- [ ] [W8] Move Vault `config :ad_butler, AdButler.Vault` from `config_env() != :test` to `config_env() == :prod`; add a static dev key in `config/dev.exs`

---

## Skipped

None.

## Deferred

None.

---

## Fix counts

- Deploy Blockers: 3
- Critical Functional: 4
- High Security: 4
- Test Gaps: 4
- Warnings: 8

**Total: 23 items**
