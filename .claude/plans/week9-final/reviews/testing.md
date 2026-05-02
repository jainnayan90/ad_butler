# Test Review: W9 Final Triage Fixes (testing-reviewer, post-fix pass)

> **⚠️ EXTRACTED FROM AGENT MESSAGE** — Write denied to agent; orchestrator captured chat output verbatim.

**Files reviewed:** `simulate_budget_change_test.exs` (NEW), `get_ad_health_test.exs` (B2 addition), `server_test.exs` (B1 addition), `analytics_test.exs` (W2 addition), `e2e_test.exs` (W4+S3), `telemetry_test.exs` (S4).

## Iron Law Violations: None

All `async: false` instances are justified (`set_mox_global` in server/e2e, global telemetry handler in telemetry_test with a comment). `verify_on_exit!` present in all Mox-using modules. No `Process.sleep` except the OTP-hibernate test at `server_test.exs:151` which carries an explicit CLAUDE.md exception comment. All factory definitions use `build/2`. `LLMClientMock` wraps a `@callback` behaviour.

## Warnings

**W1 — Confidence band exact boundaries never tested** (`simulate_budget_change_test.exs:91-137`)

Production guards use `>= 21` for `:high` and `>= 7` for `:medium`. Tests seed 3 days (`:low`), 10 days (`:medium`), 25 days (`:high`). The boundary values 7 and 21 are never exercised — an off-by-one flip from `>=` to `>` would pass all three existing tests undetected. Add tests seeding exactly 7 days (assert `:medium`) and exactly 21 days (assert `:high`).

**W2 — Query-count drain has no isolation between the two measurement runs** (`analytics_test.exs:426-472`)

The telemetry handler sends `{:query, ref}` to `self()`. The mailbox drain uses `after 0` polling — zero latency budget. If any sandbox infrastructure query event arrives between the first detach and the second `try` block, it is counted under `ref2`, making the invariance assertion `one_ad_count == query_count` unreliable. Either assert `one_ad_count <= 4` independently or flush stale messages between the two runs.

## Suggestions

**S1 — B1 system prompt test: content verified, role position enforced by pattern match** (`server_test.exs:335-363`). Pattern `[%{role: "system", content: ...} | _]` correctly enforces first position. No change needed.

**S2 — W4 PubSub subscription placed before cast (race-free)** (`e2e_test.exs:107`). Subscribe at line 107, `send_user_message` at line 157. Correct ordering; no issue.

**S3 — S3 tool-message threading assertions are on the 2nd and 3rd `expect` callbacks** (`e2e_test.exs:123-139`). Assertions correctly placed on calls 2 and 3. First call has no prior tool turn — nothing to assert. Correct.

**S4 — `telemetry_test.exs` `async: false` has a justification comment** (line 2). Comment present and accurate. No issue.
