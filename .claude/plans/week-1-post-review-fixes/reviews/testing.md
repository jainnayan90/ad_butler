# Test Review: Week 1 Auth + Oban Token Refresh

## Summary

The suite covers the happy path well and respects most iron laws. `async: true` is used correctly in DataCase tests. Mox is set up with `verify_on_exit!` and `set_mox_from_context`. Factories use `build/2` for associations. However, several critical paths are entirely untested.

---

## Critical

**1. `AuthController.logout/2` has zero test coverage.**
No `describe "DELETE /auth/logout"` block exists in `auth_controller_test.exs`. The function drops the session and broadcasts `"disconnect"` to `users_sessions:#{user_id}` — both the authenticated and unauthenticated branches are untested.

**2. State TTL expiry path is not tested** (`auth_controller_test.exs`).
`verify_state/2` rejects states older than 600 seconds. No test exercises this: the only state-invalid test uses a mismatched string, not an expired `issued_at`. Inject `issued_at = System.system_time(:second) - 700` to cover this branch.

**3. `TokenRefreshWorker` 60-day upper-bound clamp is untested.**
`schedule_next_refresh/2` clamps via `min(@max_refresh_days)`. No test passes `expires_in >= 70 * 86_400` and verifies the scheduled job sits at exactly 60 days. The `@max_refresh_days` constant is dead code from the test perspective.

**4. `TokenRefreshWorker` revoked-status DB-update failure path is untested.**
When `update_meta_connection` errors after an `:unauthorized` refresh response, the worker logs a warning and still returns `{:cancel, "unauthorized"}`. No test covers this sub-branch.

**5. `TokenRefreshWorker` generic `{:error, reason}` path is untested** (non-rate-limit, non-unauthorized).
A `:meta_server_error` returns `{:error, reason}` and triggers Oban retry. No test covers the most common transient-failure path.

---

## Warnings

**6. `Application.put_env` in `auth_controller_test.exs` has no crash-safety guarantee.**
`async: false` is correct, but if a test crashes before `on_exit` fires, env keys leak. Using `Req.Test` stubs exclusively plus Mox would eliminate the need for `Application.put_env`.

**7. Hardcoded `meta_user_id: "999002"` in `accounts_test.exs:141`.**
If the sequence ever reaches that value in the same sandbox transaction, the unique constraint on `(user_id, meta_user_id)` would fail. Use `sequence/2` instead.

**8. `schedule_refresh/2` test captures `DateTime.utc_now()` after the insert call.**
This introduces a race on slow CI. Capture the reference time *before* calling `schedule_refresh/2`.

---

## Suggestions

- Add `create_or_update_user/1` test with `email: nil` — `Meta.Client.get_me/1` returns `nil` for missing email, but no context test verifies the changeset rejects it.
- `get_meta_connection/1` describe only tests not-found. Add a found-case test.
- `mocks.ex`: wrap in a `defmodule AdButler.Mocks` for dialyzer hygiene.
