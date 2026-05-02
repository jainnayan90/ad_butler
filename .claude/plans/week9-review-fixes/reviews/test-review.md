# Test Review — Week 9 Review-Fix Changes

**Verdict**: APPROVED WITH SUGGESTIONS — No BLOCKERs. One WARNING, three SUGGESTIONs.

---

## BLOCKER

None.

---

## WARNING

### `insert_chat_message_at/4` — inserted_at offset precision vs. DB column
`test/support/factory.ex:127`, `lib/ad_butler/chat/message.ex:34`

The helper calls `DateTime.utc_now()` fresh on each invocation and adds `offset_ms` milliseconds. If the DB column were `utc_datetime` (second precision) rather than `utc_datetime_usec`, all sub-second offsets truncate to the same value and ordering is undefined. `message.ex:34` declares `utc_datetime_usec` which is correct — but confirm the migration column type matches. Also confirm `Message.changeset/2` actually `cast`s `:inserted_at`; if the field were only set via `autogenerate`, the caller-supplied timestamp is silently ignored and ordering collapses under load. Per `message.ex:50` it is in `@optional`, which looks correct — mark resolved once the migration column type is verified.

---

## SUGGESTIONS

### S1 — Hibernate test heap threshold is OTP-version sensitive
`test/ad_butler/chat/server_test.exs:157`

`heap_size < 1000` is an arbitrary threshold. OTP 27 changed GC heuristics; a more portable assertion is `Process.info(pid, :current_function) == {:erlang, :hibernate, 3}` checked immediately after the sleep. The CLAUDE.md exception comment is correctly placed.

### S2 — e2e stub fires `:telemetry.execute` in the mock body — implicit process-dict coupling
`test/ad_butler/chat/e2e_test.exs:115,119,128`

The `emit_token_usage_chunks/2` lambda fires `[:req_llm, :token_usage]` synchronously inside the `LLMClientMock.stream` stub, which runs inside the GenServer process. `Chat.Telemetry` reads correlation context from that same process's dictionary — so it works. But if the handler is ever moved to a spawned Task, context lookups return `nil` and all three `llm_usage` row assertions silently fail. Add a one-line comment: `# fires in the Server process — context dict must be set before this call`.

### S3 — `list_messages/2` undocumented-contract test lacks upstream cross-reference
`test/ad_butler/chat_test.exs:226`

The test correctly documents that `list_messages` is session-scoped, not tenant-scoped. The end-to-end guard that closes this gap lives in `server_test.exs:243` (`Chat.send_message/3` cross-tenant test). Add a comment in `chat_test.exs:226` pointing to that test so a future reader understands the isolation chain is covered.

---

## Specific questions answered

- **Mox / verify_on_exit**: `server_test.exs` and `e2e_test.exs` both call `setup :verify_on_exit!` and `setup :set_mox_global` with `async: false`. Correct.
- **async: false correctness**: Server, e2e, and telemetry tests all use `async: false` due to `Application.put_env`, `set_mox_global`, and the global telemetry handler respectively. Correct.
- **Telemetry handler leak**: `telemetry_test.exs` detaches in `on_exit`. `server_test.exs` loop-cap test uses a unique `cap_event_id` and detaches in `on_exit`. `e2e_test.exs` calls `Telemetry.detach()` in `on_exit`. No leaks found.
- **Hibernate sleep**: The CLAUDE.md exception comment is sufficient justification. The only improvement is the heap threshold portability noted above.
- **e2e synthetic telemetry events**: Covered in S2. Acceptable for a mock, but fragile if the execution model changes.
- **`DateTime.add(..., :millisecond)` clock skew**: DST does not affect `DateTime.utc_now()` (always UTC). NTP step-adjustments during a test run could theoretically affect wall-clock ordering, but since the offsets are added mathematically to a single captured `utc_now()` value rather than calling `utc_now()` twice, this is not a real risk. Safe.
- **Tenant isolation gaps**: `get_session!/2`, `get_session/2`, `list_sessions`, `ensure_server/2`, and `Chat.send_message/3` all have explicit cross-tenant tests. `list_messages/2` and `unsafe_flip_streaming_messages_to_error/1` are intentionally session-scoped with documented contracts. `unsafe_get_session_user_id/1` has no cross-tenant test (it's an internal helper taking a raw session_id with no user scoping by design). Coverage is complete for the public API surface.
