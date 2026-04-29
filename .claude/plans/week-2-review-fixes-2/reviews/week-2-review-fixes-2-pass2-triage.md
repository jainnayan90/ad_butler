# Triage: week-2-review-fixes-2 (Pass 2)

**Date**: 2026-04-29
**Source**: week-2-review-fixes-2-pass2-review.md
**Fix queue**: 2 items · **Skipped**: 5

---

## Fix Queue

- [x] [W1] Add `fields: [:args, :queue, :worker]` to `BudgetLeakAuditorWorker` unique config — makes `keys: [:ad_account_id]` relationship explicit and prevents silent breakage if fields are ever changed. `lib/ad_butler/workers/budget_leak_auditor_worker.ex:14`
- [x] [W2] Rename log key `count: skipped` → `count: not_inserted` in `AuditSchedulerWorker` — reflects DB-level `on_conflict: :nothing` semantics rather than Oban unique resolution. `lib/ad_butler/workers/audit_scheduler_worker.ex:35`

---

## Skipped

- W3: Dedup count always 0 in tests — informational only; Oban inline engine behavior, no fix possible
- S1: Bot-traffic boundary test — deferred
- S2: Bot-traffic non-risky placement test — deferred
- S3: Remove unused `insert_ad_account_for_user` in malformed UUID test — deferred
