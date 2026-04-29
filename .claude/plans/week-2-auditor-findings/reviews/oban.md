# Oban Review — week-2-auditor-findings
⚠️ EXTRACTED FROM AGENT MESSAGE (agent had no Write permission)

## Summary: 2 BLOCKERs, 5 WARNINGs, 3 SUGGESTIONs. Iron Laws: PASS.

---

## BLOCKERs

### Scheduler uses N individual `Oban.insert/1` calls
**File**: `lib/ad_butler/workers/audit_scheduler_worker.ex:23-27`
With 1,000 ad accounts, 1,000 sequential DB round-trips. The project already uses `Oban.insert_all/1` in `token_refresh_sweep_worker.ex` and `sync_all_connections_worker.ex` for this exact pattern.

Fix:
```elixir
ad_accounts
|> Enum.map(fn aa ->
  BudgetLeakAuditorWorker.new(
    %{"ad_account_id" => aa.id},
    unique: [period: 21_600, keys: [:ad_account_id]]
  )
end)
|> Oban.insert_all()
```

### `upsert_ad_health_score` return value silently dropped
**File**: `budget_leak_auditor_worker.ex:66-71`
`Enum.each` discards `{:ok, _} | {:error, _}`. DB failure → no health score, worker still returns `:ok`, Oban never retries.

---

## WARNINGs

### Cron collision with TokenRefreshSweepWorker
**File**: `config/config.exs:138,145`
Both fire at `"0 */6 * * *"` (00:00, 06:00, 12:00, 18:00 UTC). DB load spike. Consider `"3 */6 * * *"` to stagger like `SyncAllConnectionsWorker` at `"5 */6 * * *"`.

### No `timeout/1` on BudgetLeakAuditorWorker
**File**: `budget_leak_auditor_worker.ex:11`
For large accounts, `load_48h_insights` may take minutes. Only the Lifeline 30-min rescue guards against runaway jobs. Add:
```elixir
@impl Oban.Worker
def timeout(_job), do: :timer.minutes(10)
```

### AuditSchedulerWorker missing `unique:` on itself
**File**: `audit_scheduler_worker.ex:9`
If cron fires while previous run still executes (slow at 1,000 inserts), two schedulers issue redundant queries. Add `unique: [period: 21_600]` to `use Oban.Worker`.

### `upsert_ad_health_score` name vs behaviour mismatch
**File**: `analytics.ex:117-122`
Named "upsert" but is plain `Repo.insert/1`. Rename to `insert_ad_health_score` or `record_ad_health_score`.

### Pool size comment stale
**File**: `config.exs:129`
Comment says "POOL_SIZE >= 25 for sync: 20". Total concurrency is now 10+20+5+5=40. Update to `POOL_SIZE >= 50`.

---

## SUGGESTIONs

### `check_cpa_explosion` swallows DB errors silently
`with` `else _ -> :skip` absorbs transient DB errors with no log. Add a specific `{:error, reason}` clause that logs a warning.

### ~~Race on findings dedup~~ — FALSE POSITIVE
Agent suggested a partial unique index to prevent race. This index already exists in `priv/repo/migrations/20260427000002_create_findings.exs` (`UNIQUE INDEX CONCURRENTLY ... WHERE resolved_at IS NULL`).

### `@doc false` on `defp` is a no-op
`budget_leak_auditor_worker.ex:375`. Remove it.

---

## Idempotency: PASS
- Findings: safe — `maybe_emit_finding` guards with `get_unresolved_finding`.
- Health scores: safe — append-only time-series.
- Scheduler fan-out: safe — child job uniqueness prevents double-queuing.
