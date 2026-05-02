# Code Review: week9-followup-fixes post-triage (elixir-reviewer)

> **⚠️ EXTRACTED FROM AGENT MESSAGE** — agent reported Write tool denied; orchestrator captured chat output verbatim. See `scratchpad.md` 2026-05-02 entry.

## Summary

- **Status**: Approved
- **Issues Found**: 0 new issues

All 7 triage fixes (W1, W2, W3, S1, S2, S3, S4) are correctly implemented. No regressions or new anti-patterns introduced.

---

## Prior Findings Verification

**W1 — `tool`-role test added** RESOLVED. `test/ad_butler/chat_test.exs:220` adds the third test with the correct role, constraint regex, and structure.

**W2 — `assert_raise` tightened** RESOLVED. Both the assistant-role test (line 208) and tool-role test (line 233) use the 4-arg form with `~r/chat_messages_request_id_unique_when_present/`.

**W3 — `is_struct` precedes `is_map` comment** RESOLVED. Comment at `server.ex:352–354` is accurate and explains the ordering invariant.

**S1 — visibility comment placement** RESOLVED. `server.ex:360` — prose comment appears above `@doc false`, correct ordering.

**S2 — `cmd bash`** RESOLVED. `mix.exs:114` confirmed: `"cmd bash scripts/check_chat_unsafe.sh"`.

**S3 — `serialise_tool_call/2` → `/3` with `turn_id`** RESOLVED. The arity change is internally consistent: `persist_tool_turn` is now `/4` at line 329, called once from `react_step` at line 256 passing `ctx.turn_id`. The happy-path clause correctly underscores `_session_id` and `_turn_id`. Both functions are `defp` with exactly one call site each — no missed callers.

**S4 — `format_tool_results/2` describe comment** RESOLVED. `server_test.exs:308–311` has the 4-line comment referencing scratchpad D-FU decisions above the describe block.

---

## New Issues

None.
