# Project Health Audit — ad_butler
**Date**: 2026-04-22 (post week-3 fixes)
**Overall Score: 81/100 — Grade B (Good, address performance gaps)**
**Prior score**: 79/100 (C) → +2 overall, category improvements across the board

---

## Category Scores

| Category | Score | Grade | Weight | Weighted | Prior |
|----------|-------|-------|--------|---------|-------|
| Architecture | 80/100 | B | 20% | 16.0 | 72 (+8) |
| Performance | 72/100 | C | 25% | 18.0 | 62 (+10) |
| Security | 94/100 | A | 25% | 23.5 | 92 (+2) |
| Test Quality | 82/100 | B | 15% | 12.3 | 81 (+1) |
| Dependencies | 72/100 | C | 15% | 10.8 | 95 (-23*) |
| **Overall** | **81/100** | **B** | — | **80.6** | 79 |

*Dependency score reflects better detection this cycle (Oban drift, orphaned dialyxir, hackney transitive chain previously missed).

---

## Critical Issues

### Performance
**P3 — `upsert_ad/2` still called per-row (ads not bulk-upserted)**
`lib/ad_butler/sync/metadata_pipeline.ex:72` — campaigns and ad_sets were fixed with `Repo.insert_all` bulk upserts, but ads remain per-row. 500 ads per sync = 500 DB round trips.
**Fix**: Add `bulk_upsert_ads/2` mirroring `bulk_upsert_campaigns/2`.

### Tests
**T1 — `health_controller_test.exs` async: true + Application.put_env race condition**
`test/ad_butler_web/controllers/health_controller_test.exs:2,18` — sad-path readiness test mutates global app env; async: true means concurrent tests can see the stub and return 503.
**Fix**: Change to `async: false`.

---

## Warnings

### Performance
**P4 — Missing index on `meta_connections.status`**
`list_all_active_meta_connections/1` filters `WHERE status = 'active'` with no supporting index. Existing partial index is on `token_expires_at`, not `status`. At scale this becomes a sequential scan.
**Fix**: `create index(:meta_connections, [:status])` migration.

**P5 — Unbounded `Repo.all()` in list functions**
`Ads.list_ad_accounts/1`, `list_campaigns/2`, `list_ad_sets/2`, `list_ads/2` — all call `Repo.all()` with no limit. No UI yet, but must add pagination before any list view is built.

**P6 — No queue concurrency cap on `:sync`**
`SyncAllConnectionsWorker` can insert 1,000 `FetchAdAccountsWorker` jobs that all run simultaneously, risking DB pool exhaustion and Meta API rate limits. The `queues: [sync: 20]` config limits concurrency to 20 — confirm this is intentional and sufficient.

### Architecture
**C1 — `HealthController` calls `Repo` directly**
`lib/ad_butler_web/controllers/health_controller.ex:4` — web layer bypasses context layer for the readiness probe.
**Fix**: Extract to `AdButler.Health.db_ping/0` or similar.

**C2 — `MetadataPipeline` aliases `Ads.AdAccount` schema**
`lib/ad_butler/sync/metadata_pipeline.ex:8` — compile-time coupling into `Ads` schema from `Sync` layer. Used for pattern-matching only.

### Security
**I1 — ReplayDlq republishes DLQ payloads without validation (PERSISTENT)**
`lib/mix/tasks/ad_butler.replay_dlq.ex:34-51` — poison messages re-enter pipeline; blast radius reduced (MetadataPipeline now UUID-casts), but still costs round-trips and can loop.
**Fix**: Validate JSON + UUID before replay; drop+log on mismatch.

**I2 — Meta error body may echo tokens into logs**
`lib/ad_butler/meta/client.ex:148-149` — `{:error, {:token_exchange_failed, body}}` may carry Meta's rejected code/token. Audit `ErrorHelpers.safe_reason/1` recursion.

### Dependencies
**D1 — Oban version drift**: `mix.exs` pins `~> 2.18`, lock resolves `2.21.1`. Review changelog and tighten to `~> 2.21`.

**D2 — Orphaned `dialyxir` in mix.lock**: no longer a dep. Run `mix deps.unlock dialyxir`.

**D3 — Hackney transitive chain (7 packages)**: still in lock via Swoosh optional dep. Confirm Swoosh adapter; if unused, unlock.

### Tests
**T2 — `Process.sleep(100)` in integration test** (`replay_dlq_test.exs:70`)
**T3 — `plug_attack_test.exs` restores `:trusted_proxy` to hardcoded `false`** — should capture original value.
**T4 — `ads_test.exs`** — `bulk_upsert_campaigns` idempotency test never reads back to confirm update.
**T5/T6 — `metadata_pipeline_test.exs`** — ad-upsert loop never exercised; orphaned ad-set warning path untested.
**T7 — `list_ads/2` filter opts untested**.
**T8 — `AMQPBasicStub` no `@behaviour`** — define `AdButler.AMQPBasicBehaviour`.

---

## What Improved This Cycle

| Issue | Status |
|-------|--------|
| A1: Ads JOINs MetaConnection directly | ✅ Fixed |
| A2: MetadataPipeline bypasses Ads context | ✅ Fixed |
| P1: N+1 get_meta_connection! per ad_account | ✅ Fixed |
| P2: Per-row campaign/ad_set upserts | ✅ Fixed |
| S1: Session salts hardcoded in config | ✅ Fixed |
| S2: Dev Cloak key committed | ✅ Fixed |
| S3: MetadataPipeline UUID validation missing | ✅ Fixed |
| Sentry token-leakage risk | ✅ Removed entirely |

---

## Action Plan

**Immediate (before first prod deploy)**
1. Fix P3: `bulk_upsert_ads/2` — mirrors existing campaign/ad_set pattern
2. Fix T1: `health_controller_test` → `async: false`
3. Add P4 migration: `create index(:meta_connections, [:status])`
4. Run `mix sobelow --exit medium`, `mix hex.audit`, `mix deps.audit`
5. `mix deps.unlock dialyxir`

**Short-term (next sprint)**
6. Fix I1: ReplayDlq payload validation
7. Add pagination to all list functions (P5)
8. Fix T3/T8 test issues
9. Add `mix sobelow` + `mix deps.audit` to CI
10. Update Oban constraint to `~> 2.21`

**Long-term**
11. Add Phoenix 1.8 Scope pattern for user-scoped queries
12. Introduce `AdButler.AMQPBasicBehaviour` for testable AMQP calls
13. Add HSTS max-age header
14. Document session-salt rotation runbook
