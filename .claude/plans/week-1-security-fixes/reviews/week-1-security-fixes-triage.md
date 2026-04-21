# Triage: week-1-security-fixes

**Date**: 2026-04-21
**Source**: `.claude/plans/week-1-security-fixes/reviews/week-1-security-fixes-review.md`
**Decision**: Fix all criticals and warnings

---

## Fix Queue

### Criticals

- [x] **C1** Fix XFF spoofing in PlugAttack
  File: `lib/ad_butler_web/plugs/plug_attack.ex`
  Approach: `fly-client-ip` header first (Fly strips client-supplied); fallback to `List.last()` of XFF;
  fallback to `conn.remote_ip`. Remove `List.first()`.

- [x] **C2** Remove same-user fast-exit in auth callback
  File: `lib/ad_butler_web/controllers/auth_controller.ex`
  Remove the `if get_session(conn, :user_id) == user.id` branch entirely.
  Always run `clear_session() |> configure_session(renew: true) |> put_session(...)`.

### Warnings

- [x] **W1** Add `unique:` constraint to sweep worker
  File: `lib/ad_butler/workers/token_refresh_sweep_worker.ex`
  Add `unique: [period: {6, :hours}, fields: [:worker]]` to `use Oban.Worker`.

- [x] **W2** Reduce jitter range to 1 hour
  File: `lib/ad_butler/workers/token_refresh_sweep_worker.ex`
  Change `:rand.uniform(86_400)` to `:rand.uniform(3_600)`.

- [x] **W3** Change sweep worker test to `async: true`
  File: `test/ad_butler/workers/token_refresh_sweep_worker_test.exs`
  No global state used; `async: false` is unjustified.

- [x] **W4** Extract `authenticate_via_meta` tests into separate module
  Create: `test/ad_butler/accounts_authenticate_via_meta_test.exs` (async: false)
  Restore `async: true` on `test/ad_butler/accounts_test.exs`.

- [x] **W5** Fix `on_exit` in `auth_controller_test.exs` to restore env
  File: `test/ad_butler_web/controllers/auth_controller_test.exs`
  Capture originals before overwriting; restore or delete per the `restore_or_delete` pattern.

- [x] **W6** Add already-expired connection test case to sweep worker test
  File: `test/ad_butler/workers/token_refresh_sweep_worker_test.exs`
  Add test: active connection with `token_expires_at` in the past should be enqueued.

---

## Skipped

None.

## Deferred

None.
