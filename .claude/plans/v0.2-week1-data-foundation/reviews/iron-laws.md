# Iron Law Violations Report
⚠️ EXTRACTED FROM AGENT MESSAGE (Write tool denied — see scratchpad)

## Summary
- Files scanned: 11 (8 .ex + 3 .exs migration files)
- Iron Laws checked: 16 of 23 (LiveView laws N/A)
- Violations found: 4 (1 critical, 2 high, 1 medium)

---

## BLOCKER

### [Iron Law #5] Raw SQL interpolation in PartitionManagerWorker
- **File**: `lib/ad_butler/workers/partition_manager_worker.ex:34-38, :94`
- **Code**: `CREATE TABLE IF NOT EXISTS "#{partition_name}"` and `DETACH PARTITION "#{relname}"`
- **Risk**: `relname` comes from `pg_inherits` catalog, not user input. But if a malformed name ever entered the catalog, arbitrary DDL could execute. Postgres DDL doesn't support bind params.
- **Fix**: Validate `relname` strictly against the known regex (`parse_week_start/1` already exists) before interpolating. Add guard or assertion before use.

---

## WARNING

### [Iron Law #7] Scheduler workers missing `unique:` constraint
- **Files**: `lib/ad_butler/workers/insights_scheduler_worker.ex:9`, `lib/ad_butler/workers/insights_conversion_worker.ex:9`
- **Risk**: Double-enqueue on node restart during cron window publishes duplicate messages → redundant Meta API calls for every account.
- **Fix**: Add `unique: [period: 1800]` to InsightsSchedulerWorker, `unique: [period: 7200]` to InsightsConversionWorker.

### [Iron Law #16] Non-structured Logger with interpolation in telemetry handler
- **File**: `lib/ad_butler/application.ex:138-141`
- **Code**: `Logger.error("Oban job raised exception kind=#{kind} reason=#{exception_module} worker=#{job.worker} id=#{job.id}\n#{Exception.format_stacktrace(stacktrace)}")`
- **Risk**: `Exception.format_stacktrace/1` can raise on malformed stacktrace, propagating to Oban's job runner. Also violates CLAUDE.md structured-logging rule.
- **Fix**: `Logger.error("Oban job raised exception", kind: kind, reason: inspect(reason), worker: job.worker, id: job.id)`

---

## SUGGESTION

### [CLAUDE.md Logging] Same as WARNING above — string interpolation is the only Logger outlier in the entire changeset. Resolved by fixing the WARNING above.

---

## Confirmed Clean
- `list_ad_accounts_internal/0` and `unsafe_get_ad_account_for_sync/1` — UNSAFE-named, internal-only, acceptable
- `get_ad_meta_id_map/1` — scoped to single ad_account_id, not a tenant leak
- `ClientBehaviour` + `Client` + `Application.get_env` injection — correct pattern
- All monetary fields use BIGINT/NUMERIC — no :float violations
- `bulk_upsert_insights` — Repo boundary handled via context module
