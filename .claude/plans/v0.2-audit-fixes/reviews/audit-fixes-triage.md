# Triage — Audit Fixes v0.2
**Date:** 2026-04-27
**Source:** `.claude/plans/v0.2-audit-fixes/reviews/audit-fixes-review.md`
**Result:** 18 to fix, 0 skipped, 0 deferred

---

## Fix Queue

### BLOCKERS (Iron Law auto-approved)

- [ ] B1 — `lib/ad_butler/workers/insights_scheduler_worker.ex:15,20` — Move `Repo.transaction` + stream logic into `Ads.run_delivery_scheduler/1` context function; remove `alias AdButler.Repo` from worker
- [ ] B2 — `lib/ad_butler_web/controllers/auth_controller.ex:50` — Change `Logger.warning("OAuth error from provider (truncated): #{safe_description}")` → `Logger.warning("oauth_provider_error", description: safe_description)`
- [ ] B3 — `lib/ad_butler/sync/insights_pipeline.ex:118` — Wrap `Ads.bulk_upsert_insights` in `case`; return `Message.failed(message, reason)` on `{:error, _}`
- [ ] B4 — `lib/ad_butler/workers/insights_scheduler_worker.ex:37` — Change `errors ++ chunk_errors` to prepend `[chunk_errors | errors]`; `List.flatten` once at the end
- [ ] B5 — `lib/ad_butler/analytics.ex:33-44` — Parameterize date values in `CREATE TABLE ... FOR VALUES FROM ($1) TO ($2)` using `Repo.query!/3`; or apply `safe_identifier!` consistently; also guard `do_refresh/1` view_name (W7 merged here)

### WARNINGS

- [ ] W1 — `lib/ad_butler/ads.ex:556` — Fix `@spec bulk_upsert_insights` to include `| {:error, term()}`
- [ ] W2 — `lib/ad_butler/ads.ex:593,620` — Remove redundant `import Ecto.Query` inside `get_7d_insights/1` and `get_30d_baseline/1`
- [ ] W3 — `lib/ad_butler/workers/insights_conversion_worker.ex:18` — Switch from `list_ad_accounts_internal()` to `Repo.transaction` + `stream_active_ad_accounts/0` (same pattern as InsightsSchedulerWorker)
- [ ] W4 — `lib/ad_butler/workers/insights_scheduler_worker.ex:20` — Collect account IDs inside transaction, publish to RabbitMQ outside
- [ ] W5 — `lib/ad_butler/meta/client.ex:229,232` — Replace `acc ++ data` with `[data | acc]` + reverse once at base case
- [ ] W6 — `priv/repo/migrations/20260426100002_create_insights_initial_partitions.exs:32-34` — Add `DROP TABLE IF EXISTS` for all 4 initial partitions in `down/0`
- [ ] W7 — `lib/ad_butler/analytics.ex:87` — Apply `safe_identifier!/1` to `view_name` in `do_refresh/1` (merged into B5 fix)
- [ ] W8 — `lib/ad_butler/ads.ex:591-640` — Add `unsafe_` prefix to `get_7d_insights/1` and `get_30d_baseline/1` (or scope them); document caller ownership requirement
- [ ] W9 — `config/runtime.exs:35-39` — Add `if cloak_key == <<0::256>>, do: raise "..."` check in `:prod` block
- [ ] W10 — `lib/ad_butler/sync/insights_pipeline.ex:88` — Call `meta_client()` once at top of `handle_batch/4`, thread value through `process_batch_group/3` and `sync_insights_message/3`
- [ ] W11 — `test/ad_butler/ads/ads_insights_test.exs` — Add two-user cross-tenant assertions for `get_7d_insights/1` and `get_30d_baseline/1`
- [ ] W12 — `test/ad_butler/workers/insights_conversion_worker_test.exs` — Add: (a) inactive accounts excluded test; (b) publish-failure returns `{:error, reason}` test
- [ ] W13 — `test/ad_butler/workers/partition_manager_worker_test.exs:22-38` — Fix `create_old_partition/0` to use `iso_year` from `:calendar.iso_week_number/1` rather than `old_date.year`

---

## Skipped
(none)

## Deferred
(none)
