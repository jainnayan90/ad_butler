# Week 7 Triage — Fix Queue

**Source review:** [.claude/plans/v0.3-creative-fatigue-chat-mvp/reviews/week7-review.md](week7-review.md)
**Decision:** All 14 findings approved for fix. User direction: "just fix them" — pick the cleanest fix per item.

## Fix Queue (14)

### Blockers

- [ ] **B1** [Iron Law #15/#16] — N+1 in `Ads.append_quality_ranking_snapshots/2` ([lib/ad_butler/ads.ex:550-561](../../../../lib/ad_butler/ads.ex#L550))
  - Approach: build `{ad_id → new_history}` map in memory after the existing `load_existing_history/1` bulk read; replace the per-ad `Repo.update_all` loop with one `Repo.insert_all(Ad, entries, on_conflict: {:replace, [:quality_ranking_history]}, conflict_target: [:id])`.
- [ ] **B2** Non-atomic finding/score write breaks retry idempotency ([lib/ad_butler/workers/creative_fatigue_predictor_worker.ex:211-250](../../../../lib/ad_butler/workers/creative_fatigue_predictor_worker.ex#L211))
  - Approach: emit a fatigue-score `entry` for every audited ad, including those where dedup made `maybe_emit_finding` return `:skipped`. The upsert is idempotent; this guarantees scores survive any later step's failure.
- [ ] **B3** [Iron Law: pattern-match in heads] — `length/1` guard on list ([creative_fatigue_predictor_worker.ex:134](../../../../lib/ad_butler/workers/creative_fatigue_predictor_worker.ex#L134))
  - Approach: split into `defp detect_quality_drop([])`, `defp detect_quality_drop([_])`, generic clause.

### Warnings

- [ ] **W4** [Iron Law #8] `with true <- prior_cpm > 0` silent swallow ([analytics.ex:348-354](../../../../lib/ad_butler/analytics.ex#L348))
  - Approach: drop the boolean guard; `avg_cpm/1` already returns `:insufficient` for zero spend. (No code change to `avg_cpm/1` needed — already correct; just remove the redundant guard line.)
- [ ] **W5** Discarded `maybe_emit_finding/5` return value ([creative_fatigue_predictor_worker.ex:227](../../../../lib/ad_butler/workers/creative_fatigue_predictor_worker.ex#L227))
  - Approach: switch to `Enum.reduce_while` mirroring BudgetLeakAuditor; halt on `{:error, reason}` and propagate so Oban retries.
- [ ] **W6** Kill-switch compile-time vs runtime ([audit_scheduler_worker.ex:33](../../../../lib/ad_butler/workers/audit_scheduler_worker.ex#L33))
  - Approach: move to `config/runtime.exs` reading `System.get_env("FATIGUE_ENABLED", "true") == "true"`, default `true`. Update `.env.example`.
- [ ] **W7** Stale `@moduledoc` on AdHealthScore ([ad_health_score.ex:3](../../../../lib/ad_butler/analytics/ad_health_score.ex#L3))
  - Approach: rewrite intro paragraph to mention both writers (`BudgetLeakAuditorWorker` + `CreativeFatiguePredictorWorker`).
- [ ] **W8** `insert_daily/3` duplicated across two test files ([analytics_test.exs:11](../../../../test/ad_butler/analytics_test.exs#L11), [creative_fatigue_predictor_worker_test.exs:74](../../../../test/ad_butler/workers/creative_fatigue_predictor_worker_test.exs#L74))
  - Approach: extract canonical helper into `test/support/insights_helpers.ex`, accept all relevant attrs, both test files import it.
- [ ] **W9** Tenant isolation by absence ([creative_fatigue_predictor_worker_test.exs:463-498](../../../../test/ad_butler/workers/creative_fatigue_predictor_worker_test.exs#L463))
  - Approach: rewrite the test so account A has ads with NO triggering signals (clean) and account B has ads that WOULD fire all 3 heuristics; perform job for A; assert no findings or scores under account B's ads.

### Suggestions

- [ ] **S10** Unused `_emit_count` accumulator ([creative_fatigue_predictor_worker.ex:217](../../../../lib/ad_butler/workers/creative_fatigue_predictor_worker.ex#L217))
  - Approach: replace `Enum.reduce` with `Enum.flat_map` returning entries directly.
- [ ] **S11** `_window_days` parameter unused ([analytics.ex:320](../../../../lib/ad_butler/analytics.ex#L320))
  - Approach: drop the parameter (1-arity function); update worker call site.
- [ ] **S12** `inspect(v)` fallback in `format_fatigue_values` ([finding_detail_live.ex:233](../../../../lib/ad_butler_web/live/finding_detail_live.ex#L233))
  - Approach: replace fallback with `defp format_fatigue_values(_kind, _values), do: ""` plus `Logger.warning("format_fatigue_values: unrecognised kind", kind: kind)`.
- [ ] **S13** `six_hour_bucket/0` duplicated across two workers
  - Approach: extract to `lib/ad_butler/workers/audit_helpers.ex` with `@doc false` and call from both workers.
- [ ] **S14** Stale POOL_SIZE comment ([config/config.exs:138](../../../../config/config.exs#L138), [.env.example](../../../../.env.example))
  - Approach: update both. Total = 10+20+5+5+5+5 = 50; recommend `>= 60`.

---

## Skipped

(none)

## Deferred

(none)

---

## Next steps

- `/phx:plan .claude/plans/v0.3-creative-fatigue-chat-mvp/reviews/week7-triage.md` — generate phase-grouped fix plan (recommended for 14 items).
- `/phx:work` directly — for ad-hoc execution since approaches are pre-decided per item.
- `/phx:compound` — capture the dedup retry-safety pattern + the JSONB-append upsert pattern after fixes land.
