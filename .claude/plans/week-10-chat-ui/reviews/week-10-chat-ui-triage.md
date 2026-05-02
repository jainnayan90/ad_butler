# Triage: Week 10 Chat UI Review

**Source review**: [.claude/plans/week-10-chat-ui/reviews/week-10-chat-ui-review.md](week-10-chat-ui-review.md)
**Date**: 2026-05-02

## Outcome

- **Fix queue**: 10 items
- **Deferred**: 1 item
- **Skipped**: 0 items

---

## Fix Queue

### Test gaps (all 4 WARNINGs)

- [ ] **W1 — `handle_async(:send_turn, {:ok, {:error, _}})` "Send failed" flash test**
  - File: [test/ad_butler_web/live/chat_live/show_test.exs](../../../test/ad_butler_web/live/chat_live/show_test.exs)
  - Production path: [lib/ad_butler_web/live/chat_live/show.ex:189-200](../../../lib/ad_butler_web/live/chat_live/show.ex#L189)
  - Approach: configure a stub LLM client returning `{:error, :rate_limited}` (or similar) and assert the flash + `:sending` reset.

- [ ] **W2 — `handle_async(:send_turn, {:exit, _})` "Agent crashed" flash test**
  - Production path: [show.ex:202-213](../../../lib/ad_butler_web/live/chat_live/show.ex#L202)
  - Approach: same stub client raising mid-turn; assert flash + `:streaming_chunk = nil`. Also indirectly exercises `redact_reason/1`.

- [ ] **W3 — `{:tool_result, _, name, _}` PubSub handler / `current_tool` indicator test**
  - Production path: [show.ex:93-103](../../../lib/ad_butler_web/live/chat_live/show.ex#L93)
  - Approach: direct PubSub broadcast of `{:tool_result, sid, "get_findings", :ok}`; assert `Calling get_findings…` appears in render.

- [ ] **W4 — `{:turn_complete, _, :error}` cap-hit no-op test**
  - Production path: [show.ex:106-108](../../../lib/ad_butler_web/live/chat_live/show.ex#L106)
  - Approach: prime `:streaming_chunk` via a `:chat_chunk` broadcast, then broadcast `{:turn_complete, sid, :error}`; assert chunk cleared and no flash, no crash.

### Security & correctness (substantive suggestions)

- [ ] **S1 — `Chat.get_message/1` defence-in-depth tenant scoping**
  - File: [lib/ad_butler/chat.ex:230-238](../../../lib/ad_butler/chat.ex#L230)
  - Approach: change signature to `get_message(user_id, id)`; join `Session` and filter by `user_id`. Update sole caller at [show.ex:111](../../../lib/ad_butler_web/live/chat_live/show.ex#L111). Adds one join per `:turn_complete` — negligible. Removes the trust-the-topic proof obligation. Update test in [chat_test.exs](../../../test/ad_butler/chat_test.exs) to cover cross-tenant returning `:not_found`.

- [ ] **S2 — `message_count` drift on tool turns**
  - File: [lib/ad_butler_web/live/chat_live/show.ex:118](../../../lib/ad_butler_web/live/chat_live/show.ex#L118)
  - Approach: derive `:message_count` from `length(@streams.messages)` is not viable (streams are LV-side, not enumerable). Simplest fix: the empty-state guard at [show.ex:257](../../../lib/ad_butler_web/live/chat_live/show.ex#L257) is the only consumer — change the guard to test `@streams.messages.inserts == [] and is_nil(@streaming_chunk)` or introduce a separate `:any_messages?` boolean assign that flips true on first insert. Drop `:message_count` entirely.

### Code quality

- [ ] **S3 — Modernize HEEx in `tool_results_block/1`**
  - File: [lib/ad_butler_web/live/chat_live/components.ex:147-167](../../../lib/ad_butler_web/live/chat_live/components.ex#L147)
  - Approach: replace `<%= for ... do %>`/`<%= case ... do %>` with a `:for` div containing two `:if`-guarded components (`<.chart_block :if={chart_points(entry)} ...>` and `<.tool_call :if={is_nil(chart_points(entry))} ...>`). No functional change.

- [ ] **S4 — Extract `Message.tool_results_changeset/2`**
  - File: [lib/ad_butler/chat/message.ex](../../../lib/ad_butler/chat/message.ex) + [lib/ad_butler/chat.ex:264-266](../../../lib/ad_butler/chat.ex#L264)
  - Approach: add `def tool_results_changeset(message, tool_results)` to `Message` that casts and validates the list. Have `Chat.unsafe_update_message_tool_results/2` call it. Future validations on `tool_results` then apply automatically.

- [ ] **S5 — Remove redundant `@impl true` at show.ex:87**
  - File: [lib/ad_butler_web/live/chat_live/show.ex:87](../../../lib/ad_butler_web/live/chat_live/show.ex#L87)
  - Approach: one-line delete. The `@impl true` at line 60 covers all `handle_info/2` clauses.

### Coverage

- [ ] **S6 — `subscribe/1` cross-session isolation test**
  - File: [test/ad_butler/chat_test.exs](../../../test/ad_butler/chat_test.exs)
  - Approach: add a test that subscribes to `chat:#{session_a.id}`, broadcasts on `chat:#{session_b.id}`, asserts `refute_receive` on the broadcast. Documents the topic-isolation invariant.

### Pre-existing — bundled into this pass per user request

- [ ] **PE1 — Apply `redact_reason/1` discipline to `Chat.Server` log of LLM error reason**
  - File: [lib/ad_butler/chat/server.ex:230-233](../../../lib/ad_butler/chat/server.ex#L230)
  - Approach: introduce `redact_reason/1` (or import from a shared module) and apply at the `LLM stream failed` log site. Removes the last known path where a provider error body could echo into structured logs. Add a small unit test with a synthetic `{:error, %{body: "user-content"}}` reason.

---

## Deferred

- [ ] **S7 — JS test framework for `chat_scroll.js`**
  - Reason: requires adding vitest + jsdom + npm script + hook test scaffolding (~30 min). The hook is small (50 lines), stable, and has no other JS code to share the framework cost. Revisit when JS surface grows. Noted in [scratchpad.md handoff](../scratchpad.md#L88).

---

## Skipped

None.

---

## Notes from triage

- The Iron Law #12 lesson (no `raw/1` with variable, captured in [.claude/solutions/liveview-issues/contex-svg-iron-law-12-no-jsonb-persistence-20260502.md](../../../.claude/solutions/liveview-issues/contex-svg-iron-law-12-no-jsonb-persistence-20260502.md)) is a candidate for `/phx:compound` — it documents a generalisable pattern that future chart/SVG implementers should know.
- The pre-existing `theme_toggle` DaisyUI `card` leak ([layouts.ex:207](../../../lib/ad_butler_web/components/layouts.ex#L207)) was explicitly excluded — plan's D-W10-06 defers it.
