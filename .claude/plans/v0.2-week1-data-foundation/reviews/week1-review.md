# Week 1 Data Foundation — Code Review
**Date**: 2026-04-27
**Branch**: week-01-Day-01-05-Data-Foundation-and-Ingestion
**Verdict**: REQUIRES CHANGES

5 agents ran: iron-law-judge, security-analyzer, elixir-reviewer, testing-reviewer, oban-specialist.
Write tool denied for 4 agents — findings extracted from return messages.

---

## BLOCKERS (must fix before merge)

### [B1] SQL identifier interpolation — `relname` regex not anchored at start
**Files**: `lib/ad_butler/workers/partition_manager_worker.ex:94, 123`

`parse_week_start/1` uses `~r/insights_daily_(\d{4})_[Ww](\d{2})$/` — anchored at end (`$`) only. A name like `evil"; DROP TABLE x; --insights_daily_2026_W01` would match and be interpolated directly into `ALTER TABLE insights_daily DETACH PARTITION "#{relname}"`.

Not exploitable today (requires write access to `pg_class`), but unacceptable as defence-in-depth.

**Fix**: Change regex to `~r/\Ainsights_daily_(\d{4})_[Ww](\d{2})\z/` and add an identifier whitelist guard before each DDL site:
```elixir
unless Regex.match?(~r/\A[a-z0-9_]+\z/, relname), do: raise "unsafe partition name: #{inspect(relname)}"
```

Flagged by: iron-law-judge, security-analyzer, elixir-reviewer (3 of 5 agents).

---

### [B2] Scheduler workers silently succeed when RabbitMQ publish fails
**Files**: `lib/ad_butler/workers/insights_scheduler_worker.ex`, `lib/ad_butler/workers/insights_conversion_worker.ex`

`perform/1` calls `Enum.each(ad_accounts, fn aa -> publish(aa) end)`. If `publish/1` returns `{:error, _}`, `Enum.each` discards it — Oban marks the job `:success` and never retries. Silent data loss.

**Fix**: Replace `Enum.each` with error-aware accumulation:
```elixir
results = Enum.map(ad_accounts, &publish/1)
case Enum.find(results, &match?({:error, _}, &1)) do
  nil -> :ok
  {:error, reason} -> {:error, reason}
end
```

Flagged by: oban-specialist, elixir-reviewer.

---

### [B3] `bulk_upsert_insights/1` rescues own Repo code (violates CLAUDE.md)
**File**: `lib/ad_butler/ads.ex` (bulk_upsert_insights/1)

CLAUDE.md: "`rescue` is for wrapping third-party code that raises — never rescue your own code." The current `rescue Ecto.StaleEntryError` (or similar) around `Repo.insert_all` violates this. Internal Ecto errors should propagate — Oban will retry.

**Fix**: Remove the rescue block. Let `Repo.insert_all` exceptions bubble up to Oban's error handler.

Flagged by: elixir-reviewer, iron-law-judge.

---

## WARNINGS (should fix before merge)

### [W1] Missing `unique:` constraint on scheduler workers
**Files**: `lib/ad_butler/workers/insights_scheduler_worker.ex:9`, `lib/ad_butler/workers/insights_conversion_worker.ex:9`

Double-enqueue on node restart during cron window → duplicate Meta API calls for every account.

**Fix**:
```elixir
# InsightsSchedulerWorker
use Oban.Worker, queue: :default, max_attempts: 3, unique: [period: 1800]

# InsightsConversionWorker
use Oban.Worker, queue: :default, max_attempts: 3, unique: [period: 7200]
```

Flagged by: iron-law-judge, oban-specialist.

---

### [W2] Logger.error uses string interpolation in application.ex
**File**: `lib/ad_butler/application.ex:138-141`

```elixir
Logger.error("Oban job raised exception kind=#{kind} reason=#{exception_module} ...")
```

Violates CLAUDE.md structured-logging rule. Also: `Exception.format_stacktrace/1` can raise on malformed stacktrace, propagating to Oban's job runner.

