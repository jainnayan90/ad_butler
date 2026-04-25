# Architecture Audit — 2026-04-23

**Score: 72/100**

## Issues Found

### [A1-CRITICAL] `Ads` context calls `Accounts` on every scoped query
`lib/ad_butler/ads.ex:26, 31`
`scope/2` and `scope_ad_account/2` both call `Accounts.list_meta_connection_ids_for_user/1` directly. `Ads` depends on `Accounts` at runtime for every user-scoped query, issuing an extra SELECT round-trip per call. `Ads` cannot be tested or reasoned about independently of `Accounts`. -10 pts.
Fix: accept `[meta_connection_id]` as a parameter; hoist the ID lookup to the calling controller.

### [A2-MODERATE] `MetadataPipeline` calls `Accounts.get_meta_connections_by_ids/1` directly
`lib/ad_butler/sync/metadata_pipeline.ex:15, 66`
`Sync` namespace reaching directly into `Accounts` context. The trade-off (avoiding tokens in AMQP messages) is valid but undocumented in the moduledoc. -5 pts.

### [A3-MODERATE] Broadway throughput comment stale
`lib/ad_butler/sync/metadata_pipeline.ex:27–29`
Comment says "5 procs × 10 = 50" but `batch_size` is 25. Stale math will cause future maintainers to miscalibrate prefetch values. -5 pts.

### [A4-MODERATE] `setup_rabbitmq_topology` fails silently after all retries
`lib/ad_butler/application.ex:61, 72–76`
All 3 retries exhausted → logs error and returns `:ok`. Exchange and DLQ bindings are never declared but Publisher and MetadataPipeline start normally. Messages published to the undeclared exchange are silently dropped. -3 pts.
Fix: crash the supervision tree on exhausted retries (fail-fast), or make topology a supervised GenServer that gates the Publisher.

### [A5-MINOR] Bulk upsert scaffolding duplicated 3×
`lib/ad_butler/ads.ex:88–316`
`bulk_upsert_campaigns/2`, `bulk_upsert_ad_sets/2`, `bulk_upsert_ads/2` are structurally identical (~80 lines repeated). -5 pts.

## Clean (one line each)

- Workers→web isolation: no worker imports any `AdButlerWeb` module. ✓
- GenServer design: Registry + `:atomics` round-robin is correct and lock-free; `pending_connected` suspension avoids busy-polling; `terminate/2` demonitors and closes AMQP resources. ✓
- Supervision order: Repo → Vault → RateLimitStore → Oban → PublisherPool → MetadataPipeline → Endpoint. ✓
- Cron/scheduler: string keys in all perform heads; unique idempotency guards on all 4 workers. ✓
- Money types: all budget columns are `_cents` integers; `parse_budget/1` rounds Meta API floats. ✓
- Query safety: all user values pinned with `^`; no string interpolation in Ecto queries. ✓
- Third-party wrapping: Meta.Client, AMQP.Basic, PublisherPool all behind project-owned behaviours. ✓
