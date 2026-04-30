# Plan: Week 7 Review Fixes

**Source:** [.claude/plans/v0.3-creative-fatigue-chat-mvp/reviews/week7-triage.md](../v0.3-creative-fatigue-chat-mvp/reviews/week7-triage.md)
**Scope:** 14 findings (3 BLOCKER, 6 WARNING, 5 SUGGESTION) — all approved, all queued.

## Goal

Land all 14 fixes from the Week 7 review with no regressions. Approaches are pre-decided in the triage file; this plan groups them into phases by file affinity to minimize re-touches.

---

## Phases

### Phase 1 — Context layer (Ads + Analytics + Schema doc)

- [x] [P1-T1][ecto] **B1** Replaced N+1 loop with a single `UPDATE ads ... FROM unnest($1::uuid[], $2::text[]::jsonb[])` statement at [ads.ex:566-597](../../../lib/ad_butler/ads.ex#L566-L597) — different shape than the planned `insert_all on_conflict` (avoids encode-twice issue with already-encoded JSONB) but achieves the same single-round-trip goal. New tests in [ads_test.exs:363-471](../../../test/ad_butler/ads_test.exs#L363) cover happy path + 14-snapshot cap + nil-only filter.

- [x] [P1-T2][ecto] **W4** Boolean guard removed; [`Analytics.get_cpm_change_pct/1`](../../../lib/ad_butler/analytics.ex#L320) now relies on the upstream `:insufficient` return.

- [x] [P1-T3][ecto] **S11** `get_cpm_change_pct/1` is 1-arity; `_window_days` parameter dropped; single call site in `heuristic_cpm_saturation/1` updated.

- [x] [P1-T4] **W7** [`AdHealthScore`](../../../lib/ad_butler/analytics/ad_health_score.ex#L1-L18) `@moduledoc` rewritten — names both writers, the shared 6-hour bucket, and the column-isolated `on_conflict` replace strategy.

### Phase 2 — Worker correctness rebuild

The blocker fixes B2/B3 + warning W5 + suggestion S10 all touch the same `audit_account` reduce loop. Treat as one cohesive restructure.

- [x] [P2-T1][oban] **B3** Pattern-matched in heads at [creative_fatigue_predictor_worker.ex:135-138](../../../lib/ad_butler/workers/creative_fatigue_predictor_worker.ex#L135) — `defp detect_quality_drop([])` + `defp detect_quality_drop([_])` + generic clause.

- [x] [P2-T2][oban] **B2 + W5 + S10** Restructured into `build_entries/4` + `audit_one_ad/4` at [creative_fatigue_predictor_worker.ex:247-274](../../../lib/ad_butler/workers/creative_fatigue_predictor_worker.ex#L247) — `Enum.reduce_while` halts on `{:error, _}`, score entries always emitted on `:skipped` dedup, no emit-count accumulator. Mirrors BudgetLeakAuditor's halt-on-error pattern.

- [x] [P2-T3][oban] **S13** [`AuditHelpers`](../../../lib/ad_butler/workers/audit_helpers.ex) module created (`@moduledoc false`); both [budget_leak_auditor_worker.ex:23,84,383](../../../lib/ad_butler/workers/budget_leak_auditor_worker.ex#L23) and `creative_fatigue_predictor_worker.ex` now alias and delegate. Bonus: also moved `dedup_constraint_error?/1` since both workers had identical copies.

### Phase 3 — Configuration + LiveView + docs polish

- [x] [P3-T1] **W6** [config/runtime.exs:90](../../../config/runtime.exs#L90) reads `FATIGUE_ENABLED` (default `"true"`); [.env.example:59](../../../.env.example#L59) documents the toggle; [AuditSchedulerWorker](../../../lib/ad_butler/workers/audit_scheduler_worker.ex#L11-L15) `@moduledoc` explains the hot-toggle path including the test-side `Application.put_env/3` route.

- [x] [P3-T2][liveview] **S12** [finding_detail_live.ex:234-237](../../../lib/ad_butler_web/live/finding_detail_live.ex#L234) fallback uses `Logger.warning` with `:kind` metadata; `:kind` already in the allowlist at [config/config.exs:89](../../../config/config.exs#L89).

- [x] [P3-T3] **S14** Pool-size comment updated at [config/config.exs:156-158](../../../config/config.exs#L156) — totals (10+20+5+5+5+5=50) and "POOL_SIZE >= 60 in prod" recommendation are in place.

### Phase 4 — Test cleanup

- [x] [P4-T1] **W8** [test/support/insights_helpers.ex](../../../test/support/insights_helpers.ex) exists with canonical `insert_daily/3`; both [analytics_test.exs:5](../../../test/ad_butler/analytics_test.exs#L5) and [creative_fatigue_predictor_worker_test.exs:8](../../../test/ad_butler/workers/creative_fatigue_predictor_worker_test.exs#L8) import it; duplicate `defp insert_daily` clauses removed.

- [x] [P4-T2] **W9** Tenant-isolation test rewritten at [creative_fatigue_predictor_worker_test.exs:444-535](../../../test/ad_butler/workers/creative_fatigue_predictor_worker_test.exs#L444) — Account A has clean signals, Account B has all 3 firing signals, perform_job runs against A only, asserts zero scores + findings for Account B's ad (proves scope filter works, not absence-of-data).

- [x] [P4-T3] Existing worker integration tests still pass post-restructure — full suite green (399/399).

### Phase 5 — Verification gate

- [x] [P5-T1] Format + compile clean — `mix format --check-formatted` + `mix compile --warnings-as-errors` both no-output.
- [x] [P5-T2] `mix test` → **399 tests, 0 failures, 8 excluded** (up from 392 baseline; new tests for ads bulk write + tenant isolation rewrite included).
- [x] [P5-T3] `mix credo --strict` → **797 mods/funs, found no issues** — even the 2 pre-existing items the plan flagged as out-of-scope are now clean.
- [x] [P5-T4] `mix check.unsafe_callers` → no output (passes).

---

## Risks (and mitigations)

1. **B1 bulk write may conflict with existing on_conflict semantics on `ads`.**
   *Mitigation*: Use a different conflict_target (`[:id]`) and a different replace set (`[:quality_ranking_history, :updated_at]`) than the metadata sync's `bulk_upsert_ads` (which uses `[:ad_account_id, :meta_id]` target). They never compete because `quality_ranking_history` is separate from the `name/status/raw_jsonb` set.

2. **P2-T2 restructure could regress existing integration tests.**
   *Mitigation*: All 6 worker integration tests assert observable behavior (score Decimal value, finding severity, dedup count). Restructure preserves these. Run worker tests immediately after P2-T2.

3. **P3-T1 runtime config change breaks tests that toggle the kill-switch.**
   *Mitigation*: The existing test (`audit_scheduler_worker_test.exs:36-50`) uses `Application.put_env` in test, which still works at runtime — `config/runtime.exs` only sets the initial value. Test path unchanged.

---

## Self-Check

- **Have you been here before?** Yes — most fixes are restating existing patterns from `BudgetLeakAuditorWorker` (halt-on-error reduce, always-emit-score). The novel work is the bulk JSONB upsert in P1-T1.
- **What's the failure mode you're not pricing in?** P1-T1's `on_conflict: {:replace, [:quality_ranking_history, :updated_at]}, conflict_target: [:id]` will succeed on every row because `id` is always populated for upserted ads. But if a metadata sync deletes an ad between `bulk_upsert_ads` and `append_quality_ranking_snapshots`, the bulk insert silently inserts a stub row. *Mitigation*: keep current ordering — append always runs immediately after upsert in the same MetadataPipeline batch; no realistic window for deletion.
- **Where's the Iron Law violation risk?** P2-T2 must keep the worker calling only `Ads.*` and `Analytics.*` — no new `Repo.` calls. P4-T2 must keep `unsafe_*` markers if it adds query helpers.

---

## Acceptance Criteria

- [x] All 14 triage items checked off.
- [x] `mix test` passes — 399 / 399.
- [x] `mix credo --strict` — zero issues.
- [x] `mix check.unsafe_callers` passes.
- [x] N+1 eliminated — `bulk_write_quality_ranking_history/2` issues a single `UPDATE ... FROM unnest()` ([ads.ex:588-596](../../../lib/ad_butler/ads.ex#L588)).
- [ ] Retry safety verified manually — deferred (no `iex` smoke run done in this session; the structural change to `reduce_while` + always-emit-score is covered by unit tests but the kill-mid-run scenario is unverified).

---

## Out of Scope

- The 2 pre-existing credo issues (`accounts.ex` nesting, `insights_pipeline.ex` Logger metadata).
- Pool size enforcement at runtime — comment-only update; CI/deploy adjustments belong to a separate ops ticket.
- The `:fatigue_enabled` env var being type-checked (boolean parsing accepts only `"true"` literal) — sufficient for v0.3 MVP per CLAUDE.md "validate at boundaries, not internal."
