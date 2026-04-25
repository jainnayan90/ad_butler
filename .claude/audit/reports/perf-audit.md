# Performance Audit

**Score: 80/100**
**Date: 2026-04-23**

## Issues Found

### HIGH — Double DB round-trip on every user-facing query
`lib/ad_butler/ads.ex:25–37`
Both `scope/2` and `scope_ad_account/2` unconditionally call `list_meta_connection_ids_for_user/1` before the main query. All 8 public context functions cost 2 round-trips each. A dashboard rendering campaigns + ad sets + ads incurs 6–16 round-trips. -5 pts.

### MEDIUM — Broadway `prefetch_count` too low relative to batch throughput
`lib/ad_butler/sync/metadata_pipeline.ex:29–39`
`batcher_concurrency: 5` × `batch_size: 25` = 125 messages can be in-flight, but `prefetch_count: 50` caps AMQP delivery at 50 total (≤10 per processor). Batchers will time-out waiting for a full 25-message batch and flush early on `batch_timeout: 2000ms`. Correct value: `prefetch_count: 150` (≥ 5 × 25 + headroom). -5 pts.

### MEDIUM — `Oban.insert_all/1` without repo inside streaming transaction
`lib/ad_butler/workers/sync_all_connections_worker.ex:33`
`Oban.insert_all/1` (no repo arg) opens its own internal transaction, nesting savepoints inside the outer `Repo.transaction`. Should be `Oban.insert_all(AdButler.Repo, changesets)` to reuse the existing connection. -5 pts.

### LOW — TokenRefreshSweepWorker issues sequential `Oban.insert/1` calls
`lib/ad_butler/workers/token_refresh_sweep_worker.ex:41–55`
`Enum.reduce` calls `schedule_with_jitter/1` → `Oban.insert/1` once per connection. With limit 500 this is 500 sequential DB round-trips. Should be a single `Oban.insert_all/2` over the full list. -5 pts.

## Clean (one line each)

- N+1 queries: `handle_batch/4` calls `get_meta_connections_by_ids/1` exactly once with WHERE IN. ✓
- Bulk upserts: `on_conflict: {:replace, [...]}`, correct `conflict_target:`, `returning: [:id, :meta_id]`. ✓
- Index coverage: all FK columns indexed; composite unique indexes back all upsert conflict targets; partial index on active connections for token sweep. ✓
- ETS: `write_concurrency: :auto` correct for OTP 26. ✓
- Repo.stream: bounded by `max_rows: 500` + `Stream.chunk_every(200)`. ✓
- Publisher pool: `:atomics` round-robin over 5 GenServers, no bottleneck. ✓
- Money types: all budget/cost fields are `:bigint` cents. ✓
