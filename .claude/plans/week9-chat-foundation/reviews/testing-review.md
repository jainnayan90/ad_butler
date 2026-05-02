⚠️ EXTRACTED FROM AGENT MESSAGE

# Test Review: Week 9 Chat Foundation

## Summary

60 tests across 8 files. Tenant isolation well-covered for all tools and the context layer — every tool test has a cross-tenant assertion with two distinct users. Primary issues: banned `:timer.sleep` calls (7 instances), telemetry handler that leaks globally without detach cleanup, `stop_supervised!` called with a module name instead of a pid/ref, and no test for the public `Chat.send_message/3` entry point that enforces authorization.

---

## Iron Law Violations

**T-IL1. NO PROCESS.SLEEP (7 violations)**

`:timer.sleep` appears in `chat_test.exs` (lines 89, 101, 132, 190, 209) and `server_test.exs` (lines 101, 142). CLAUDE.md is explicit.

Five of seven exist solely to force `inserted_at` ordering. Replaceable: pass an explicit `inserted_at` in attrs, or use a monotonic sequence column. The `server_test.exs:101` history-replay (25 messages) has the same fix.

`server_test.exs:142` (hibernation test) is different — waits for OTP to hibernate. The one case where no `assert_receive` alternative exists. Document as deliberate exception with comment explaining why.

---

## Critical

**T-C1. TelemetryTest: telemetry handler not detached on_exit** (`telemetry_test.exs:11`)

`ChatTelemetry.attach()` installs a process-global `:telemetry` handler. Setup calls `attach()` but no `on_exit(fn -> :telemetry.detach(handler_id) end)`. Handler persists across test modules, can fire against unrelated sandbox connections in subsequent runs, will emit `{:error, :already_attached}` warnings on next caller. The `e2e_test.exs` `on_exit` only calls `clear_context()` — same gap.

Fix: add `on_exit(fn -> :telemetry.detach(@handler_id) end)` to both setup blocks, or expose `handler_id/0` as a public function.

**T-C2. No test for `Chat.send_message/3`** (the public authorized entry point)

`server_test.exs` calls `Server.send_user_message/2` directly, bypassing the `get_session` authorization guard in `Chat.send_message/3`. A regression removing that guard would not be caught.

**T-C3. `list_messages/2` missing tenant-isolation test** (`chat_test.exs`)

`list_messages/2` is called with a bare `session_id` — no `user_id` parameter. No test asserts that calling with another user's session_id is safe. Intent may be that callers pre-validate via `get_session!/2`, but the contract is untested.

---

## Warnings

**T-W1. `stop_supervised!(Server)` uses module name, not pid/ref** (`server_test.exs:249`)

`start_supervised!({Server, session_id})` is called, but `stop_supervised!(Server)` passes the module atom. If the child id assigned by the supervisor differs from the module name, or if multiple Server children exist, this stops the wrong child. Use the pid returned from `start_supervised!`.

**T-W2. `Application.put_env` restore in hibernate_after describe-block** (`server_test.exs:126-133`)

When `previous` is `nil`, the inner `on_exit` calls `Application.put_env(:ad_butler, :chat_server_hibernate_after_ms, nil)`, setting the key to nil instead of removing it. Use `Application.delete_env` when previous is nil.

**T-W3. `telemetry_test.exs`: `async: false` likely too conservative**

`set_context/1` uses `Process.put/2` — process-local, safe for concurrency. Only global side effect is `:telemetry.attach_many/4`. If `attach()` were moved to `test_helper.exs` once, these tests could run `async: true`.

**T-W4. `paginate_messages/2` test does not verify page-2 boundary** (`chat_test.exs:204-221`)

5 messages, `per_page: 3` — page 2 never fetched. Off-by-one would not be caught.

**T-W5. `pubsub_subscribe` called after `start_supervised_server!`** (`server_test.exs:169-170`)

The subscribe happens after the server starts. If the stub resolves the stream synchronously, the server could broadcast `:chat_chunk` before the test process subscribes, causing flaky `assert_receive` timeouts. Move subscribe before `send_user_message`.

**T-W6. `insert_finding_for_user/2` creates a full entity chain per call** (`get_findings_test.exs:8-26`)

Limit-clamping test inserts 30 findings × 5 entities = 150 DB rows. Share a single ad account in setup.

**T-W7. `compare_creatives_test.exs` double meta_connection for user_b** (`compare_creatives_test.exs:31, 41`)

`user_b` gets a `meta_connection` from inline `insert` at line 31 and another inside `insert_ad_for_user(user_b)`. Two connections for the same user can mask scoping bugs.

---

## Suggestions

- **T-S1.** `e2e_test.exs` synthesizes a `:telemetry` event after the fact rather than verifying it fires naturally during the turn. Test comment acknowledges this — acceptable for an integration smoke test, but worth noting that the telemetry wiring itself is not exercised end-to-end. (Tied to security S-W2 — Server doesn't call set_context.)
- **T-S2.** All four tool test files define near-identical `insert_ad_for_user/1` private functions. Extract to `test/support/chat_helpers.ex`.
- **T-S3.** `server_test.exs` history-replay: with 25 `:timer.sleep(1)` calls, on a slow CI box multiple messages can share the same `inserted_at`, making the `hd(state.history).content == "msg 6"` assertion flaky. Fixing the sleep issue (explicit `inserted_at`) also fixes this.
