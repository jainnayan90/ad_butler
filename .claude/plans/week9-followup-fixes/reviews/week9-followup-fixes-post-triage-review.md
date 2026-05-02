# Re-Review Summary — week9-followup-fixes (post-triage)

**Verdict: PASS**

Re-review after the triage pass closed all 7 findings from the prior
review. 2 reviewers (elixir + testing) confirm every prior W/S RESOLVED.
One observation surfaces a pre-existing `@spec`/behavior mismatch that is
*adjacent to* the test diff but does not affect any code changed in this
triage; demoted to SUGGESTION and marked PRE-EXISTING.

| Agent | New BLOCKER | New WARNING | New SUGGESTION | New NIT |
|-------|-------------|-------------|----------------|---------|
| elixir-reviewer | 0 | 0 | 0 | 0 |
| testing-reviewer | 0 | 0 | 1 (PRE-EXISTING) | 0 |

Both reviewers' Write tools were denied; orchestrator captured each
output verbatim into `reviews/elixir-post-triage.md` and
`reviews/testing-post-triage.md` with EXTRACTED FROM AGENT MESSAGE
banners (logged in scratchpad).

---

## Prior Findings — All RESOLVED

| ID | Verified by | Note |
|----|-------------|------|
| W1 | elixir + testing | tool-role test at `chat_test.exs:220-243` |
| W2 | elixir + testing | 4-arg `assert_raise` with constraint regex on all 3 tests |
| W3 | elixir | comment at `server.ex:352-354` accurately states the invariant |
| S1 | elixir | visibility comment correctly placed above `@doc false` at `server.ex:360` |
| S2 | elixir | `mix.exs:114` confirmed `cmd bash scripts/check_chat_unsafe.sh` |
| S3 | elixir | `serialise_tool_call/3` + `persist_tool_turn/4` cascade is internally consistent (one call site each, no missed callers, happy-path arity correct) |
| S4 | testing | comment at `server_test.exs:308-311` references scratchpad D-FU |

---

## New Findings

### S5 (PRE-EXISTING) — `append_message/1` `@spec` doesn't declare `Ecto.ConstraintError`

**Surfaced by**: testing-reviewer
**Files**: [lib/ad_butler/chat/message.ex](lib/ad_butler/chat/message.ex)
(no `unique_constraint/3`),
[lib/ad_butler/chat.ex:225](lib/ad_butler/chat.ex#L225) (`append_message/1` `@spec`)

**Status**: PRE-EXISTING — neither file was touched by the triage. The
test diff (W1 + W2) merely *exercises* the existing behavior with
tighter assertions. The plan handoff explicitly decided that
`Ecto.ConstraintError` is the intended behavior for now and that
`on_conflict: :nothing` should wait until a real retry path lands in
W11.

**Observation**: The current behavior is correct. The @spec on
`append_message/1` doesn't mention that the call may raise
`Ecto.ConstraintError` on a duplicate `request_id` (the only existing
caller, `Chat.Server`, lives in the same context and tolerates the
crash via per-session supervisor restart). When a future caller
(W10/W11 LiveView, or a retry-on-conflict worker) actually depends on
the tuple-return contract, this mismatch becomes a real bug.

**Decision needed at W11 time**, not now. Options when picked up:
1. Add `unique_constraint(:request_id, name: :chat_messages_request_id_unique_when_present)` to `Message.changeset/2` and surface the violation as `{:error, changeset}` from `append_message/1` (matches `@spec`).
2. Switch to `on_conflict: :nothing, conflict_target: [:request_id]` for assistant/tool rows (silent retry — matches the `LLM.insert_usage` pattern at `lib/ad_butler/llm.ex:72`).
3. Update the `@spec` to explicitly declare the raise.

This entry supersedes the existing scratchpad handoff bullet about
`on_conflict: :nothing`; same root concern, more specific framing.

---

## Test & Compile

- 530/0 tests (W1 added one test; was 529 before triage).
- `mix credo --strict`: only the pre-existing `compare_creatives.ex`
  TODO (W11 follow-up).
- `mix check.unsafe_callers` and `mix check.tools_no_repo`: green.
