# Iron Law Review — Week 7 Creative Fatigue

⚠️ EXTRACTED FROM AGENT MESSAGE (Write tool unavailable in agent env)

**Files scanned:** 10 | **Iron Laws checked:** 20 | **Violations:** 3 (1 BLOCKER, 1 WARNING, 1 SUGGESTION)

---

## BLOCKER

### [Iron Law #15/#16] N+1 `Repo.update_all` in `append_quality_ranking_snapshots`
`lib/ad_butler/ads.ex:550-561`

```elixir
Enum.each(pairs, fn {ad_id, snapshot} -> ... Repo.update_all(...) end)
```

Confidence: DEFINITE — one UPDATE per ad inside `Enum.each`. 50 ads → 50 serial DB round-trips per metadata sync. Both Iron Law #15 (N+1) and #16 (bulk ops > 10 rows) violated.

**Fix:** Build the complete `{ad_id → new_history}` map in memory, then a single `Repo.insert_all` with `on_conflict: {:replace, [:quality_ranking_history]}` — or `Repo.update_all` with a `CASE/WHEN` fragment. `load_existing_history/1` already bulk-fetches in one query; the write side must match.

---

## WARNING

### [Iron Law #8] `with true <- prior_cpm > 0` silently swallows a false branch
`lib/ad_butler/analytics.ex:348-354`

Bare boolean in a `with` chain falls to `else _ -> nil` with no log, no error tag, no distinguishable reason. If `avg_cpm/1` ever returns `{:ok, 0.0}` for a valid zero-spend window, this silently drops the result. Iron Law #8: no silent error swallowing.

**Fix:** Remove the boolean guard and handle zero-prior-CPM inside `avg_cpm/1`. Never use `true <- expr` in a `with` chain.

---

## SUGGESTION

### [Iron Law #10] `inspect(v)` in fallback `format_fatigue_values` exposes internal term syntax to UI
`lib/ad_butler_web/live/finding_detail_live.ex:233`

Currently unreachable in prod (all heuristic shapes matched above), but pattern is fragile. A future heuristic with unexpected value shape would render Elixir internal syntax (`#PID<>`, struct reprs) directly in user-facing HTML. Per Iron Law #10, `inspect/1` is a developer tool and must not surface in the UI.

**Fix:** Replace fallback with `defp format_fatigue_values(_kind, _values), do: ""` and add a `Logger.warning("format_fatigue_values: unrecognised kind #{kind}")`.

---

## Migration Safety (no violation)

Migration #2 (`make_leak_score_nullable`) is correctly structured: `def up` / `def down` with a backfill UPDATE before re-imposing `NOT NULL` in the rollback path. Follows CLAUDE.md three-migration pattern. Safe to merge.

---

## Verified Clean

- Worker never calls Repo directly (Iron Law #1 pass)
- All `unsafe_*` functions consistently named and documented
- Oban worker uses string keys, has `unique:`, stores only IDs
- `findings_live.ex` uses `stream/3` and pagination
- No `String.to_atom`, no `raw(`, no DaisyUI classes in changed files
