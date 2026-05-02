# Test Review: week9-followup-fixes (testing-reviewer)

> **⚠️ EXTRACTED FROM AGENT MESSAGE** — agent reported Write tool blocked; orchestrator captured chat output verbatim. See `scratchpad.md` 2026-05-02 entry.

## Summary

Three test sections added: a partial-index constraint test in `chat_test.exs`, a `format_tool_results/2` unit test in `server_test.exs`, and a `decimal_to_float/1` fall-through test appended to `get_ad_health_test.exs`. All pass with `async: true`/`async: false` correctly set, `verify_on_exit!` present, no `Process.sleep` outside the documented OTP hibernate exemption. No Iron Law violations found. Four issues follow.

## Iron Law Violations

None.

## Issues Found

### Warnings

- [ ] **Missing `tool`-role coverage for the partial unique index** — `chat_test.exs`, `"request_id partial unique index"` describe block

  The DB constraint is `WHERE request_id IS NOT NULL` with no role column in the predicate. The two current tests only exercise `assistant` (duplicate rejected) and `user` with `nil` (allowed). A third test should assert two `tool`-role messages with the same non-nil `request_id` are also rejected, confirming the index is role-agnostic. Without it, any future code stamping `request_id` on tool messages could silently violate or reveal that the constraint is scoped differently than assumed.

- [ ] **`assert_raise` without constraint name allows silent regression** — `chat_test.exs`, line 208

  `assert_raise Ecto.ConstraintError, fn -> ... end` does not verify _which_ constraint fired. If the session FK or another constraint hits first the test still passes without the partial unique index being exercised. Tighten to:
  ```elixir
  assert_raise Ecto.ConstraintError,
               ~r/chat_messages_request_id_unique_when_present/,
               fn -> ... end
  ```

### Suggestions

- [ ] **Document `@doc false` exposure rationale in the test** — `server_test.exs`, `"format_tool_results/2"` describe block (lines 308-324)

  The plan scratchpad records why injection through the LLM/Tools dispatch path was rejected. That rationale is absent in the test file. A future reader may refactor away the `@doc false` exposure without realising the test depends on it. One comment line above the describe is sufficient: `# Tested directly — tool dispatch injection rejected as too invasive (see plan scratchpad).`

- [ ] **Helper test placement is opportunistic** — `get_ad_health_test.exs`, lines 96-101

  The plan itself acknowledges this. `Helpers` is used by multiple tools; `GetAdHealth` is just the heaviest decimal user. Acceptable now, but a dedicated `test/ad_butler/chat/tools/helpers_test.exs` should be created when a second helper test is added, rather than letting helper tests accumulate in unrelated files.
