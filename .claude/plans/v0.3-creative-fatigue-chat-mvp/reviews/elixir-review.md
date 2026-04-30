# Elixir Code Review — Week 7 Creative Fatigue

⚠️ EXTRACTED FROM AGENT MESSAGE (Write tool unavailable in agent env)

**Status:** Changes Requested | **Issues:** 7 (2 BLOCKER, 3 WARNING, 2 SUGGESTION)

---

## BLOCKER

### 1. N+1 `Repo.update_all` inside `Enum.each`
`lib/ad_butler/ads.ex:550-561`

`append_quality_ranking_snapshots/2` fires one `Repo.update_all` per ad inside `Enum.each`. For an account with 50 ads that is 50 round-trips per metadata sync.

No single-statement bulk fix exists because each ad has a different merged JSONB value. Correct approaches:
- (a) push the merge into a single SQL `CASE`/`jsonb_build_object` expression
- (b) at minimum wrap all updates in `Repo.transaction/1` so partial failure doesn't leave half-updated rows

Rule violated: CLAUDE.md — "N+1 queries are bugs. Use bulk operations for anything over ~10 rows."

### 2. `length/1` guard on list traversal
`lib/ad_butler/workers/creative_fatigue_predictor_worker.ex:134`

```elixir
defp detect_quality_drop(snapshots) when length(snapshots) < 2, do: :skip
```

`length/1` traverses the whole list. Use pattern-match heads:

```elixir
defp detect_quality_drop([]), do: :skip
defp detect_quality_drop([_]), do: :skip
defp detect_quality_drop(snapshots), do: ...
```

Rule violated: CLAUDE.md — "Pattern-match in function heads."

---

## WARNING

### 3. `if triggered == []` instead of pattern match
`lib/ad_butler/workers/creative_fatigue_predictor_worker.ex:221`

Replace with a `case` on `run_all_heuristics/1` return value, pattern-matching `[]` and `triggered` directly.

### 4. `with true <- prior_cpm > 0` mixes bare boolean into tagged-tuple chain
`lib/ad_butler/analytics.ex:348-351`

A failing boolean produces opaque `false` in the `else` arm. Since `avg_cpm/1` already returns `:insufficient` for zero spend the guard is redundant — remove it, or convert to an explicit tagged tuple.

### 5. Stale `@moduledoc` on AdHealthScore
`lib/ad_butler/analytics/ad_health_score.ex:3`

Still says "computed by `BudgetLeakAuditorWorker`" — Week 7 made `CreativeFatiguePredictorWorker` an equal writer. Update in same commit per CLAUDE.md doc-with-code rule.

---

## SUGGESTION

### 6. Unused `_emit_count` accumulator
`lib/ad_butler/workers/creative_fatigue_predictor_worker.ex:217`

The counter is accumulated but discarded (`{entries, _emit_count}`). Replace `Enum.reduce` with `Enum.flat_map`.

### 7. `_window_days` parameter silently ignored
`lib/ad_butler/analytics.ex:320`

```elixir
def get_cpm_change_pct(ad_id, _window_days \\ 7) do
```

Always uses hard-coded 7-day window. Remove the parameter, or use it. As-is, callers passing a different value get wrong results with no error.

---

## Verified Clean

- Oban args use string keys throughout; `unique` config correct on both workers.
- `connected?(socket)` checked before data loads in both LiveViews.
- No `String.to_atom` on user input anywhere in new code.
- All public functions have `@spec` and `@doc`.
- Both migrations are reversible (migration 2 has explicit `up`/`down`).
- Test file covers all three heuristics, integration scoring, dedup, and tenant isolation.
