# Elixir Idiom Review — Week 9 Review-Fix Changes

**Status**: ⚠️ Changes Requested
**Issues Found**: 4 (0 blockers, 2 warnings, 2 suggestions)

---

## BLOCKERS

None.

---

## WARNINGS

### W1 — Logger metadata keys `turn_id` and `conversation_id` not allowlisted
`lib/ad_butler/chat/telemetry.ex` writes these as DB columns, not Logger metadata, so no current log call drops them. But the allowlist in `config/config.exs:88-143` does not include `:turn_id` or `:conversation_id`. Any future `Logger.*` call using these keys will silently drop without a compiler warning. Pre-allowlist them now:

```elixir
# config/config.exs — add to the metadata list:
:turn_id,
:conversation_id,
```

### W2 — `decimal_to_float/1` has no fall-through clause — raises on unexpected input
`lib/ad_butler/chat/tools/helpers.ex:45-48`

```elixir
def decimal_to_float(nil), do: nil
def decimal_to_float(%Decimal{} = d), do: Decimal.to_float(d)
def decimal_to_float(n) when is_number(n), do: n / 1
# No catch-all — passes a binary or atom raises FunctionClauseError
```

The `@spec` documents `nil | Decimal.t() | number()` so callers should be safe, but a misuse (e.g. a health row field returns a binary) will crash the tool process with no descriptive error. Add:

```elixir
def decimal_to_float(_), do: nil
```

---

## SUGGESTIONS

### S1 — `react_loop` try/after correctness is correct but needs a comment
`lib/ad_butler/chat/server.ex:199-221`

The `react_step/7` tool-cap abort path returns from inside `handle_stream_result/5` which is wrapped by `react_loop`'s `try/after`. `Telemetry.clear_context()` runs on every path including cap abort — verified correct. The recursive `react_loop` call in the else branch owns its own `set_context`/`clear_context` pair. Add a one-line comment on `react_loop/3` noting "each recursive invocation owns its own try/after pair" to prevent future reviewers from second-guessing this.

### S2 — `CompareCreatives.summary_row/1` 4×N Analytics calls (acknowledged TODO)
`lib/ad_butler/chat/tools/compare_creatives.ex:63-66`

4 queries × up to 5 ads = 20 DB round-trips. The `# TODO(W11): bulk fetch` comment exists — this is a pre-existing acknowledged issue. Flagging so it doesn't slip W11 triage. CLAUDE.md: "N+1 queries are bugs."

---

## Pre-existing (outside diff — one-liners)

- `lib/ad_butler/chat/server.ex:322-328` — `normalise_params/1` rescues `ArgumentError` from `String.to_existing_atom/1` and silently returns the original string-keyed map; a caller gets atom keys for known params and string keys for unknown ones in the same map, which is a confusing mixed-key shape. Consider returning `{:error, :unknown_param}` or logging the fallback.
