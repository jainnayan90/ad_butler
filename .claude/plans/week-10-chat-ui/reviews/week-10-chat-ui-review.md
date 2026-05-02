# Review: Week 10 Chat UI

**Date**: 2026-05-02
**Branch**: `week-10-chat-ui`
**Plan**: [.claude/plans/week-10-chat-ui/plan.md](../plan.md)
**Agents**: elixir-reviewer, security-analyzer, testing-reviewer (3, parallel)

---

## Verdict: **PASS WITH WARNINGS**

No blockers. All five fixes from the prior review pass are confirmed
landed and clean. Remaining items are testing gaps on error branches
and minor stylistic suggestions — none gate merge.

| Severity | Count |
|---|---|
| BLOCKER | 0 |
| WARNING | 4 |
| SUGGESTION | 7 |

Verification (re-run): `mix compile --warnings-as-errors` ✓,
`mix format --check-formatted` ✓, `mix credo --strict` ✓,
`mix check.tools_no_repo` ✓, `mix test` 579 / 0 / 10 excluded.

---

## Prior Findings — All Resolved

Confirmed addressed by all three agents:

1. ~~`rescue Ecto.NoResultsError` rescuing own code~~ → `Chat.get_message/1` non-raising path used in [show.ex:111](../../../lib/ad_butler_web/live/chat_live/show.ex#L111).
2. ~~Missing `@impl true` on second `handle_info` group~~ → added at [show.ex:87](../../../lib/ad_butler_web/live/chat_live/show.ex#L87).
3. ~~`charts.ex fetch/2` `||` mishandling `value: 0`~~ → switched to `Map.fetch/2` case at [charts.ex:97-100](../../../lib/ad_butler_web/charts.ex#L97).
4. ~~`update_message_tool_results/2` unscoped~~ → renamed `unsafe_update_message_tool_results/2` with load-bearing `unsafe_` doc warning at [chat.ex:240-276](../../../lib/ad_butler/chat.ex#L240). Zero callers in `lib/`.
5. ~~Logger reasons leaking content via exit reason~~ → `redact_reason/1` flattens to atom/tag at every reason-bearing log site ([show.ex:138, 193, 206](../../../lib/ad_butler_web/live/chat_live/show.ex#L138)).

---

## Warnings — Test gaps on production error branches

These are real branches in shipping code with no test coverage. Not
blockers because the happy paths are covered, but each is a regression
trap.

### W1 — `handle_async(:send_turn, {:ok, {:error, _}})` "Send failed" flash untested
- **File**: [test/ad_butler_web/live/chat_live/show_test.exs](../../../test/ad_butler_web/live/chat_live/show_test.exs) (missing test) for [lib/ad_butler_web/live/chat_live/show.ex:189-200](../../../lib/ad_butler_web/live/chat_live/show.ex#L189)
- **Why**: When `Chat.send_message/3` returns `{:error, _}`, the LV flashes "Send failed — please retry." and resets `:sending`/`:streaming_chunk`. No test exercises this branch. A future change that drops the error reset would silently leave the UI stuck in "Sending…".

### W2 — `handle_async(:send_turn, {:exit, _})` "Agent crashed" flash untested
- **File**: same file, [show.ex:202-213](../../../lib/ad_butler_web/live/chat_live/show.ex#L202)
- **Why**: Distinct failure mode (start_async task crashed). Untested. The redact_reason path is only exercised here; if the redactor regressed, no test would catch it.

### W3 — `{:tool_result, _sid, name, _status}` PubSub handler untested
- **File**: production at [show.ex:93-103](../../../lib/ad_butler_web/live/chat_live/show.ex#L93)
- **Why**: Sets `@current_tool` and schedules `{:clear_tool_indicator, name}` via `Process.send_after/3`. The streaming_bubble component renders "Calling {tool}…" from this assign. No test verifies the indicator appears.

### W4 — `{:turn_complete, _sid, :error}` cap-hit no-op path untested
- **File**: production at [show.ex:106-108](../../../lib/ad_butler_web/live/chat_live/show.ex#L106)
- **Why**: Silently clears `streaming_chunk` on the `:error` atom variant (loop-cap exceeded). A future change adding a flash here would regress invisibly. The acceptance criterion at plan.md line 245 ("Loop-cap exceeded turn shows a `system_error` row 'loop_cap_exceeded' without leaving the LV in a stuck state") is partially asserted but the LV-side handler is not exercised.

**Recommended addition**: ~25-line block in `show_test.exs` covering all four. Direct PubSub broadcast drives W3/W4; for W1/W2, configure a stub LLM client that returns `{:error, :rate_limited}` or raises. The W10D5-T6 deferred Mox e2e test (handoff.md) would also unblock W1/W2 naturally.

---

## Suggestions — Lower-priority polish

### S1 — `get_message/1` is an enumeration oracle if the topic is ever leaked (defence-in-depth)
- **File**: [chat.ex:230-238](../../../lib/ad_butler/chat.ex#L230) consumed at [show.ex:111](../../../lib/ad_butler_web/live/chat_live/show.ex#L111)
- **Why**: Today `Chat.Server` is the only broadcaster on `chat:#{sid}`, so msg_ids on that topic are by-construction in-tenant. A future code path that broadcasts `{:turn_complete, sid, msg_id}` with a `msg_id` from another session would `stream_insert` cross-tenant content. Belt-and-braces fix: scope the read by joining `Session` and the LV's `current_user.id`. One extra join per `:turn_complete`. Not blocking — current threat model holds.

### S2 — `message_count` drift on tool turns
- **File**: [show.ex:118](../../../lib/ad_butler_web/live/chat_live/show.ex#L118)
- **Why**: Counter increments by 1 per `:turn_complete`, but `Chat.Server.persist_tool_turn/4` may persist tool rows without bumping the counter. Only consumer is the empty-state guard at [show.ex:257](../../../lib/ad_butler_web/live/chat_live/show.ex#L257) — worst case is a flickering banner.

### S3 — Legacy `<%= for %>`/`<%= case %>` in HEEx
- **File**: [components.ex:147-167](../../../lib/ad_butler_web/live/chat_live/components.ex#L147)
- **Why**: `tool_results_block/1` uses EEx-style `<%= for ... do %>`/`<%= case ... do %>` instead of HEEx `:for`/`:if` attribute syntax used elsewhere. Cleaner replacement: a `:for` div containing two `:if`-guarded components (chart_block + tool_call). No functional change.

### S4 — `unsafe_update_message_tool_results/2` bypasses `Message.changeset/2`
- **File**: [chat.ex:264-266](../../../lib/ad_butler/chat.ex#L264)
- **Why**: `Ecto.Changeset.cast/4` is called directly. If `Message` adds validations on `tool_results` later they will be silently skipped. Extract `Message.tool_results_changeset/2` to keep the schema authoritative. Low priority since the function has zero callers today.

### S5 — Redundant `@impl true` at `show.ex:87`
- **File**: [show.ex:87](../../../lib/ad_butler_web/live/chat_live/show.ex#L87)
- **Why**: Elixir only requires `@impl true` before the first clause of each callback name. The annotation at line 60 covers all subsequent `handle_info/2` clauses. The duplicate at line 87 is harmless but extra. Remove for consistency.

### S6 — `subscribe/1` cross-session isolation test missing
- **File**: [test/ad_butler/chat_test.exs](../../../test/ad_butler/chat_test.exs)
- **Why**: The current test verifies the happy-path receive but doesn't assert that broadcasts on `chat:other-id` don't leak to a process subscribed to `chat:this-id`. Topic naming makes this trivial in practice, but explicit coverage would document the invariant.

### S7 — No JS test framework for `chat_scroll.js`
- **File**: [assets/js/hooks/chat_scroll.js](../../../assets/js/hooks/chat_scroll.js)
- **Why**: The hook owns three concerns (scroll-to-bottom, atBottom tracking, history-prepend viewport preservation) with subtle state. No tests possible without adding vitest+jsdom. Defer until JS surface area grows.

---

## False Positives (Filtered)

- **elixir-reviewer**: claimed `test/ad_butler_web/live/chat_live/show_test.exs` and `index_test.exs` do not exist. Both files exist and contain 13 tests across them; all pass. Likely a stale tool snapshot in the agent. **Discounted.**

---

## Out of Scope (Pre-existing)

- `lib/ad_butler/chat/server.ex:230-233` — logs raw LLM `reason` term unredacted. Same `redact_reason/1` discipline now in `ChatLive.Show` should land here too. **File a separate task** — not in the W10 diff.
- `lib/ad_butler_web/components/layouts.ex:207` — `theme_toggle/1` uses DaisyUI `class="card"`. Pre-existing; chat surface does not touch the helper. Plan's D-W10-06 explicitly defers this.

---

## Notes

- Both LiveViews have a `Plug.Conn` disconnected-render test (Index at [index_test.exs:71](../../../test/ad_butler_web/live/chat_live/index_test.exs#L71), Show at [show_test.exs:23](../../../test/ad_butler_web/live/chat_live/show_test.exs#L23)) — CLAUDE.md mandate satisfied.
- Tenant isolation tests present on every scoped read (sessions list, session show, message access).
- `Chat.subscribe/1`, `Chat.get_message/1`, `Chat.unsafe_update_message_tool_results/2` all unit-tested.
- `mix check.tools_no_repo` extended to forbid `Repo.` calls in `lib/ad_butler_web/live/chat_live/` and passes.
- The `testing-reviewer` and `security-analyzer` agents could not write to their `output_file` (`Write` was blocked in their session). Findings extracted from agent messages and noted at [scratchpad.md:88](../scratchpad.md#L88).
