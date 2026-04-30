# Week 7 Review-Fixes — Pass 2 Triage Decisions

**Source review:** [week7-fixes-pass2-review.md](week7-fixes-pass2-review.md)
**Decision:** B-1 + W-2 + W-3 approved. S-6 deferred.

## Fix Queue (3)

### Blocker

- [x] **B-1** [test-correctness] Restore the original CTR formula `clicks = 80 - (6 - d) * 10` in the tenant-isolation test for account B. The previous "readability" rewrite reversed the slope direction; the test now passes for the wrong reason (heuristic doesn't fire at all instead of firing-and-being-scope-filtered).
  - **File:** [test/ad_butler/workers/creative_fatigue_predictor_worker_test.exs:480-481](../../../test/ad_butler/workers/creative_fatigue_predictor_worker_test.exs#L480)
  - **Approach:** revert the formula to `clicks = 80 - (6 - d) * 10`. Keep the explanatory comment (it was correct — only the formula contradicted it). Run `mix test test/ad_butler/workers/creative_fatigue_predictor_worker_test.exs` to confirm the test still passes (it should — both formulas yield zero account-B scores; the difference is whether the heuristic fired in the first place, which is the whole point of the regression guard).

### Warnings

- [x] **W-2** [DRY] Move `dedup_constraint_error?/1` from both workers to `AdButler.Workers.AuditHelpers`.
  - **Files:**
    - Add public `dedup_constraint_error?/1` to [lib/ad_butler/workers/audit_helpers.ex](../../../lib/ad_butler/workers/audit_helpers.ex)
    - Drop local copy + call via `AuditHelpers.dedup_constraint_error?(...)` in [budget_leak_auditor_worker.ex:402](../../../lib/ad_butler/workers/budget_leak_auditor_worker.ex#L402)
    - Same change in [creative_fatigue_predictor_worker.ex:371](../../../lib/ad_butler/workers/creative_fatigue_predictor_worker.ex#L371)
  - **Approach:** `@spec dedup_constraint_error?(Ecto.Changeset.t()) :: boolean()`, `@doc` describing the partial-unique-index dedup classification. Both workers already `alias AdButler.Workers.AuditHelpers`.

- [x] **W-3** [test-correctness] Tighten the S-3 DB-state assertion to drop the unreachable `nil` branch.
  - **File:** [test/ad_butler/ads_test.exs:472](../../../test/ad_butler/ads_test.exs#L472)
  - **Approach:** change `assert reloaded.quality_ranking_history in [nil, %{"snapshots" => []}]` → `assert reloaded.quality_ranking_history == %{"snapshots" => []}`. The migration's `default: %{"snapshots" => []}` makes `nil` unreachable on a fresh row.

## Skipped

(none)

## Deferred

- **S-6** [arity-unification] `handle_create_result/N` differs between the two workers (3-ary vs 2-ary). Bundling with W-2 was an option but user opted to defer. Captured for a future cleanup pass.

---

## Next steps

- `/phx:work .claude/plans/week7-fixes/reviews/week7-fixes-pass2-triage.md` — execute the 3 fixes ad-hoc.
- `/phx:plan .claude/plans/week7-fixes/reviews/week7-fixes-pass2-triage.md` — overkill for 3 small items.
- `/phx:compound` — capture the "test passes for the wrong reason" failure mode + the "extract shared worker helpers to AuditHelpers" pattern after fixes land.
