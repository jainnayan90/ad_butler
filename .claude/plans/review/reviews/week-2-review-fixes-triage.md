# Triage: Week-2 Review Fixes

**Date**: 2026-04-22
**Source**: `.claude/plans/review/reviews/week-2-review-fixes-review.md`
**Decision**: Fix all blockers + warnings + deploy/test suggestions

---

## Fix Queue

### BLOCKERs

- [x] [B1] Fix `Enum.each` → `Enum.map` + error propagation in `metadata_pipeline.ex:71`
  - Replace `Enum.each(ads, &Ads.upsert_ad(...))` with `Enum.map` + find first error and return it
  - File: `lib/ad_butler/sync/metadata_pipeline.ex`

- [x] [B2] Create `/app/bin/migrate` binary + `AdButler.Release` module
  - Create `lib/ad_butler/release.ex` with `Ecto.Migrator.with_repo` + `run(:up, all: true)`
  - Create `rel/overlays/bin/migrate` (chmod 755) calling `eval "AdButler.Release.migrate()"`
  - File: `lib/ad_butler/release.ex`, `rel/overlays/bin/migrate`

- [x] [B3] Export Docker ARG values as ENV in Dockerfile
  - Add `ENV SESSION_SIGNING_SALT=${SESSION_SIGNING_SALT}` and `ENV SESSION_ENCRYPTION_SALT=${SESSION_ENCRYPTION_SALT}` after ARG declarations
  - File: `Dockerfile`

### Security WARNINGs

- [x] [W1] Fix `inspect(reason)` to only inspect `cs.errors`, not full changeset
  - Pattern-match `%Ecto.Changeset{} = cs` and log `cs.errors` only
  - Add `@derive {Inspect, except: [:access_token]}` to `MetaConnection`
  - Add `"access_token"` to `:filter_parameters` in `config.exs`
  - File: `lib/ad_butler/workers/fetch_ad_accounts_worker.ex`, `lib/ad_butler/accounts/meta_connection.ex`, `config/config.exs`

- [x] [W2] Validate SESSION_*_SALT is non-empty in `config/prod.exs`
  - Replace `|| raise` with explicit check for nil, `""`, and minimum length
  - File: `config/prod.exs`

### Deploy WARNINGs

- [x] [W3] Set `auto_stop_machines = false` in `fly.toml`
  - Broadway RabbitMQ consumers don't survive machine suspension
  - File: `fly.toml`

- [x] [W4] Add `kill_timeout = 60` to `fly.toml`
  - 5s default too short for in-flight Oban workers and Broadway consumer ACKs
  - File: `fly.toml`

- [x] [W6] Add rate limiting to `/health/readiness`
  - Prefer binding to Fly private network; at minimum add throttle pipeline
  - File: `fly.toml` (internal_port binding) or `lib/ad_butler_web/router.ex`

### Code + Test WARNINGs

- [x] [W5] Move RabbitMQ topology setup from `Task.start/1` to supervised Task
  - Add `Task.Supervisor` to child list, use `Task.Supervisor.start_child/2`
  - File: `lib/ad_butler/application.ex`

- [x] [W7] Add comment to `sync_all_connections_worker.ex` about insert_all validation failures
  - Document that `Oban.insert_all/1` silently drops invalid changesets (not raises)
  - File: `lib/ad_butler/workers/sync_all_connections_worker.ex`

- [x] [W8] Add name assertion to `bulk_upsert_ad_sets/2` idempotency test
  - After second upsert, reload from DB and assert `reloaded.name == "Updated"`
  - File: `test/ad_butler/ads_test.exs`

### Deploy Suggestions

- [x] [S1] Add non-root user to Dockerfile runtime stage
  - `addgroup appgroup && adduser appuser -G appgroup` + `USER appuser`
  - File: `Dockerfile`

- [x] [S2] Increase health check grace period from 10s to 30s in `fly.toml`
  - File: `fly.toml`

- [x] [S3] Remove `:tar` from `releases` stanza in `mix.exs`
  - Dockerfile copies unpacked dir; `:tar` step unused and wastes build time
  - File: `mix.exs`

### Test Suggestions

- [x] [S4] Replace `match?({:ok, _}, Ecto.UUID.cast(id))` with `assert {:ok, _} = Ecto.UUID.cast(id)`
  - Cleaner ExUnit failure message on regression
  - File: `test/ad_butler/workers/fetch_ad_accounts_worker_test.exs`

- [x] [S5] Add UUID payload validation to integration test publish mock
  - Mirror the unit test: assert `ad_account_id` is a valid UUID in `fn payload -> ... end`
  - File: `test/integration/sync_pipeline_test.exs`

---

## Skipped

- S6 (length/1 called twice in accounts.ex) — trivial, skipped

---

## Next Steps

15 items in fix queue across 3 priorities (blockers → security → deploy/code).
</content>
