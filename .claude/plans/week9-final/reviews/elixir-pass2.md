# Code Review: W9 Final — Pass 2 (Fix Verification)

> **⚠️ EXTRACTED FROM AGENT MESSAGE** — Write denied to agent; orchestrator captured chat output verbatim.

**Status**: Changes Requested (1 new WARNING)
**Issues**: 1 WARNING, 2 SUGGESTIONs. All 5 prior findings confirmed resolved.

---

## Prior Findings — All Resolved

- **W1** `analytics.ex` — `bin_to_uuid/1` now uses `case Ecto.UUID.load/1` + nil fallback; `flat_map`-drop in `delivery_by_id` is correct. RESOLVED.
- **W2** `ads.ex` — `filter_owned_ad_ids/2` pre-filters via `Ecto.UUID.cast/1` using `Enum.flat_map`; blanket `rescue` removed. RESOLVED.
- **S1** `server.ex:320-338` — `normalise_params/1` uses `Enum.reduce` with per-key `try/rescue`; valid atom keys survive; single `Logger.warning` logged at end with `unknown_keys:` list. RESOLVED.
- **S2** `compare_creatives.ex:79-85` — `health_metric/2` now three pattern-matched heads. RESOLVED.
- **N1** `analytics.ex:309` — `if owned == []` replaces redundant `case` clause. RESOLVED.

---

## WARNING

**`compare_creatives.ex:79-85` — non-exhaustive `health_metric/2` causes runtime `FunctionClauseError` on unknown keys**

The three heads cover `nil`, `%AdHealthScore{} + :fatigue_score`, and `%AdHealthScore{} + :leak_score`. Any other combination — e.g. a valid `%AdHealthScore{}` with an unrecognised atom key — raises `FunctionClauseError`. The two call sites (lines 74-75) only ever pass `:fatigue_score` and `:leak_score` today, so this is currently safe, but there is no compile-time enforcement. Adding a third metric key at a call site without a matching head will crash in production.

```elixir
defp health_metric(%AdHealthScore{} = score, key) do
  Logger.warning("chat: unknown health metric key", key: key, ad_id: score.ad_id)
  nil
end
```

---

## Suggestions

1. **`ads.ex:174-186`** — `case valid do [] -> ...` nesting is one level deep unnecessarily. The `[]` head at line 163 already handles empty input; an `if valid == [], do: [], else: ...` would flatten. Low priority — code is correct.

2. **`analytics.ex:377`** — catchall `bin_to_uuid(_)` returns nil silently. A non-binary term is a caller contract violation; consider a `Logger.warning/2` so schema drift surfaces in logs rather than quietly dropping rows.
