# Audit Fixes Review — v0.2

**Verdict: REQUIRES CHANGES**
**Date:** 2026-04-27
**Branch:** week-01-Day-01-05-Data-Foundation-and-Ingestion

---

## Summary

| Severity | Count |
|----------|-------|
| BLOCKER  | 5     |
| WARNING  | 13    |
| SUGGESTION | 9   |

The audit-fix goals (ARCH-1 through ARCH-4, SEC-1/2/3, PERF-1–3, DEPS-2) were largely achieved. The Iron Law review confirmed the main violations are fixed. However, the new insights pipeline and scheduler introduced fresh violations that block merge.

---

## BLOCKERS

### B1 — Iron Law: `InsightsSchedulerWorker` calls `Repo` directly
**File:** `lib/ad_butler/workers/insights_scheduler_worker.ex:15,20`
The worker aliases `AdButler.Repo` and calls `Repo.transaction(...)`. Workers must never call `Repo` — this is the exact violation ARCH-1 was meant to fix. It was fixed for `MatViewRefreshWorker` and `PartitionManagerWorker` but missed for `InsightsSchedulerWorker`. Move the `Repo.transaction` + stream logic into a context function (e.g. `Ads.run_delivery_scheduler/1`).

### B2 — Structured logging violation in `auth_controller.ex`
**File:** `lib/ad_butler_web/controllers/auth_controller.ex:50`
`Logger.warning("OAuth error from provider (truncated): #{safe_description}")` uses string interpolation. This is in the same file as the SEC-2 fix but a different callback. Fix: `Logger.warning("oauth_provider_error", description: safe_description)`.

### B3 — Broadway crash on upsert failure in `insights_pipeline.ex`
**File:** `lib/ad_butler/sync/insights_pipeline.ex:118`
`{:ok, count} = Ads.bulk_upsert_insights(normalised)` is a bare match. If the upsert raises (partition missing, DB error), Broadway crashes the processor without calling `Message.failed/2`. Use `case` and return a failed message on `{:error, _}`.

### B4 — O(n²) error accumulation in `insights_scheduler_worker.ex`
**File:** `lib/ad_butler/workers/insights_scheduler_worker.ex:37`
`errors ++ chunk_errors` inside `Enum.reduce` over potentially thousands of accounts is O(n²). Accumulate with `[chunk_errors | errors]` and flatten once at end.

### B5 — Analytics SQL date interpolation without parameterization
**File:** `lib/ad_butler/analytics.ex:33-44`
`Date.to_iso8601(ws)` and `Date.to_iso8601(we)` are interpolated into `CREATE TABLE ... FOR VALUES FROM ('#{...}') TO ('#{...}')`. Use `Repo.query!/3` with positional params (`$1`, `$2`), or apply `safe_identifier!/1` to the date strings and quote them consistently.

---

## WARNINGS

### W1 — `@spec` for `bulk_upsert_insights` doesn't include `{:error, term()}`
**File:** `lib/ad_butler/ads.ex:556`
Spec says `{:ok, non_neg_integer()}` but the `@doc` describes `{:error, term()}` as a possible return. Fix the spec.

### W2 — Redundant `import Ecto.Query` inside function bodies
**File:** `lib/ad_butler/ads.ex:593,620`
`import Ecto.Query` inside `get_7d_insights/1` and `get_30d_baseline/1` — the module already imports at line 9. Remove.

### W3 — `InsightsConversionWorker` not on streaming path
**File:** `lib/ad_butler/workers/insights_conversion_worker.ex:18`
Uses `Ads.list_ad_accounts_internal()` (loads all into memory). PERF-2 added `stream_active_ad_accounts/0` and updated the scheduler worker; the conversion worker was missed.

### W4 — Side-effects (publish) inside `Repo.transaction`
**File:** `lib/ad_butler/workers/insights_scheduler_worker.ex:20`
RabbitMQ publishes happen inside the DB transaction. A rollback cannot un-publish messages. Collect IDs inside the transaction, publish outside.

### W5 — O(n²) list accumulation in `meta/client.ex`
**File:** `lib/ad_butler/meta/client.ex:229,232`
`acc ++ data` in recursive `fetch_all_pages/6`. Use `[data | acc]` + final reverse.

### W6 — Migration `down` doesn't drop partitions
**File:** `priv/repo/migrations/20260426100002_create_insights_initial_partitions.exs:32-34`
`down` drops the PL/pgSQL function but not the four partitions it created. Rollback leaves orphan partitions blocking re-run.

### W7 — `do_refresh/1` and `create_future_partitions/0` SQL without `safe_identifier!`
**File:** `lib/ad_butler/analytics.ex:33-44,87`
`do_refresh/1` interpolates `view_name` without guarding; `create_future_partitions/0` doesn't apply `safe_identifier!` to partition names. Apply consistently or use positional params.

### W8 — `get_7d_insights/1` and `get_30d_baseline/1` have no tenant scope
**File:** `lib/ad_butler/ads.ex:591-640`
Queries by `ad_id` without any user/tenant scope. Either accept a `user` param + join through `AdAccount`, or add `unsafe_` prefix and document caller ownership requirement.

### W9 — Cloak prod key doesn't check for all-zeros placeholder
**File:** `config/runtime.exs:35-39`
The `:prod` block checks 32-byte length but not for `<<0::256>>`. Add the same check the `:dev` block has.

### W10 — `meta_client()` called per-message in `handle_batch/4`
**File:** `lib/ad_butler/sync/insights_pipeline.ex:88`
`Application.get_env` called up to 25× per batch. Call once at the top and thread through.

### W11 — Missing tenant isolation tests for `get_7d_insights/1` and `get_30d_baseline/1`
**File:** `test/ad_butler/ads/ads_insights_test.exs`
Both functions accept an unscoped `ad_id`. CLAUDE.md requires two-user cross-tenant assertions for every scoped query.

### W12 — `InsightsConversionWorkerTest` missing inactive-account and publish-failure tests
**File:** `test/ad_butler/workers/insights_conversion_worker_test.exs`
No test for inactive ad accounts being excluded. No test for publish-failure returning `{:error, reason}`.

### W13 — ISO week year boundary issue in partition test
**File:** `test/ad_butler/workers/partition_manager_worker_test.exs:22-38`
`create_old_partition/0` derives partition name from `old_date.year`, but `:calendar.iso_week_number/1` returns `{iso_year, week}` which can differ from the calendar year near year boundaries. Silently wrong test.

---

## CLEAN (verified by Iron Law judge)

- ARCH-1: `MatViewRefreshWorker` + `PartitionManagerWorker` — no `Repo` in workers ✅
- ARCH-2: `HealthController` uses `Health.db_ping/0` ✅
- ARCH-4: `UsageHandler` delegates to `LLM.insert_usage/1` ✅
- Configurable fn pattern (`Application.get_env`) applied correctly ✅
- Tenant scoping: all user-facing Ads queries through `scope/2` ✅
- LiveView streams: all 5 LiveViews use `stream/3` ✅
- No `String.to_atom` in `lib/` ✅
- Broadway context boundary: InsightsPipeline calls only `Ads.*` + `Accounts.*` ✅
