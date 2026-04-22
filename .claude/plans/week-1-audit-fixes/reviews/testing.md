# Testing Review: Week-1 Audit Fixes

⚠️ EXTRACTED FROM AGENT MESSAGE (Write permission denied in subagent context)

**Verdict**: PASS WITH WARNINGS — 0 blockers, 3 warnings, 3 suggestions

---

## Summary

Mox migration is structurally sound. `ClientBehaviour` defines `@callback` for every dispatched method, `ClientMock` registered via `Mox.defmock/2 for: ClientBehaviour`, and `verify_on_exit!` present in all Mox-using modules. Factory patterns clean. No Iron Law violations.

---

## Warnings

### W1: `accounts_authenticate_via_meta_test.exs` — `async: false` unjustified, missing `set_mox_from_context`
Uses `stub/3` in serialised `async: false` mode — correct as written, but upgrading to `async: true` without adding `setup :set_mox_from_context` would cause Mox ownership errors.
Fix: `async: true` + `setup :set_mox_from_context` (matching pattern in `token_refresh_worker_test.exs`).

### W2: `plug_attack_test.exs` — `unique_octet/0` collision domain is only 250 values
`rem(System.unique_integer([:positive]), 250) + 1` gives 1–250. Safe within a single run. But the ETS table persists across `mix test` invocations in the same process (e.g., `--repeat-until-failure`) — could hit a partially-filled bucket from a prior run.

### W3: `auth_controller_test.exs` — hardcoded UUID in PubSub broadcast test
Logout test subscribes to `"users_sessions:00000000-0000-0000-0000-000000000001"`. Safe with `async: false`. If ever made async, this UUID must be randomised per test to avoid cross-test broadcast pollution.

---

## Suggestions

### S1: Prefer `expect/3` over `stub/3` for happy path in authenticate test
The happy path calls `exchange_code` and `get_me` exactly once. `stub/3` allows zero or many calls. Using `expect(ClientMock, :exchange_code, 1, fn ... end)` would detect regressions where calls are accidentally skipped.

### S2: `accounts_test.exs` — missing case-sensitivity test for `get_user_by_email/1`
No test documents whether email lookup is case-sensitive. Add a test with a mixed-case email to establish the contract.

### S3: `require_authenticated_test.exs` — `init_test_session(%{})` for "no session" case is CORRECT
No change needed. An empty session map causes `get_session(conn, :user_id)` to return `nil` as expected.
