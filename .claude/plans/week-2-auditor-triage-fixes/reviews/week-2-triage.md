# Triage: week-2-auditor-triage-fixes

**Date**: 2026-04-28  
**Source review**: `.claude/plans/week-2-auditor-triage-fixes/reviews/week-2-triage-review.md`  
**Result**: 13 to fix, 0 skipped, 0 deferred

---

## Fix Queue

### Blockers

- [ ] **B1** [Iron Law #6 AUTO] `acknowledge_finding/2` calls `get_finding!` — raises instead of returning error tuple  
  `lib/ad_butler/analytics.ex:83` — Replace with `get_finding/2` + `with`. Update `@spec` to include `{:error, :not_found}`.

- [ ] **B2** `handle_event("acknowledge")` KeyError on nil finding  
  `lib/ad_butler_web/live/finding_detail_live.ex:54` — Add nil-guard function head for `finding: nil` case.

### Warnings

- [ ] **W1** `Analytics.get_finding/2` has zero tests  
  `test/ad_butler/analytics_test.exs` — Add 3 cases: (1) ok for owner, (2) `:not_found` cross-tenant, (3) `:not_found` nonexistent UUID.

- [ ] **W2** `six_hour_bucket/0` midnight race  
  `lib/ad_butler/workers/budget_leak_auditor_worker.ex` — Replace `Date.utc_today()` with `DateTime.to_date(now)`.

- [ ] **W3** `Oban.insert_all/1` return value silently ignored  
  `lib/ad_butler/workers/audit_scheduler_worker.ex:30` — Capture result, log error tuples.

- [ ] **W4** Float arithmetic for CPA/placement ratios in evidence JSONB  
  `lib/ad_butler/workers/budget_leak_auditor_worker.ex` — Use integer division for ratio comparisons, or Decimal for persisted values.

- [ ] **W5** URL filter params bypass allowlist on direct navigation  
  `lib/ad_butler_web/live/findings_live.ex:42-52` — Apply same allowlist + `Ecto.UUID.cast/1` validation in `handle_params/3` that `filter_changed` uses.

- [ ] **W6** `with false <- is_nil(...)` anti-pattern  
  `lib/ad_butler/sync/insights_pipeline.ex` — Replace with `normalised when not is_nil(normalised.date_start) <- normalise_row(row, local_id)`.

### Suggestions

- [ ] **S1** Health score idempotency not tested  
  `test/ad_butler/workers/budget_leak_auditor_worker_test.exs` — Add test: perform_job twice within same bucket → count == 1.

- [ ] **S2** `AuditSchedulerWorker` `unique:` missing explicit `keys: []`  
  `lib/ad_butler/workers/audit_scheduler_worker.ex:9` — Add `keys: []` explicitly for clarity.

- [ ] **S3** `unsafe_get_latest_health_score/1` — no scope enforcement  
  `lib/ad_butler/analytics.ex:141` — Strengthen `@doc` to explicitly warn callers must call `get_finding/2` first and reference the invariant.

- [ ] **S4** TOCTOU in finding deduplication — add note  
  `lib/ad_butler/analytics.ex` / `lib/ad_butler/workers/budget_leak_auditor_worker.ex` — Add comment in `maybe_emit_finding/3` noting the partial unique index (migration 20260427000002) is the DB-level guard against concurrent duplicate inserts.

- [ ] **S5** `async: false` undocumented in worker tests  
  `test/ad_butler/workers/*_test.exs` — Add one-line comment explaining why `async: false` (materialized view `REFRESH` cannot run `CONCURRENTLY` in sandbox).

---

## Skipped

None.

## Deferred

None.
