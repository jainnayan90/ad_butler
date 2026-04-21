---
module: "AdButler.Accounts, AdButlerWeb.AuthController"
date: "2026-04-21"
problem_type: test_failure
component: testing
symptoms:
  - "Mox.UnexpectedCallError when switching from Req.Test stubs to Mox"
  - "Tests fail non-deterministically with async: true and global Mox ownership"
  - "Happy-path tests pass even when the mock was never called (stub silently absorbs extra calls)"
root_cause: "Req.Test stubs bypass Mox ownership model; stub/3 does not assert call count so mock may never fire without test failure; async: true tests need set_mox_from_context to wire per-process ownership"
severity: medium
tags: [mox, testing, async, stub, expect, req-test, mock-strategy, meta-client]
---

# Mox: stub/3 vs expect/3 Strategy + async: true Setup

## Symptoms

Three distinct failures when migrating from `Req.Test` to `Mox`:

1. `Mox.UnexpectedCallError` — mock called from a process that doesn't own it
2. Happy-path tests pass silently even when the system under test never calls the mock
3. With `async: true`, tests interfere with each other's mock state

## Investigation

1. **`Req.Test` stubs stopped working** after `meta_client()` dispatch was unified — Req.Test intercepts HTTP at the adapter level; once the client is resolved via `Application.get_env`, Req.Test has nothing to intercept
2. **Switched to `Mox.stub/3` globally** — worked but stub silently absorbs any number of calls (0, 1, N) without failure
3. **Used `async: false` as workaround** — eliminated interference but killed test parallelism
4. **Root cause for async failures**: Mox assigns mock ownership to the test process; worker/context processes spawned by the code under test are in a different process

## Root Cause

### stub vs expect

`Mox.stub/3` allows 0-to-N calls — it will not fail even if the mock is never invoked. This means a happy-path test using `stub` could pass even if the code path that calls the mock is broken.

`Mox.expect/3` asserts the mock is called **exactly once** (or N times if you pass a count). `verify_on_exit!` then confirms all expectations were met.

### async: true + ownership

By default Mox uses global mode (ownership tied to the test process). For `async: true` tests, multiple test processes run concurrently and collide on the global mock. `set_mox_from_context` switches Mox to private mode per test process.

## Solution

```elixir
# In async test modules — BOTH setups required together
setup :set_mox_from_context   # per-process ownership for async safety
setup :verify_on_exit!         # assert all expects were satisfied

# Happy-path tests — use expect/3 (asserts mock is actually called)
test "successful token exchange" do
  expect(ClientMock, :exchange_code, fn _code ->
    {:ok, %{access_token: "token", expires_in: 86_400}}
  end)
  expect(ClientMock, :get_me, fn _token ->
    {:ok, %{meta_user_id: "123", name: "User", email: "u@example.com"}}
  end)
  # test body...
end

# Error-path tests — use stub/3 (not all mocks will fire)
test "exchange_code failure short-circuits get_me" do
  stub(ClientMock, :exchange_code, fn _code ->
    {:error, {:token_exchange_failed, "bad code"}}
  end)
  # get_me is never called; stub tolerates this, expect would fail
  # test body...
end
```

### Decision rule

| Scenario | Use |
|----------|-----|
| Happy path — all mocks expected to fire | `expect/3` |
| Error path — some mocks may not fire | `stub/3` |
| Setup shared across describe blocks | `stub/3` in `setup` |
| Asserting call count > 1 | `expect(Mock, :fn, N, fn)` |

### Files Changed

- `test/ad_butler/accounts_authenticate_via_meta_test.exs` — `async: true`, `set_mox_from_context`, `expect` on happy path
- `test/ad_butler_web/controllers/auth_controller_test.exs` — `expect` on happy-path callback tests

## Prevention

- [ ] Always pair `set_mox_from_context` with `verify_on_exit!` in async Mox test modules
- [ ] Code review rule: happy-path tests using `stub` instead of `expect` should be flagged
- [ ] When migrating from `Req.Test` to `Mox`: Req.Test intercepts HTTP; Mox intercepts module dispatch — they are not equivalent when `meta_client()` is resolved at runtime

## Related

- `.claude/solutions/testing-issues/stale-test-db-schema-citext-varchar-20260421.md` — Another async test infrastructure issue
