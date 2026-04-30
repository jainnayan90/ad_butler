# Week 7 — Creative Fatigue: Heuristic Layer

**Review verdict: REQUIRES CHANGES**

4 specialist agents reviewed: elixir-reviewer, oban-specialist, testing-reviewer, iron-law-judge. After deconfliction and anti-noise filter:

- **3 BLOCKERS** — must fix before commit
- **6 WARNINGS** — should fix before commit
- **5 SUGGESTIONS** — defer or address opportunistically

---

## BLOCKERS (3)

### 1. N+1 `Repo.update_all` in `Ads.append_quality_ranking_snapshots/2`
[lib/ad_butler/ads.ex:550-561](lib/ad_butler/ads.ex#L550)

`Enum.each(pairs, fn {ad_id, snapshot} -> ... Repo.update_all(...) end)` fires one UPDATE per ad on every metadata sync. 50 ads → 50 round-trips. Violates Iron Laws #15 (N+1) and #16 (bulk ops > 10 rows). Both elixir-reviewer and iron-law-judge flagged independently.

**Fix:** Build the `{ad_id → new_history}` map in memory, then either (a) single `Repo.insert_all` with `on_conflict: {:replace, [:quality_ranking_history]}, conflict_target: [:id]`, or (b) `Repo.update_all` with a `CASE/WHEN` SQL fragment, or (c) at minimum wrap the existing loop in `Repo.transaction/1`.

### 2. Non-atomic finding/score write breaks retry idempotency
[lib/ad_butler/workers/creative_fatigue_predictor_worker.ex:211-250](lib/ad_butler/workers/creative_fatigue_predictor_worker.ex#L211)

If findings emit successfully but `Analytics.bulk_insert_fatigue_scores/1` raises (or process dies), the job retries. On retry, `unsafe_list_open_finding_keys/1` returns those findings as already-open → every ad hits `:skipped` → `entries` empty → no scores written → silent `:ok`. Health scores lost for the entire 6-hour bucket.

**Fix:** Pick one — (a) emit a score `entry` even in `:skipped` branch, (b) write `bulk_insert_fatigue_scores` *before* findings, or (c) wrap both in `Repo.transaction/1`. BudgetLeakAuditorWorker uses `reduce_while` + `with` to halt on error — mirror that pattern.

### 3. `length/1` guard on list violates pattern-matching law
[lib/ad_butler/workers/creative_fatigue_predictor_worker.ex:134](lib/ad_butler/workers/creative_fatigue_predictor_worker.ex#L134)

```elixir
defp detect_quality_drop(snapshots) when length(snapshots) < 2, do: :skip
```

`length/1` traverses the whole list. CLAUDE.md: "Pattern-match in function heads, not in `case` blocks inside the body."

**Fix:**
```elixir
defp detect_quality_drop([]), do: :skip
defp detect_quality_drop([_]), do: :skip
defp detect_quality_drop(snapshots), do: ...
```

---

## WARNINGS (6)

### 4. `with true <- prior_cpm > 0` silently swallows the false branch
[lib/ad_butler/analytics.ex:348-354](lib/ad_butler/analytics.ex#L348)

Bare boolean falls to `else _ -> nil` with no error tag. Iron Law #8: no silent error swallowing.

**Fix:** Move the zero-prior-CPM check inside `avg_cpm/1` (return `:insufficient` when total_spend == 0). Drop the `with true <- …` guard.

### 5. `maybe_emit_finding/5` return value discarded
[lib/ad_butler/workers/creative_fatigue_predictor_worker.ex:227](lib/ad_butler/workers/creative_fatigue_predictor_worker.ex#L227)

Finding-creation `{:error, reason}` is logged but the job still returns `:ok`. Permanently lost finding. BudgetLeakAuditor's `apply_check/5` halts on `{:error, reason}` — mirror it.

### 6. Kill-switch is compile-time (config.exs), not runtime
[lib/ad_butler/workers/audit_scheduler_worker.ex:33](lib/ad_butler/workers/audit_scheduler_worker.ex#L33)

The moduledoc claims it can "pause without redeploying" but `config :ad_butler, fatigue_enabled` lives in `config.exs` — baked at compile time in mix releases.

**Fix:** Either move to `config/runtime.exs` reading `System.get_env("FATIGUE_ENABLED")`, or correct the moduledoc.

### 7. Stale `@moduledoc` on AdHealthScore
[lib/ad_butler/analytics/ad_health_score.ex:3](lib/ad_butler/analytics/ad_health_score.ex#L3)

Says "computed by `BudgetLeakAuditorWorker`" — Week 7 made `CreativeFatiguePredictorWorker` an equal writer. CLAUDE.md: docs ship in same commit as code.

### 8. `insert_daily/3` duplicated across two test files with schema divergence
[test/ad_butler/analytics_test.exs:11](test/ad_butler/analytics_test.exs#L11) vs [test/ad_butler/workers/creative_fatigue_predictor_worker_test.exs:74](test/ad_butler/workers/creative_fatigue_predictor_worker_test.exs#L74)

Analytics version takes `cpm_cents` and `reach_count` from attrs; worker version hard-codes `reach_count: 0` and ignores `cpm_cents`. Extract to `test/support/insights_helpers.ex`.

### 9. Tenant isolation in worker test passes by absence, not by genuine scoping
[test/ad_butler/workers/creative_fatigue_predictor_worker_test.exs:463-498](test/ad_butler/workers/creative_fatigue_predictor_worker_test.exs#L463)

The "scaffold contract" test ensures account A has no ads — so account B's data is never queried regardless of scoping. Real test: account A has ads with NO triggering signals, account B has separate ads that WOULD fire heuristics; running for A must not touch B's findings.

---

## SUGGESTIONS (5)

10. **Unused `_emit_count` accumulator** — replace `Enum.reduce` with `Enum.flat_map`. [worker:217](lib/ad_butler/workers/creative_fatigue_predictor_worker.ex#L217)
11. **`_window_days` parameter ignored** — remove the param or use it. Currently a footgun for callers. [analytics.ex:320](lib/ad_butler/analytics.ex#L320)
12. **`inspect(v)` fallback in `format_fatigue_values`** — currently unreachable but a future heuristic with unexpected shape would render `#PID<>` etc. directly to UI. Replace with empty string + `Logger.warning`. [finding_detail_live.ex:233](lib/ad_butler_web/live/finding_detail_live.ex#L233)
13. **`six_hour_bucket/0` duplicated** verbatim in both audit workers. Extract to shared helper.
14. **Pool size comment in `config.exs` is stale** — total worker slots now 50 (was 25); recommend `>= 60` in `.env.example`. [config.exs:138](config/config.exs#L138)

---

## Notes (filtered as low-signal)

- Testing-reviewer's BLOCKER-2 (partition concurrency race): verified — `create_insights_partition` uses `CREATE TABLE IF NOT EXISTS` (priv/repo/migrations/20260426100002), idempotent. Demoted.
- Testing-reviewer's BLOCKER-1 (kill-switch global state): only the scheduler reads `:fatigue_enabled`, and that test is `async: false`. Real risk is low. Demoted but addressable via #6.
- UI-copy assertions in LiveView tests: legitimate trade-off; reasonable to assert template output for behavior tests. Not flagged.

---

## Verified Clean

- Both migrations reversible; migration 2 has explicit `up`/`down` with backfill.
- Oban args use string keys; `unique:` config on both workers honors the [solved-pattern](`.claude/solutions/oban/unique-keys-requires-args-in-fields-20260429.md`).
- Worker never touches `Repo` directly (Iron Law #1 pass).
- All public functions have `@spec` and `@doc`.
- `findings_live.ex` uses `stream/3` and pagination.
- No `String.to_atom`, no `raw(`, no DaisyUI classes.
- `connected?(socket)` checked before LiveView data loads.
