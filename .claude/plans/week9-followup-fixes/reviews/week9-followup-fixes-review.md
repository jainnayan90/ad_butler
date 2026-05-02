# Review Summary — week9-followup-fixes

**Verdict: PASS WITH WARNINGS**

3 reviewers (elixir / security / testing) each delivered findings inline
because the Write tool was blocked in their environment; orchestrator
captured each agent's chat output verbatim into the per-agent files
under `reviews/` and logged the fallback in `scratchpad.md`. No agent
output was lost.

| Agent | BLOCKER | WARNING | SUGGESTION | NIT |
|-------|---------|---------|------------|-----|
| elixir-reviewer | 0 | 1 | 0 | 2 |
| security-analyzer | 0 | 0 | 2 | 2 |
| testing-reviewer | 0 | 2 | 2 | 0 |

After deconfliction (1 duplicate removed, 2 deferred items confirmed),
**3 warnings + 4 unique suggestions/nits** remain.

## Verifications of Prior-Review Concerns (RESOLVED)

The prior `/phx:full` review pass flagged the basename-`--exclude` flaw
in `mix.exs`. The fix moved the gate to `scripts/check_chat_unsafe.sh`
with path-anchored `grep -v '^lib/...:'`. Both elixir-reviewer and
security-analyzer independently verified this is sound:

- `grep -rn ... lib --include='*.ex'` (no trailing slash) emits
  canonical paths.
- The `^lib/ad_butler/chat/server.ex:` and `^lib/ad_butler/chat.ex:`
  filters reject any path that doesn't start with that exact prefix.
- A future `lib/foo/server.ex` cannot bypass the gate.

`Jason.encode` fallback, `kind_of/1` no-leak classifier, `redact: true`
schema coverage, partial-index non-enumeration: all verified clean.

---

## Warnings (3)

### W1 — Missing `tool`-role coverage on the partial unique index test
**File**: [test/ad_butler/chat_test.exs](test/ad_butler/chat_test.exs)
(`describe "request_id partial unique index"`)

Index predicate is `WHERE request_id IS NOT NULL` with no role filter.
Existing tests cover `assistant` (rejected) and `user` with nil
(allowed). Add a third test asserting two `tool`-role messages with the
same non-nil `request_id` are also rejected, locking in the
role-agnostic invariant.

### W2 — `assert_raise Ecto.ConstraintError` lacks constraint name
**File**: [test/ad_butler/chat_test.exs:208](test/ad_butler/chat_test.exs#L208)

Without a regex match on the constraint name, a future FK or check
constraint firing first would silently keep the test green even if the
partial unique index never engaged. Tighten:

```elixir
assert_raise Ecto.ConstraintError,
             ~r/chat_messages_request_id_unique_when_present/,
             fn -> ... end
```

### W3 — `kind_of/1` clause-order risk for future editors
**File**: [lib/ad_butler/chat/server.ex:351-354](lib/ad_butler/chat/server.ex#L351)

The implementation correctly puts `is_struct` before `is_map` (structs
satisfy `is_map/1`). The plan's scratchpad lists the inverted order in
the prose. No bug today; risk is a future edit reordering clauses based
on the prose. Add a one-line comment above the clauses or correct the
scratchpad description.

---

## Suggestions / NITs (4 unique)

### S1 — `format_tool_results/2` is `def @doc false` rather than `defp`
**File**: [lib/ad_butler/chat/server.ex:356-375](lib/ad_butler/chat/server.ex#L356)
(_flagged by elixir-reviewer NIT-2 + security SUGGESTION-1 — same finding_)

Pure function, low risk, but reachable from any module. Either keep
with an explicit `# Public only for unit testing — do not call from
outside Chat.Server` comment, or refactor to `defp` and test through
`react_step/7` integration.

### S2 — `cmd scripts/check_chat_unsafe.sh` relies on git execute bit
**File**: [mix.exs:114](mix.exs#L114)

Portable form: `cmd bash scripts/check_chat_unsafe.sh`. The execute
bit is preserved on macOS/Linux but lost on Windows checkouts and
`zip`-extracted archives. Cheap to harden.

### S3 — `serialise_tool_call/2` warning carries no `turn_id`
**File**: [lib/ad_butler/chat/server.ex:343-346](lib/ad_butler/chat/server.ex#L343)

Logger metadata has `session_id` and `kind` but not the `turn_id` that
identifies the assistant turn the malformed tool-call came from.
Threading `turn_id` from `ctx` would make the warning actionable in
log search.

### S4 — Document `@doc false` rationale at the test site
**File**: [test/ad_butler/chat/server_test.exs](test/ad_butler/chat/server_test.exs)
(`describe "format_tool_results/2"`)

The trade-off (rejecting tool-injection-via-Application-env) lives only
in the plan scratchpad. A future refactor moving back to `defp` would
silently break this test. One-line comment above the describe is
sufficient.

---

## Items Confirmed Deferred (no new evidence to act now)

- **Telemetry context-map redaction** — `Process.put` stores
  `request_id` in a plain map. No code path interpolates it today;
  re-flag in W10/W11 if a LiveView surfaces the context.
  ([lib/ad_butler/chat/telemetry.ex:25](lib/ad_butler/chat/telemetry.ex#L25))
- **Helper test placement opportunism** — already acknowledged in plan;
  promote to `helpers_test.exs` when the second helper test is added.
- **`decimal_to_float/_` silent type masking** — security-classified as
  no-leak; observability-only consideration.

---

## Test & Pre-existing Notes

- All 529 tests pass (`mix test` in test env).
- `mix credo --strict`: 1 pre-existing TODO in `compare_creatives.ex`
  (W11 follow-up — out of scope).
- Pre-existing style smells noted but not in diff:
  - `server.ex:320-327` `normalise_params/1` — `String.to_existing_atom`
    + `rescue ArgumentError`, safe given known tool-param atom universe.
  - `message.ex:68-76` `validate_content_required/1` — `if`-on-role,
    pre-existing style; not a regression.
