# Week-2 Review Fixes

**Source**: `.claude/plans/review/reviews/week-2-triage.md`
**Date**: 2026-04-22
**Status**: Complete

## Overview

15 fixes across 4 phases from the week-2 code review. All approved by user. No new
dependencies. No schema changes. Covers correctness bugs in Oban workers, deploy
configuration, and test coverage gaps.

---

## Phase 1: Code Criticals

- [x] [oban] [C1] Fix `sync_account` to publish DB UUID, not Meta external ID — captured `{:ok, ad_account}`, use `ad_account.id`; UUID assertion in test mock
- [x] [oban] [C2] Handle `Oban.insert_all/1` return value in `SyncAllConnectionsWorker` — bound result (`_jobs = Oban.insert_all(jobs)`); returns list not `{:ok, _}`
- [x] [C3] Add `Mix.Task.run("app.start")` to `ReplayDlq.run/1` — inserted as first line before `Application.fetch_env!`
- [x] [C4] Filter orphaned ad sets before `bulk_upsert_ad_sets` — `Enum.split_with` on `campaign_id != nil`; warns with `meta_ids`; added `@doc` on bulk functions

---

## Phase 2: Code Warnings

- [x] [W1] Document duplicate-publish risk in `sync_account` — single-line comment before `Enum.find`
- [x] [W2] Add retry logic to `setup_rabbitmq_topology/0` — 3 attempts, 2s sleep, warns per failure, errors on final
- [x] [W3] Log when `list_all_active_meta_connections` hits row limit — `Logger.warning` when `length(result) >= limit`
- [x] [oban] [W4] Fix `SyncAllConnectionsWorker` unique period to match cron interval — `period: 21_600`
- [x] [W5] Check `update_meta_connection` result in `:unauthorized` branch — wrapped in case, logs on error

---

## Phase 3: Deploy Blockers

- [x] [DEP-B1] Create/update `config/prod.exs` to enforce session salt injection at build time — added `SESSION_SIGNING_SALT`/`SESSION_ENCRYPTION_SALT` via `|| raise`; both in `.env.example`; stale comment removed from `runtime.exs`
- [x] [DEP-B2] Create Dockerfile (multi-stage) and fly.toml — multi-stage build with ARGs for salts; `releases` stanza in `mix.exs`; `RABBITMQ_URL` already in `.env.example`
- [x] [DEP-B3] Add health-check plug/endpoints — `HealthController` with `liveness/2` and `readiness/2`; `/health` scope in router (no pipelines)

---

## Phase 4: Test Gaps

- [x] [ecto] [T-C1] Add `bulk_upsert_ad_sets/2` tests — insert + idempotency
- [x] [ecto] [T-C2] Add `upsert_creative/2` tests — insert + idempotency
- [x] [ecto] [T-C3] Add tests for `get_ad_account_for_sync/1` and `get_ad_account_by_meta_id/2`
- [x] [ecto] [T-C4] Add cross-tenant raise tests for `get_ad_set!/2` and `get_ad!/2`
- [x] [T-W3] Fix integration tag scope in `sync_pipeline_test.exs` — removed `@moduletag`, added `@tag :integration` to DLQ test only

---

## Verification

- [x] `mix compile --warnings-as-errors`
- [x] `mix format --check-formatted`
- [x] `mix credo --strict`
- [x] `mix test` (120 tests, 0 failures, 7 excluded)
- [ ] `mix test --include integration` (if RabbitMQ available)

---

## Risks

- **C1 (UUID bug)**: Downstream consumer currently parses `ad_account_id` as a Meta external ID
  string. After fix it becomes a UUID. Verify consumer (MetadataPipeline) uses `get_ad_account_for_sync/1`
  (already accepts UUID) — no change needed there, but worth a grep before landing.
- **DEP-B2 (Dockerfile)**: SESSION_SIGNING_SALT and SESSION_ENCRYPTION_SALT must be present at
  compile time. Fly.io build secrets (`fly secrets set --stage`) must be configured before first deploy.
- **DEP-B1/B2 ordering**: `prod.exs` must be created before Dockerfile build is tested, or the
  build will fail on missing salts.
