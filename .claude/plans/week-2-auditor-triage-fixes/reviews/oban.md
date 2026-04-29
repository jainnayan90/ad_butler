# Oban Worker Review: week-2-auditor-triage-fixes

⚠️ EXTRACTED FROM AGENT MESSAGE (write was denied)

## Idempotency Assessment: SAFE to retry.

## Critical

- **`Oban.insert_all/1` return value silently discarded** (`audit_scheduler_worker.ex:30`) — errors from DB failures are dropped silently. Capture result and log error tuples.

- **`six_hour_bucket/0` midnight race condition** (`budget_leak_auditor_worker.ex`) — `DateTime.utc_now()` and `Date.utc_today()` are separate calls. At midnight, `now.hour` = 23 (bucket=18) but `Date.utc_today()` returns the next day → wrong timestamp. Fix: `DateTime.to_date(now)` instead of `Date.utc_today()`.

## Warnings

- **`halt-on-first-error` in `insert_health_scores/2` and `run_all_heuristics/5`** — one bad ad blocks the whole account audit. Consider log-and-continue.
- **`unique: [period: 21_600]` no `keys:` on AuditSchedulerWorker** — correct intent but omitting `keys: []` explicitly is a future footgun.
- **TOCTOU in finding deduplication** — `get_unresolved_finding/2` → `create_finding/1` has no DB-level unique constraint. Concurrent runs could double-insert. A partial unique index `ON (ad_id, kind) WHERE resolved_at IS NULL` would eliminate this. (NOTE: migration 20260427000002 already adds this index — verify it is in place.)
- **`:skipped` findings counted in `fired_kinds`** — health score reflects "heuristics that fired" not "new findings created". Worth documenting.

## Suggestions

- No `timeout/1` on `AuditSchedulerWorker`.
- `BudgetLeakAuditorWorker` `@moduledoc` could note why `unsafe_*` Ads functions are acceptable in background context.
