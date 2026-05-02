# Review: week-10-review-fixes — fix-fixes pass

**Date**: 2026-05-02
**Branch**: `week-10-chat-ui` (uncommitted, on top of `37009d1`)
**Source triage**: [.claude/plans/week-10-review-fixes/reviews/week-10-review-fixes-triage.md](week-10-review-fixes-triage.md)
**Reviewers**: elixir-reviewer, testing-reviewer, iron-law-judge

## Verdict

**PASS** — All 8 triage items substantively resolved. One sibling-banner nit found and fixed during this review pass. Nothing blocks commit.

## Findings

### Resolved during review

**Sibling banner — `# get_message!/1` not renamed alongside `describe "get_message!/2"`**
- *elixir-reviewer*: `test/ad_butler/chat_test.exs:463`
- L3 caught the `# update_message_tool_results/2` banner at line 516 but missed
  the `# get_message!/1` banner at line 463 above the (already-renamed)
  `describe "get_message!/2"`. Fixed inline (`!/1` → `!/2`).

### Confirmed clean

- **M1 race fix** (testing + elixir) — `"All chats"` only renders inside
  `<div :if={@session}>`, so `assert render(view) =~ "All chats"` is a
  deterministic gate proving `:load` has run. `Chat.subscribe/1` is called
  inside the same handler before the `:session` assign, so the PubSub
  subscription is live by the time the assertion passes.
- **M2 `stub(:stop)` comment** (testing + elixir) — accurately describes
  why the stub stays. `verify_on_exit!` enforces `expect/3`, not `stub/3`.
- **M3 `@doc` extension** — caller-contract warning is correct; the
  prose-rephrased "Used by..." line trades a small loss of ExDoc
  cross-link for `check.unsafe_callers` cleanliness.
- **L1 `reraise` shape** (elixir) — `Ecto.NoResultsError, [queryable: Message], __STACKTRACE__`
  matches `Repo.one!/1`'s internal raise shape. Test exercises it.
- **L2 timeout bump** — 1_000ms matches the W2 crash-path test.
- **L4 `:any_messages?` comment** — documents the load-bearing
  subscribe-before-flip ordering invariant.
- **L5 `nil` example** — trivially correct; `nil` is `is_atom/1` true.

## Iron Laws

PASS — 0 violations across the 4 changed lib files. `rescue Ecto.Query.CastError`
is third-party rescue (allowed). No new `inspect/1` in Logger metadata.
No `String.to_atom/1` on user input. All public defs already had `@doc`.

## Tests

PASS — full suite remains 595 / 0 failures. The new `get_message!/2`
malformed-UUID parity test exercises the new rescue clause directly.

## Next Step

The branch is ready to commit. No further fixes warranted.
