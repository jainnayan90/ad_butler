# Test Review: Post-Triage Re-Review (testing-reviewer)

> **⚠️ EXTRACTED FROM AGENT MESSAGE** — agent reported Write tool denied; orchestrator captured chat output verbatim. See `scratchpad.md` 2026-05-02 entry.

**Files reviewed:** `test/ad_butler/chat_test.exs`, `test/ad_butler/chat/server_test.exs`

## Summary

Prior findings W1, W2, and S4 are correctly resolved. One latent correctness risk identified around how `Ecto.ConstraintError` propagates through `append_message/1`; no Iron Law violations found.

## Iron Law Violations

None.

## Issues Found

### Critical

None.

### Warnings

**W1 constraint propagation gap** (`chat_test.exs` lines 208–217, 233–242)

`Message.changeset/2` has no `unique_constraint(:request_id, name: :chat_messages_request_id_unique_when_present)` declaration. When the DB index fires, Ecto raises `Ecto.ConstraintError` (uncaught) instead of returning `{:error, changeset}`. The tests correctly assert the raise — they accurately document actual runtime behaviour. However, actual behaviour deviates from `append_message/1`'s `@spec`, which declares only `{:ok, t} | {:error, Ecto.Changeset.t()} | {:error, :session_not_found}`. Any production caller expecting a tuple return on duplicate `request_id` will receive an uncaught exception. Fix: add `unique_constraint(:request_id, name: :chat_messages_request_id_unique_when_present)` to `Message.changeset/2` and update `append_message/1` to handle it, then update the tests to assert `{:error, changeset}` instead of `assert_raise`.

### Suggestions

**`assert_raise` regex correctness** — `assert_raise/3` with a regex matches against `Exception.message(exception)`. `Ecto.ConstraintError` embeds the constraint name in its message, so `~r/chat_messages_request_id_unique_when_present/` will match correctly given the migration uses `name: :chat_messages_request_id_unique_when_present`. Sound as-is.

**Cross-session duplicate `request_id`** — The index is global (not per-session). A cross-session collision would also raise. Not testing this is fine; it is an edge case not relevant to the current coverage goals.

## Prior Findings Status

| Finding | Status |
|---------|--------|
| W1 — new tool-role duplicate `request_id` test | RESOLVED — test present at lines 220–243 |
| W2 — `assert_raise` with regex message pattern | RESOLVED — used correctly in all three tests |
| S4 — comment explaining direct `format_tool_results/2` testing | RESOLVED — comment added at lines 308–311 in `server_test.exs` |
