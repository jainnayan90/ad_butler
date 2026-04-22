# Performance Audit

**Score: 62/100**

| Category | Score | Notes |
|---|---|---|
| No N+1 patterns | 20/30 | 2 N+1 patterns |
| Indexes for common queries | 20/20 | clean |
| Preloads used appropriately | 15/15 | clean |
| No GenServer bottlenecks | 5/15 | Scheduler never re-schedules |
| LiveView streams | N/A | no LiveView lists |
| Queries avoid SELECT * | 2/10 | 4 list queries pull raw_jsonb |

## Issues

**[P1-CRITICAL] N+1 — metadata_pipeline.ex:64: get_meta_connection! per ad_account in batch**
10 ad accounts sharing one connection → 10 identical DB round trips. Fix: load connection once at top of process_batch_group/1 and pass into sync_ad_account/2.

**[P2-CRITICAL] N+1 — metadata_pipeline.ex:99,108: one upsert per campaign/ad_set**
upsert_campaigns/2 and upsert_ad_sets/2 loop with individual upserts. 100 campaigns = 100 sequential DB round trips. Fix: Repo.insert_all/3 with multi-row values + on_conflict + returning: [:id, :meta_id].

**[P3-WARNING] Scheduler GenServer fires once, never re-schedules (accounts.ex/scheduler.ex)**
Pre-existing W1. Replace with Oban cron worker.

**[P4-WARNING] list_all_active_meta_connections/0 unbounded (accounts.ex:84)**
Pre-existing W6. No LIMIT, no pagination. Loads full table at scale.

**[P5-WARNING] SELECT * on JSONB-heavy schemas (ads.ex:34,71,120,170)**
list_ad_accounts, list_campaigns, list_ad_sets, list_ads all pull raw_jsonb. Add select/2 projections for list views.

## Clean Areas

Indexes clean. FK indexes present. Composite unique indexes correct. Token sweep jitter + 500-row limit well-designed. Oban uniqueness on meta_connection_id prevents duplicate fan-out. All money as bigint cents. All user values pinned with ^.
