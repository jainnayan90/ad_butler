# Test Review: week-01-Day-01-05-Authentication

⚠️ EXTRACTED FROM AGENT MESSAGE (write permission denied)

49 tests pass. Async safety correct — `async: false` justified on ClientTest and AuthControllerTest (both call `Application.put_env`). Mox setup correct: `verify_on_exit!` present, `set_mox_from_context` used.

---

## CRITICAL

### C1. TokenRefreshSweepWorker has zero test coverage

`lib/ad_butler/workers/token_refresh_sweep_worker.ex` is a new Oban worker with a `perform/1` implementation and no test file at all.

---

## WARNINGS

### W1. `Repo.aggregate` count not scoped to user

**File**: `test/ad_butler/accounts_test.exs:99`

`Repo.aggregate(AdButler.Accounts.MetaConnection, :count) == 1` counts ALL meta_connections in the sandbox. Scope with `from(mc in MetaConnection, where: mc.user_id == ^user.id)`.

### W2. `assert_receive` timeout too short

**File**: `test/ad_butler_web/controllers/auth_controller_test.exs:180`

`assert_receive %Phoenix.Socket.Broadcast{...}` uses default 100ms timeout — flaky under CI load. Use explicit: `assert_receive %Phoenix.Socket.Broadcast{...}, 1000`.

### W3. `on_exit` deletes env instead of restoring

**File**: `test/ad_butler/meta/client_test.exs` setup

`Application.delete_env/2` removes keys rather than restoring originals. If `config/test.exs` sets these globally, deletion removes them for subsequent tests. Use `Application.put_env` in `on_exit` to restore.

### W4. Invalid-email test omits `meta_user_id`

**File**: `test/ad_butler/accounts_test.exs:51`

The changeset may have multiple errors (`:meta_user_id` required + `:email` invalid) but only `:email` is asserted — false confidence.

---

## SUGGESTIONS

### S1. Duplicate `schedule_refresh/2` test

Tested at line 88 and again at line 136 inside `"perform/1 edge cases"`. Remove the duplicate.

### S2. No test for `Accounts.authenticate_via_meta/1`

New public context function has no happy-path test. A test using `ClientMock` would catch pipeline composition regressions.

### S3. `%{}` pattern in test signatures

`test "...", %{} do` pattern in `token_refresh_worker_test.exs` — `%{}` is redundant. Prefer omitting or using `_context`.
