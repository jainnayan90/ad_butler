# Test Review: Week 1 Auth + Oban Review-Fixes

⚠️ EXTRACTED FROM AGENT MESSAGE (Write access unavailable)

## Iron Law Violations
None. `async: true`/`false` correct, `verify_on_exit!` present, `build(:user)` in factory, mock backed by `ClientBehaviour`.

## Critical

**C1. `get_meta_connection/1` (non-bang) has zero test coverage.**
New public function. Add test for the `nil` return on an unknown ID.

**C2. `exchange_code/3` and `get_me/1` are untested at unit level in `client_test.exs`.**
Controller integration test covers happy path only via `Req.Test.stub`. Error branches (`:token_exchange_failed`, `:user_info_failed`, timeout) completely uncovered.

## Warnings

**W1. ETS table race in `client_test.exs:44`.** `:ets.insert(@rate_limit_table, ...)` called directly without verifying table exists. If application is not started, this crashes. Seed via the stub path instead.

**W2. No test for duplicate `meta_connection` constraint in `auth_controller_test.exs`.** A second OAuth callback for the same Meta user hits the `(user_id, meta_user_id)` constraint inside the `with` chain and silently redirects with "Authentication failed" — real regression risk with no coverage.

**W3. `client_test.exs` `async: false` has no comment** explaining why, making it a future flip target.

**W4. Idempotency test (`token_refresh_worker_test.exs:90-102`) only asserts `:ok` twice** — should also assert final DB state after second call.

**W5. `update_meta_connection` test asserts returned struct AND re-fetches from DB** — double assertion; keep only the DB re-fetch to confirm persistence.

## Suggestions

- `schedule_refresh/2` test should assert the scheduled time delta, not just `!= nil`.
- `timeout/1` callback deserves trivial test (`assert TokenRefreshWorker.timeout(%Oban.Job{}) == 30_000`).
- `create_or_update_user` "creates a user" test uses inline `System.unique_integer` rather than factory — minor consistency issue.
