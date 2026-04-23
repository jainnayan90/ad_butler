# Triage: Week-3 Review Fixes

**Date**: 2026-04-22
**Source**: `.claude/plans/review/reviews/week-3-review.md`
**Decision**: Fix everything — all blockers + all warnings + all suggestions

---

## Fix Queue

### BLOCKERs

- [ ] [B1] Wire BroadwayRabbitMQ.Producer to configured AMQP URL
  - Add `connection: Application.fetch_env!(:ad_butler, :rabbitmq)[:url]` to producer spec
  - File: `lib/ad_butler/sync/metadata_pipeline.ex:190`

- [ ] [B2] Remove PlugAttack from `:health_check` pipeline
  - Health probes must not be throttled — Fly probers share IPs and can get 429, triggering machine restarts
  - Remove `plug AdButlerWeb.PlugAttack` from `:health_check` pipeline (keep existing `/health` PlugAttack *rule* for malicious callers, but don't gate Fly's probers via the pipeline)
  - File: `lib/ad_butler_web/router.ex:48-50`

- [ ] [B3] Move `x-message-ttl` from work queue to DLQ
  - Main queue `ad_butler.sync.metadata` should NOT have TTL (it causes messages to expire during Broadway restart)
  - DLQ `ad_butler.sync.metadata.dlq` should have TTL to prevent indefinite accumulation
  - File: `lib/ad_butler/messaging/rabbitmq_topology.ex:32`

### Safety Warnings

- [ ] [W1] Guard DLQ ack behind successful publish in `drain_dlq/3`
  - Check `AMQP.Basic.publish/5` return value; on `{:error, _}` nack with `requeue: true` instead of acking
  - File: `lib/mix/tasks/ad_butler.replay_dlq.ex:36-38`

- [ ] [W2] Switch session salt injection to BuildKit secrets
  - Replace `ARG SESSION_SIGNING_SALT` + `ENV SESSION_SIGNING_SALT=…` with `--mount=type=secret` in RUN step
  - Add `# syntax=docker/dockerfile:1.4` directive at top of Dockerfile
  - File: `Dockerfile:1,24-27`

- [ ] [W6] Add `ECTO_IPV6` and `ERL_AFLAGS` to fly.toml `[env]`
  - `ECTO_IPV6 = "true"` and `ERL_AFLAGS = "-proto_dist inet6_tcp"` required for Fly's IPv6-only internal Postgres
  - File: `fly.toml`

### Behavior Warnings

- [ ] [W3] Add timeout to readiness `SELECT 1` query
  - `SQL.query(Repo, "SELECT 1", [], timeout: 1_000, queue_target: 200)` to prevent pool exhaustion under probe flood
  - File: `lib/ad_butler_web/controllers/health_controller.ex:11-16`

- [ ] [W4] Document at-least-once publish semantics in FetchAdAccountsWorker
  - Add code comment confirming `MetadataPipeline` handles duplicate `{ad_account_id, sync_type: "full"}` idempotently (DB upserts are conflict-safe)
  - File: `lib/ad_butler/workers/fetch_ad_accounts_worker.ex`

- [ ] [W5] Return error or log at `:error` when connection limit hit
  - In `SyncAllConnectionsWorker`, check if `list_all_active_meta_connections` returned exactly `limit` rows and return `{:error, :connection_limit_exceeded}` or log at `:error` severity
  - File: `lib/ad_butler/workers/sync_all_connections_worker.ex`; `lib/ad_butler/accounts.ex:86`

- [ ] [W7] Increase rate-limit snooze from 60s to `:timer.minutes(15)`
  - Meta API rate limit windows are ~1 hour; 60s snooze immediately re-hits the limit
  - File: `lib/ad_butler/workers/fetch_ad_accounts_worker.ex:49`

- [ ] [W8] Log warning when `Oban.insert_all/1` returns changeset validation failures
  - Filter result list for `%Ecto.Changeset{}` entries and log count with `Logger.warning`
  - File: `lib/ad_butler/workers/sync_all_connections_worker.ex:21`

- [ ] [W9] Bind `length(result)` once in `list_all_active_meta_connections/1`
  - `result_count = length(result)` then reuse in both condition and log metadata
  - File: `lib/ad_butler/accounts.ex:93-97`

### Code Quality Suggestions

- [ ] [S1] Remove client-side UUID generation from `bulk_upsert_*`
  - `Map.put(:id, Ecto.UUID.generate())` is discarded on conflict; remove to avoid misleading readers
  - File: `lib/ad_butler/ads.ex:85-88`, `lib/ad_butler/ads.ex:118-121`

- [ ] [S2] Add happy-path tests for `get_campaign!/2`, `get_ad_set!/2`, `get_ad!/2`
  - Currently only cross-tenant raise is tested; add test for user retrieving their own record
  - File: `test/ad_butler/ads_test.exs:156,358,376`

- [ ] [S3] Remove `Application.get_env` indirection from `Publisher.publish/1`
  - In production always resolves to `__MODULE__`; call `GenServer.call(__MODULE__, {:publish, payload})` directly
  - File: `lib/ad_butler/messaging/publisher.ex:17-19`

- [ ] [S4] Add string-key args assertion to `SyncAllConnectionsWorker` test
  - `assert_enqueued(args: %{"meta_connection_id" => conn.id})` per job to guard atom-key regression
  - File: `test/ad_butler/sync/scheduler_test.exs:33`

- [ ] [S5] Add `HEALTHCHECK` directive to Dockerfile
  - `HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 CMD wget -qO- http://localhost:4000/health/liveness || exit 1`
  - File: `Dockerfile`

- [ ] [S6] Add comment to `handle_message/3` `{:ok, _}` else arm
  - Clarify this fires when JSON decodes but `"ad_account_id"` key is missing
  - File: `lib/ad_butler/sync/metadata_pipeline.ex:37`

- [ ] [S7] Add structured JSON logging for production
  - Add JSON formatter or `logger_json` in `config/prod.exs` for log aggregator compatibility
  - File: `config/prod.exs`

- [ ] [S8] Add error tracking integration
  - Add Sentry or AppSignal to `mix.exs` and configure in `runtime.exs`; catches GenServer/Oban/LiveView crashes
  - File: `mix.exs`, `config/runtime.exs`

---

## Skipped

None.

---

## Deferred

None.

---

## Next Steps

18 items in fix queue across 4 priorities (blockers → safety → behavior → suggestions).