**Fix**:
```elixir
Logger.error("Oban job raised exception",
  kind: kind,
  reason: inspect(reason),
  worker: job.worker,
  id: job.id
)
```

Flagged by: iron-law-judge.

---

### [W3] `sync_type` not validated in InsightsPipeline
**File**: `lib/ad_butler/sync/insights_pipeline.ex:48-58`

`handle_message/3` validates the UUID but not `sync_type`. Any unknown string causes `FunctionClauseError` in `insights_opts/1` — Broadway catches it and routes to DLQ silently.

**Fix**: Add allow-list check to the `with`:
```elixir
true <- sync_type in ["delivery", "conversions"]
```
With else clause: `false -> Message.failed(message, :invalid_sync_type)`.

Flagged by: security-analyzer.

---

### [W4] Missing `timeout/1` on long-running DDL workers
**Files**: `lib/ad_butler/workers/partition_manager_worker.ex`, `lib/ad_butler/workers/mat_view_refresh_worker.ex`

DDL operations (partition creation, REFRESH MATERIALIZED VIEW) can run long under load. Without `timeout/1`, Oban uses a default that may not match actual runtime.

**Fix**: Add `@impl Oban.Worker; def timeout(_job), do: :timer.minutes(5)` to both workers.

Flagged by: oban-specialist.

---

### [W5] MatViewRefreshWorker missing fallback clause
**File**: `lib/ad_butler/workers/mat_view_refresh_worker.ex`

`perform/1` pattern-matches `%{"view" => "7d"}` and `%{"view" => "30d"}` only. Unknown view key raises `FunctionClauseError` — not a clean Oban error.

**Fix**: Add `def perform(%{"view" => view}), do: {:error, "unknown view: #{view}"}`.

Flagged by: oban-specialist.

---

## SUGGESTIONS (optional improvements)

### [S1] MatViewRefreshWorker view name interpolation — add guard
**File**: `lib/ad_butler/workers/mat_view_refresh_worker.ex:28`

`Repo.query!("REFRESH MATERIALIZED VIEW CONCURRENTLY #{view_name}")` — safe today via hard-coded pattern match. Add defensive guard: `when view_name in ["ad_insights_7d", "ad_insights_30d"]`.

Flagged by: security-analyzer.

### [S2] `list_ad_accounts_internal/0` is a public `def`
**File**: `lib/ad_butler/ads.ex`

Correctly named but accessible to any module importing `AdButler.Ads`. Already tracked in week-3 plan for extraction to `AdButler.Ads.Sync`.

Flagged by: security-analyzer.

### [S3] `get_ad_meta_id_map/1` has no defence-in-depth tenant check
**File**: `lib/ad_butler/ads.ex`

Queries `Ad` by `ad_account_id` with no `meta_connection_id` join. Safe today because Meta API scopes by `ad_account.meta_id`. Consider adding `meta_connection_id` as second arg for defence-in-depth.

Flagged by: security-analyzer.

---

## Confirmed Clean

- Tenant scoping: consistent `scope/2` and `scope_ad_account/2` on all user-facing queries
- Access token encryption: `redact: true`, `@derive Inspect except`, `filter_parameters`
- `ErrorHelpers.safe_reason/1`: strips embedded secrets from logged error structs
- `partition_by_ad_account/1`: serialises same-account Broadway messages correctly
- `unsafe_*` naming convention: correct, internal-only, grep-verified no controller/LV callers
- Monetary fields: all BIGINT/NUMERIC — no `:float` violations
- HTTP client: Req used throughout
- No `String.to_atom/1` on user input in changed files
- No PII in RabbitMQ payloads

---

## Fix Effort Estimate

| Finding | Effort |
|---------|--------|
| B1 — regex anchor + guard | ~15 min |
| B2 — scheduler error propagation | ~10 min |
| B3 — remove rescue in bulk_upsert | ~5 min |
| W1 — unique: constraints | ~5 min |
| W2 — structured Logger.error | ~5 min |
| W3 — sync_type allow-list | ~5 min |
| W4 — timeout/1 on DDL workers | ~5 min |
| W5 — fallback clause MatViewRefresh | ~5 min |

Total: ~55 min
