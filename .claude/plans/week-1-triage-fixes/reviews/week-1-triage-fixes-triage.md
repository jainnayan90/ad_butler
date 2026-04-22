# Triage: week-1-triage-fixes
Date: 2026-04-21

## Fix Queue

### Criticals
- [ ] C1: Restore `clear_session()` before `put_session` in login flow — `auth_controller.ex` callback/2
- [ ] C2: Cast JSONB fragment to `::uuid` in sweep worker — `token_refresh_sweep_worker.ex:19-25`
- [ ] C3: Rotate all three session salts; move prod values to env vars (out of git) — `config/config.exs`, `config/prod.exs`, `config/runtime.exs`
- [ ] C4: Replace `conn.remote_ip` with real client IP — add `RemoteIp` plug or read `X-Forwarded-For` in `plug_attack.ex`
- [ ] C5: Add test file for `TokenRefreshSweepWorker` — `test/ad_butler/workers/token_refresh_sweep_worker_test.exs`

### Warnings
- [ ] W1: `assert_receive` explicit 1000ms timeout — `test/ad_butler_web/controllers/auth_controller_test.exs:180`
- [ ] W2: `on_exit` restore env with `put_env` instead of `delete_env` — `test/ad_butler/meta/client_test.exs`
- [ ] W3: Scope `Repo.aggregate` count to user — `test/ad_butler/accounts_test.exs:99`
- [ ] W4: Add happy-path test for `Accounts.authenticate_via_meta/1`
- [ ] W5: Change meta credentials guard from `!= :test` to `== :prod` — `config/runtime.exs`

### Suggestions
- [ ] S1: Remove redundant `pending_ids` pre-query in sweep worker; let Oban uniqueness deduplicate
- [ ] S2: Add jitter to orphan enqueue delay in sweep worker
- [ ] S3: Remove redundant `validate_length(:meta_user_id, max: 20)` — regex already enforces it

## Skipped
_None_

## Deferred
_None_
