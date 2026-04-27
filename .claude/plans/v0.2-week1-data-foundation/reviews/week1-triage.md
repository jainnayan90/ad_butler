# Week 1 Triage
**Date**: 2026-04-27

## Fix Queue

- [ ] B1 — Anchor regex `\A...\z` + identifier whitelist guard in PartitionManagerWorker
- [ ] B2 — Scheduler workers: propagate publish errors instead of Enum.each discard
- [ ] B3 — Remove rescue around Repo.insert_all in bulk_upsert_insights
- [ ] W1 — Add `unique:` constraints to InsightsSchedulerWorker + InsightsConversionWorker
- [ ] W2 — Fix Logger.error string interpolation in application.ex
- [ ] W3 — Add sync_type allow-list validation in InsightsPipeline.handle_message/3
- [ ] W4 — Add timeout/1 to PartitionManagerWorker + MatViewRefreshWorker
- [ ] W5 — Add fallback clause to MatViewRefreshWorker.perform/1

## Skipped

- S1 — MatViewRefreshWorker view name guard (safe today, tracked in week-3)
- S2 — list_ad_accounts_internal/0 public def (tracked in week-3 plan)
- S3 — get_ad_meta_id_map/1 tenant defence-in-depth (safe today)
