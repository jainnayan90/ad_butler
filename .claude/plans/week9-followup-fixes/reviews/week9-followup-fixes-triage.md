# Triage — week9-followup-fixes-review

**Source**: [week9-followup-fixes-review.md](week9-followup-fixes-review.md)
**Date**: 2026-05-02
**Decision summary**: Fix all 7 findings. None deferred, none skipped.

---

## Fix Queue (7)

### Warnings

- [x] **W1 — Add `tool`-role coverage to partial unique index test**
  - **File**: `test/ad_butler/chat_test.exs` — `describe "request_id partial unique index"`
  - **Action**: Add a third test asserting two `tool`-role messages with the
    same non-nil `request_id` are also rejected, locking in the
    role-agnostic invariant of the partial index.

- [x] **W2 — Tighten `assert_raise` with constraint-name regex**
  - **File**: [test/ad_butler/chat_test.exs:208](../../../test/ad_butler/chat_test.exs#L208)
  - **Action**: Change `assert_raise Ecto.ConstraintError, fn -> ... end`
    to `assert_raise Ecto.ConstraintError, ~r/chat_messages_request_id_unique_when_present/, fn -> ... end`
    on every test in the describe block (so a future FK or check
    constraint firing first cannot mask the partial index never engaging).

- [x] **W3 — Add `is_struct must precede is_map` comment in `kind_of/1`**
  - **File**: [lib/ad_butler/chat/server.ex:351-354](../../../lib/ad_butler/chat/server.ex#L351)
  - **Action**: Inline one-line comment above the clauses. User chose
    code comment over scratchpad prose fix because the comment
    protects future editors who never read the scratchpad.

### Suggestions

- [x] **S1 — `format_tool_results/2` visibility comment**
  - **File**: [lib/ad_butler/chat/server.ex:356-375](../../../lib/ad_butler/chat/server.ex#L356)
  - **Action**: Keep `@doc false def`; add comment
    `# Public only for unit testing — do not call from outside Chat.Server.`
    above the `@doc false`. User rejected the defp+integration-test
    refactor as scratchpad already rejected tool-injection-via-app-env.

- [x] **S2 — `cmd bash scripts/check_chat_unsafe.sh`**
  - **File**: [mix.exs:114](../../../mix.exs#L114)
  - **Action**: Prepend `bash` to the cmd invocation so the alias works
    without the executable bit (Windows / zip-extracted checkouts).

- [x] **S3 — Thread `turn_id` into `serialise_tool_call` warning**
  - **File**: [lib/ad_butler/chat/server.ex:343-346](../../../lib/ad_butler/chat/server.ex#L343)
  - **Action**: `serialise_tool_call/2` is called from
    `persist_tool_turn/3` which only knows `session_id`. Either:
    (a) accept losing turn_id correlation (simpler — log already has
    session_id; turn-level joins via `chat_messages.inserted_at` are
    possible), or
    (b) thread `turn_id` from `react_step/7` → `persist_tool_turn/4`
    → `serialise_tool_call/3`. Default to (b) for actionability per
    the agent's recommendation.

- [x] **S4 — Document `@doc false` rationale in test**
  - **File**: `test/ad_butler/chat/server_test.exs` —
    `describe "format_tool_results/2"`
  - **Action**: One-line comment above the describe:
    `# Tested directly — tool dispatch injection rejected as too invasive (see plan scratchpad D-FU-02).`

---

## Skipped

(none)

## Deferred

(none — all 4 deferred items from review summary were already in
the original plan handoff and remain deferred to W10/W11 unchanged)
