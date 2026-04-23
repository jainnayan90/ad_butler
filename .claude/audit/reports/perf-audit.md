# Performance Audit — 2026-04-23

**Score: 68/100**

## Issues Found

### CRITICAL — CPU-bound O(n) validation loop blocks Broadway batcher process
`lib/ad_butler/ads.ex:328-344`

`bulk_validate/2` calls `changeset(struct(schema_mod), attrs)` once per row, synchronously inside the Broadway batch callback. For large syncs (1000 campaigns, 5000 ads) this fully occupies the 2-process batcher on CPU work, blocking all downstream processing until validation finishes.

### CRITICAL — Single GenServer serializes all RabbitMQ publishes — timeout risk under sync load
`lib/ad_butler/messaging/publisher.ex:27-29`

All callers block on `GenServer.call(__MODULE__, {:publish, payload})`. `FetchAdAccountsWorker` calls `publish/1` per ad account inside an `Enum.map`. With `sync` queue concurrency at 20, up to 20 Oban workers compete on a single process mailbox. Default 5 s `GenServer.call` timeout means workers crash before the mailbox drains under sustained load.

**Fix:** Pool of publisher processes, or `GenServer.cast` with AMQP-level flow control.

### HIGH — Double DB round-trip on every user-facing query — `scope/2` hidden cost
`lib/ad_butler/ads.ex:25-37`

Both `scope/2` and `scope_ad_account/2` unconditionally issue `SELECT id FROM meta_connections WHERE user_id = $1` before the actual query. All 8 public context functions cost 2 round-trips each. A multi-resource dashboard page incurs 4–16 round-trips.

### HIGH — Broadway throughput ceiling at ~20 concurrent syncs — settings too conservative
`lib/ad_butler/sync/metadata_pipeline.ex:29-34`

`batch_size: 10`, `batcher_concurrency: 2`, `prefetch_count: 10`. Effective ceiling = 20 concurrent sync operations. Each sync is ~3 sequential Meta API calls (~9 s total). For 1000 connections: ~150 s minimum wall time per sweep. Raising `batcher_concurrency` to 5–10 and `prefetch_count` to 50 gives 3–5× improvement with no code changes.

### HIGH — `list_all_active_meta_connections/1` silently truncates at 1000
`lib/ad_butler/accounts.ex:116-131`

When >1000 active connections exist, connections beyond position 1000 are permanently skipped every sweep. Cursor-based batching is needed.

### MEDIUM — No index on `campaigns.status` or `ad_sets.status`
Migrations `20260420155128`, `20260420155129` — Both tables lack an index on `status`. The `:status` filter option causes full scans on the ad_account_id range. A composite `(ad_account_id, status)` index covers both.

### MEDIUM — ETS table missing `write_concurrency` despite concurrent writes
`lib/ad_butler/meta/rate_limit_store.ex:23`

`read_concurrency: true` without `write_concurrency: true` causes a global table lock on writes, serializing all concurrent writers even on independent keys.

**Fix:** Add `write_concurrency: true` (or `:auto` on OTP 26+).

### MEDIUM — `SyncAllConnectionsWorker` passes 1000 job structs to `Oban.insert_all/1` in one call
A single 1000-row INSERT causes latency spikes and leaves no partial success on failure. Chunk to 100–200 rows per call.

### LOW — Broadway `partition_by_ad_account/1` decodes JSON twice per message
`lib/ad_butler/sync/metadata_pipeline.ex:196-200` — `Jason.decode/1` runs at partition time and again in `handle_message/3`. Negligible at low volume.

### LOW — `list_expiring_meta_connections/2` 70-day lookahead over-fetches
`lib/ad_butler/accounts.ex:157` — With 90-day token lifetime, a 70-day window schedules refresh jobs for nearly every active connection each sweep. Oban unique constraint suppresses duplicates, but DB query+insert still run. A 7–14 day window is appropriate.

### LOW — `process_batch_group/1` uses `get_meta_connection!` — crashes entire batch on deleted connection
`lib/ad_butler/sync/metadata_pipeline.ex:62` — `Ecto.NoResultsError` routes all messages in the batch to DLQ. Use `get_meta_connection/1` with nil guard and `Message.failed/2` per message.

## Clean Areas

- No DB N+1: no `Repo` calls inside loops; all bulk operations use `Repo.insert_all`
- FK indexes: all FK columns have explicit single-column indexes in migrations
- Composite unique indexes: all upsert conflict targets have backing unique indexes
- Money types: all budget/cost fields use `:bigint` cents — no floats
- Query parameter pinning: all user-supplied values use `^`; no string interpolation in queries
- Oban queue separation: `sync: 20 / default: 10 / analytics: 5` with documented pool headroom
- Oban idempotency: `FetchAdAccountsWorker` unique window (5 min, keyed on meta_connection_id) prevents fan-out duplicates
- Broadway DLQ: failed messages route through RabbitMQ DLX, not silently dropped
- `meta_connections.status` index: concurrently-built index covers active-connection sweep queries

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
