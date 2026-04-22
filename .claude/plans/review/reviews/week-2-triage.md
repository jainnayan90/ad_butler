# Week-2 Triage — Fix Queue

**Source**: week-2-review.md
**Date**: 2026-04-22
**Decision**: Fix all findings (user approved all groups)

---

## Fix Queue

### Phase 1: Code Criticals

- [ ] [C1] Fix `sync_account` to publish DB UUID, not Meta external ID
  - File: `lib/ad_butler/workers/fetch_ad_accounts_worker.ex:57-66`
  - Use `ad_account.id` (returned by `upsert_ad_account`) in the JSON payload, not `account["id"]`
  - Also add UUID assertion to mock in `FetchAdAccountsWorkerTest` to catch regressions

- [ ] [C2] Handle `Oban.insert_all/1` return value in `SyncAllConnectionsWorker`
  - File: `lib/ad_butler/workers/sync_all_connections_worker.ex:13-21`
  - Pattern match `{:ok, _jobs}` / `{:error, reason}` and propagate error for Oban retry

- [ ] [C3] Add `Mix.Task.run("app.start")` to `ReplayDlq.run/1`
  - File: `lib/mix/tasks/ad_butler.replay_dlq.ex`
  - Must run before any `Application.fetch_env!` call

- [ ] [C4] Filter orphaned ad sets before `bulk_upsert_ad_sets`
  - File: `lib/ad_butler/ads.ex:109-141`, `lib/ad_butler/sync/metadata_pipeline.ex:125`
  - Filter/log ad sets with `nil` campaign_id from `build_ad_set_attrs/2` before bulk insert
  - Document "no changeset validation" contract on the bulk upsert functions

### Phase 2: Code Warnings

- [ ] [W1] Document duplicate-publish risk in `sync_account`
  - File: `lib/ad_butler/workers/fetch_ad_accounts_worker.ex:42-45`
  - Add comment explaining RabbitMQ re-publish on retry is accepted; DB upserts are idempotent

- [ ] [W2] Add retry logic to `setup_rabbitmq_topology` in Application
  - File: `lib/ad_butler/application.ex:54`
  - Add simple retry with back-off inside `setup_rabbitmq_topology/0` (e.g., 3 attempts, 2s delay)

- [ ] [W3] Log when `list_all_active_meta_connections` hits row limit
  - File: `lib/ad_butler/accounts.ex`
  - After `Repo.all/1`, check `length(result) == 1000` and `Logger.warning/2`

- [ ] [W4] Fix `SyncAllConnectionsWorker` unique period to match cron interval
  - File: `lib/ad_butler/workers/sync_all_connections_worker.ex`
  - Change `period: 3600` to `period: 21600`

- [ ] [W5] Check `update_meta_connection` result in `:unauthorized` branch
  - File: `lib/ad_butler/workers/fetch_ad_accounts_worker.ex:51`
  - Log warning if `{:error, reason}` returned

### Phase 3: Deploy Blockers

- [ ] [DEP-B1] Create `config/prod.exs` to enforce session salt injection at build time
  - New file: `config/prod.exs`
  - Read `SESSION_SIGNING_SALT` and `SESSION_ENCRYPTION_SALT` from build env with `System.get_env/2 || raise`
  - Update `.env.example` and `runtime.exs` comment

- [ ] [DEP-B2] Create Dockerfile (multi-stage) and fly.toml
  - New files: `Dockerfile`, `fly.toml`
  - fly.toml: `release_command` for migrations, `min_machines_running = 1`, health check config
  - Dockerfile: multi-stage, elixir builder + runtime, pass SESSION_SIGNING/ENCRYPTION_SALT as ARGs

- [ ] [DEP-B3] Add health-check plug/endpoints
  - `/health/liveness` — returns 200 immediately
  - `/health/readiness` — `SELECT 1` against Repo, returns 200 or 503
  - Wire into fly.toml `[http_service.checks]`

### Phase 4: Test Gaps

- [ ] [T-C1] Add `bulk_upsert_ad_sets/2` tests
  - File: `test/ad_butler/ads_test.exs`
  - Insert test + upsert idempotency on (ad_account_id, meta_id)

- [ ] [T-C2] Add `upsert_creative/2` tests
  - File: `test/ad_butler/ads_test.exs`
  - Insert + idempotency tests

- [ ] [T-C3] Add tests for `get_ad_account_for_sync/1` and `get_ad_account_by_meta_id/2`
  - File: `test/ad_butler/ads_test.exs`
  - Basic retrieval + nil case

- [ ] [T-C4] Add cross-tenant raise tests for `get_ad_set!/2` and `get_ad!/2`
  - File: `test/ad_butler/ads_test.exs`
  - Mirror `get_campaign!/2` cross-tenant test pattern

- [ ] [T-W3] Remove `:integration` module tag from `sync_pipeline_test.exs`; use per-test tag on DLQ test only
  - File: `test/integration/sync_pipeline_test.exs`
  - `@moduletag :integration` → remove; add `@tag :integration` to the DLQ replay test only

---

## Skipped

None.

## Deferred

- DEP-W1: Outdated runtime.exs comment — minor, bundle with DEP-B1
- DEP-W2: RABBITMQ_URL in .env.example — minor, bundle with DEP-B2
- DEP-W3: releases stanza in mix.exs — bundle with DEP-B2
- DEP-W4: Structured logging / error tracking — future task
- T-W2: SyncAllConnectionsWorker tests in dedicated file — low priority refactor
- SEC: get_ad_account_for_sync/1 module boundary — optional, not urgent
