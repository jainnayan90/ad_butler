# Plan: Week 10 Review Fixes

**Window**: 1 day (~3-4 hours)
**Branch**: `week-10-chat-ui` (continue, no new branch)
**Source**: [.claude/plans/week-10-chat-ui/reviews/week-10-chat-ui-triage.md](../week-10-chat-ui/reviews/week-10-chat-ui-triage.md)
**Decisions log**: [scratchpad.md](scratchpad.md)

---

## Goal

Close the 10 fix items from the W10 review triage:

- 4 test gaps for production error branches in `ChatLive.Show`
- 1 defence-in-depth tenant scoping change (`Chat.get_message/1`)
- 1 correctness fix (`message_count` drift)
- 3 code-quality polish items
- 1 isolation test
- 1 pre-existing log-redaction fix in `Chat.Server`

S7 (JS test framework) is **deferred** — handed off to a future pass.

---

## What Already Exists (no redesign)

| Asset | File | Notes |
|---|---|---|
| Mox mock for chat LLM | [test/support/mocks.ex:5](../../../test/support/mocks.ex#L5) | `AdButler.Chat.LLMClientMock` defined |
| Mock wired in test env | [config/test.exs:59](../../../config/test.exs#L59) | `config :ad_butler, :chat_llm_client, AdButler.Chat.LLMClientMock` |
| `LLMClientBehaviour` | [lib/ad_butler/chat/llm_client_behaviour.ex](../../../lib/ad_butler/chat/llm_client_behaviour.ex) | `stream/2` returns `{:ok, handle} \| {:error, reason}` |
| `redact_reason/1` pattern | [lib/ad_butler_web/live/chat_live/show.ex:262-266](../../../lib/ad_butler_web/live/chat_live/show.ex#L262) | atom/tag flatten — to be lifted to a shared module |
| `Chat.get_message/1` (non-raising) | [lib/ad_butler/chat.ex:230-238](../../../lib/ad_butler/chat.ex#L230) | Will be retro-scoped to `(user_id, id)` |
| Existing tenant-isolation test pattern | [test/ad_butler/chat_test.exs:39-69](../../../test/ad_butler/chat_test.exs#L39) | Mirror for `get_message/2` |

---

## Tasks

### Phase 1 — Code quality fixes (zero-risk, fast)

- [ ] [W10R-T1] Delete redundant `@impl true` at [lib/ad_butler_web/live/chat_live/show.ex:87](../../../lib/ad_butler_web/live/chat_live/show.ex#L87). Keep only the one at line 60. (S5)
- [ ] [W10R-T2][liveview] Modernize HEEx in `tool_results_block/1` at [lib/ad_butler_web/live/chat_live/components.ex:147-167](../../../lib/ad_butler_web/live/chat_live/components.ex#L147). Replace `<%= for ... do %>` / `<%= case ... do %>` with a `:for` div containing two `:if`-guarded components: `<.chart_block :if={chart_points(entry)} ... />` and `<.tool_call :if={is_nil(chart_points(entry))} ... />`. No functional change. (S3)
- [ ] [W10R-T3][ecto] Extract `Message.tool_results_changeset/2` in [lib/ad_butler/chat/message.ex](../../../lib/ad_butler/chat/message.ex). Pure-function changeset that casts `tool_results` and validates it is a list. Update `Chat.unsafe_update_message_tool_results/2` at [lib/ad_butler/chat.ex:264-266](../../../lib/ad_butler/chat.ex#L264) to delegate. (S4)

### Phase 2 — `redact_reason` shared helper + Chat.Server fix (PE1)

- [ ] [W10R-T4] Create `AdButler.Chat.LogRedactor` module at `lib/ad_butler/chat/log_redactor.ex`. Lift `redact_reason/1` from [show.ex:262-266](../../../lib/ad_butler_web/live/chat_live/show.ex#L262) into the new module as `redact/1`. Public function with `@moduledoc` + `@doc` per CLAUDE.md. Behaviour: atoms pass through; `{tag, _}` and `{tag, _, _}` reduce to `tag`; everything else returns `:unknown`.
- [ ] [W10R-T5] Update `ChatLive.Show` to call `AdButler.Chat.LogRedactor.redact/1` instead of the local `redact_reason/1`. Remove the local fn. Three call sites: handle_info turn_error, handle_async {:ok, {:error, _}}, handle_async {:exit, _}. (S5 cleanup)
- [ ] [W10R-T6] Apply the same redaction to `Chat.Server` LLM-error log at [lib/ad_butler/chat/server.ex:230-233](../../../lib/ad_butler/chat/server.ex#L230). Change `reason: reason` to `reason: AdButler.Chat.LogRedactor.redact(reason)`. (PE1)
- [ ] [W10R-T7] Tests for `LogRedactor.redact/1` in `test/ad_butler/chat/log_redactor_test.exs` (NEW). Cover: atom passthrough, 2-tuple flatten, 3-tuple flatten, map fallthrough to `:unknown`, content-bearing string fallthrough to `:unknown`. Pure unit test, `async: true`.

### Phase 3 — Defence-in-depth scoping (S1)

- [ ] [W10R-T8][ecto] Change `Chat.get_message/1` signature to `get_message(user_id, id)` at [lib/ad_butler/chat.ex:230-238](../../../lib/ad_butler/chat.ex#L230). Implementation: `from(m in Message, join: s in Session, on: s.id == m.chat_session_id, where: m.id == ^id and s.user_id == ^user_id) |> Repo.one()`. Returns `{:ok, message} | {:error, :not_found}`. Update `@doc` to drop the "not tenant-scoped" warning — it now IS scoped.
- [ ] [W10R-T9][ecto] Update `Chat.get_message!/1` to `get_message!(user_id, id)` similarly. The bang version is currently unused outside tests; if the tests are the only callers, change them. Verify no other callers via grep first.
- [ ] [W10R-T10][liveview] Update sole caller at [show.ex:111](../../../lib/ad_butler_web/live/chat_live/show.ex#L111) to pass `socket.assigns.current_user.id`. The `case` on `{:ok, msg} | {:error, :not_found}` already exists — just thread the user_id.
- [ ] [W10R-T11][ecto] Update tests in [test/ad_butler/chat_test.exs](../../../test/ad_butler/chat_test.exs) `describe "get_message/1"` and `describe "get_message!/1"` blocks to pass user_id. Add cross-tenant test: user_b calling `get_message(user_b.id, user_a_msg.id)` returns `:not_found`.

### Phase 4 — `message_count` drift fix (S2)

- [ ] [W10R-T12][liveview] Drop `:message_count` assign from `ChatLive.Show`. Replace with a derived empty-state guard. Two consumers:
  - Empty-state placeholder at [show.ex:257](../../../lib/ad_butler_web/live/chat_live/show.ex#L257) — change `@message_count == 0 and is_nil(@streaming_chunk)` to use a new `:any_messages?` boolean assign that flips `false` initially, `true` on first `stream_insert` (handle in `:load` handler if `total > 0`, in `:turn_complete` handler unconditionally).
  - Remove from `mount/3` initial assigns and `:load` handler.
- [ ] [W10R-T13] Verify the empty-state branch still renders correctly via the existing connected-mount test at [show_test.exs:40](../../../test/ad_butler_web/live/chat_live/show_test.exs#L40) (with messages present) plus a new test for the empty-session case (no messages → "Start the conversation" placeholder visible).

### Phase 5 — Test gaps (W1-W4 + S6)

- [ ] [W10R-T14] [W1] Test `handle_async(:send_turn, {:ok, {:error, _}})` "Send failed" flash. Use `AdButler.Chat.LLMClientMock` to return `{:error, :rate_limited}` from `stream/2`. Steps: `expect(LLMClientMock, :stream, fn _, _ -> {:error, :rate_limited} end)`, set Mox mode `set_mox_from_context`, submit a non-empty form, assert flash + `:sending = false`. The full `start_async` → `Chat.send_message` → `Chat.Server` → mock chain runs.
- [ ] [W10R-T15] [W2] Test `handle_async(:send_turn, {:exit, _})` "Agent crashed" flash. Mock raises in `stream/2`: `expect(LLMClientMock, :stream, fn _, _ -> raise "boom" end)`. Assert flash + `:streaming_chunk = nil`. Indirectly exercises `LogRedactor.redact/1` on a 3-tuple exit reason.
- [ ] [W10R-T16] [W3] Test `{:tool_result, _, name, _}` PubSub handler. Direct broadcast `{:tool_result, sid, "get_findings", :ok}` after mount; assert `Calling get_findings…` text in render. Drop the assertion before the 2-second `clear_tool_indicator` fires.
- [ ] [W10R-T17] [W4] Test `{:turn_complete, _, :error}` cap-hit no-op. Prime `:streaming_chunk` via a chunk broadcast, then broadcast `{:turn_complete, sid, :error}`; assert chunk cleared, no flash, view alive.
- [ ] [W10R-T18] [S6] Test `Chat.subscribe/1` cross-session isolation in [test/ad_butler/chat_test.exs](../../../test/ad_butler/chat_test.exs). Subscribe to `chat:#{a.id}`, broadcast on `chat:#{b.id}`, `refute_receive` on the wrong topic. Documents the topic-isolation invariant.

### Phase 6 — Verification

- [ ] [W10R-T19] `mix compile --warnings-as-errors`
- [ ] [W10R-T20] `mix format --check-formatted`
- [ ] [W10R-T21] `mix credo --strict`
- [ ] [W10R-T22] `mix check.tools_no_repo`
- [ ] [W10R-T23] `mix test` — full suite; expect 579 + ~6 new = ~585 tests, 0 failures.

---

## Verification After Each Phase

```bash
mix compile --warnings-as-errors
mix format --check-formatted
mix test --only chat
```

End of plan:

```bash
mix compile --warnings-as-errors
mix format --check-formatted
mix check.tools_no_repo
mix credo --strict
mix test
```

---

## Risks (and mitigations)

1. **`Chat.get_message/2` signature change ripples.** The bang variant is referenced in tests; the non-bang one only at `show.ex:111`. Before changing, grep the codebase for both and update or delete unused callers.
   *Mitigation*: T9 explicitly says "Verify no other callers via grep first." If the bang variant is only test-internal, also consider deleting it.

2. **`:any_messages?` derivation race.** On a concurrent `:load` + `:turn_complete` sequence, the assign could flip in the wrong order if `handle_info` clauses race. Single LV process serialises messages, so no race in practice — but worth a comment.
   *Mitigation*: comment the invariant on the assign.

3. **Mox mode for W1/W2.** The chat LV mounts a real `Chat.Server` GenServer that calls `LLMClientMock.stream/2`. Mox global mode is required for cross-process calls; private mode would fail. Use `setup :set_mox_from_context` and configure expectations on the test process — Mox routes calls from the spawned `Chat.Server` back to the test pid.
   *Mitigation*: copy the pattern from existing chat-server tests (search `set_mox_from_context` in test/ad_butler/chat/).

4. **`tool_results_block/1` HEEx rewrite alters output.** The `<%= case %>` form returns the same tree as the `:if`-guarded form, but a misplaced `:for` could change the DOM. The existing test at [show_test.exs:179](../../../test/ad_butler_web/live/chat_live/show_test.exs#L179) verifies `<details>` and `Tool: get_findings`; the chart test at line 199 verifies `<svg`. Both should still pass.
   *Mitigation*: rerun `mix test test/ad_butler_web/live/chat_live/show_test.exs` after the rewrite.

---

## Self-Check

- **Have you been here before?** Yes — these fixes are review-driven. The patterns (Mox setup, tenant scoping joins, redactor extraction) all exist in the codebase. No novel territory.
- **What's the failure mode you're not pricing in?** A `Chat.Server` already running on a session at test time would route `LLMClientMock.stream` calls before Mox expectations are set, leading to a mock-not-found error. Mitigation: use a fresh session id per test (factory autoincrements UUIDs) and set the expectation BEFORE submitting the form. Worst case, the existing chat test files already solve this — copy their setup.
- **Where's the Iron Law violation risk?** Lifting `redact_reason/1` into a public module surfaces it to other Logger call sites — a future caller might pass it sensitive data and assume "safe." Mitigation: docstring on `LogRedactor.redact/1` says "reduces a free-form term to a non-content-bearing tag for structured logging — never round-trip the original term."

---

## Acceptance Criteria

- [ ] All 10 review-fix items from the triage doc converted to tasks (PASS — tasks above).
- [ ] `mix precommit` (or its underlying steps) clean.
- [ ] `mix test` 0 failures, ~585 tests.
- [ ] `Chat.get_message/2` and `get_message!/2` are tenant-scoped; old single-arg signatures removed.
- [ ] `AdButler.Chat.LogRedactor` exists with `@moduledoc` + `@doc`; `redact_reason/1` removed from `ChatLive.Show`; `Chat.Server` LLM-error log uses it.
- [ ] No `:message_count` assign in `ChatLive.Show`; `:any_messages?` (or equivalent) drives the empty-state branch.
- [ ] Test count up by ~6 (4 W's + 1 S6 + 1 LogRedactor); existing 579 pass.

---

## Out of Scope

- **S7 — JS test framework for `chat_scroll.js`** — deferred per triage decision; noted in [.claude/plans/week-10-chat-ui/scratchpad.md handoff](../week-10-chat-ui/scratchpad.md).
- **W10D5-T6 full Mox-mocked e2e test** — the Mox setup landed in W1/W2 above can be the foundation; the broader e2e (full stream + persistence + chart round-trip) remains a separate W11 task per the W10 plan handoff.
- **DaisyUI `card` in `theme_toggle/1`** — pre-existing leak, plan's D-W10-06 explicitly defers.
