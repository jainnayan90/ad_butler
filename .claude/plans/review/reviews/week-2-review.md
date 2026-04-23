# Week-2 Review: Sync Pipeline, Ads Context, Workers

**Date**: 2026-04-22
**Verdict**: REQUIRES CHANGES
**Breakdown**: 4 critical · 5 warnings (code) · 3 deploy blockers · 4 warnings (deploy) · test coverage gaps

---

## CRITICAL (fix before merge)

### C1: Published payload contains Meta external ID, not DB UUID — pipeline fully broken
**Source**: Elixir Reviewer
**Location**: `lib/ad_butler/workers/fetch_ad_accounts_worker.ex:61`

`account["id"]` is the Meta external ID (e.g. `"act_111"`). `MetadataPipeline.handle_message/3` calls `Ecto.UUID.cast(raw_id)` on the received `ad_account_id`. Every message DLQs with `:invalid_payload`. The test mocks `publish/1` with `fn _payload -> :ok end` and never inspects content — bug is invisible in tests.

**Fix**: use the DB UUID returned by `upsert_ad_account`:
```elixir
with {:ok, ad_account} <- Ads.upsert_ad_account(connection, build_ad_account_attrs(account)),
     {:ok, payload} <- Jason.encode(%{ad_account_id: ad_account.id, sync_type: "full"}),
     :ok <- publisher().publish(payload) do
  :ok
end
```

### C2: `Oban.insert_all/1` return value discarded — silent enqueue failure
**Source**: Oban Specialist
**Location**: `lib/ad_butler/workers/sync_all_connections_worker.ex:17`

`Oban.insert_all/1` returns `{:ok, jobs}` or `{:error, reason}`. Result is piped to nothing; worker always returns `:ok`. A DB error during bulk insert is invisible — no retry, connections silently skipped for 6 hours.

**Fix**: pattern match the return and propagate `{:error, reason}`.

### C3: `ReplayDlq` mix task crashes on every run — application not started
**Source**: Elixir Reviewer
**Location**: `lib/mix/tasks/ad_butler.replay_dlq.ex`

`Application.fetch_env!(:ad_butler, :rabbitmq)` called before OTP application starts. `runtime.exs` hasn't been evaluated; key doesn't exist → `ArgumentError`.

**Fix**: add `Mix.Task.run("app.start")` at the top of `run/1`.

### C4: `bulk_upsert_ad_sets` silently inserts nil campaign_id on orphaned ad sets
**Source**: Elixir Reviewer
**Location**: `lib/ad_butler/ads.ex:109-141`, `metadata_pipeline.ex:125`

`Repo.insert_all/3` skips changeset validation. `Map.get(campaign_id_map, s["campaign_id"])` returns `nil` when the ad set's campaign wasn't in the batch. A `nil` campaign_id hits the DB as an opaque NOT NULL constraint error.

**Fix**: filter out or log orphaned ad sets before bulk insert; document the "no validation" contract.

---

## WARNINGS (code)

### W1: Partial-failure in `sync_account` causes re-publish on retry
**Source**: Oban Specialist
**Location**: `fetch_ad_accounts_worker.ex:42-45`

When one account fails, the whole job retries. DB upserts are idempotent; RabbitMQ publishes re-fire for all previously-succeeded accounts. Document duplicate-publish risk or make retries smarter (track which accounts were published).

### W2: `Task.start/1` for RabbitMQ topology is unsupervised, no retry
**Source**: Elixir Reviewer
**Location**: `lib/ad_butler/application.ex:54`

If RabbitMQ is unreachable at boot, topology is never declared, app runs silently broken. Use `Task.Supervisor.start_child` or add retry with back-off inside `setup_rabbitmq_topology/0`.

### W3: `list_all_active_meta_connections` silently caps at 1000 rows
**Source**: Oban Specialist
**Location**: `lib/ad_butler/accounts.ex`

No log or error when limit is hit. Use `Repo.stream/2` or log when count == limit.

### W4: `SyncAllConnectionsWorker` unique period (3600s) mismatches cron interval (21600s)
**Source**: Oban Specialist

Deduplication window expires 5h before next cron tick. Set `period: 21600` or document the intent.

### W5: `update_meta_connection` result unchecked in `:unauthorized` branch
**Source**: Oban Specialist
**Location**: `fetch_ad_accounts_worker.ex:51`

If DB update fails, token is never marked revoked and error is swallowed.

---

## DEPLOY BLOCKERS (pre-deploy)

### DEP-B1: Compile-time session salts have no build-pipeline enforcement
`endpoint.ex:13-14` uses `compile_env!` for session salts. `config.exs` no longer sets them; `runtime.exs` intentionally omits them. `mix release` in prod **will crash** at compile time without `SESSION_SIGNING_SALT` / `SESSION_ENCRYPTION_SALT` in the build environment. No Dockerfile, fly.toml, or CI enforces this.

**Fix A**: Add `config/prod.exs` reading salts from build env vars.
**Fix B**: Replace `@session_options` in `endpoint.ex` with a runtime function.

### DEP-B2: No Dockerfile or fly.toml
Release build process undefined. No migration hook, no health-check wiring, no machine guarantees.

### DEP-B3: No health-check endpoints
No `/health/liveness` or `/health/readiness`. Fly.io cannot gate rolling deploys.

---

## DEPLOY WARNINGS

- **DEP-W1**: Outdated comment in `runtime.exs:10-17` — still says "pass PHX_SERVER=true". Now unconditional.
- **DEP-W2**: `RABBITMQ_URL` missing from `.env.example` prod section — required by `fetch_env!`.
- **DEP-W3**: No `releases:` stanza in `mix.exs` for Fly.io IPv6 distribution.
- **DEP-W4**: No structured logging / error tracking (Sentry) for Oban discards.

---

## TEST COVERAGE GAPS

- **T-C1**: `bulk_upsert_ad_sets/2` — zero tests (companion to tested `bulk_upsert_campaigns/2`)
- **T-C2**: `upsert_creative/2` — zero tests
- **T-C3**: `get_ad_account_for_sync/1`, `get_ad_account_by_meta_id/2` — untested
- **T-C4**: `Ads.get_ad_set!/2` and `Ads.get_ad!/2` cross-tenant raise — untested
- **T-W3**: First test in `sync_pipeline_test.exs` is mistagged `:integration` — mocks both adapters, never needs RabbitMQ; blocks unit CI unnecessarily
- **T-W2**: `SyncAllConnectionsWorker` tests belong in a dedicated file, not `scheduler_test.exs`
- **Suggestion**: Publish payload content should be asserted in `FetchAdAccountsWorkerTest` — would have caught C1

---

## SECURITY: PASS

No IDOR, SQL injection, atom exhaustion, XSS, or credential exposure. All prior security findings resolved. Tenant scoping verified via grep. `get_ad_account_for_sync/1` has single call site in pipeline (confirmed by grep).

---

## What's Good

- Broadway partition-by-ad-account prevents cross-tenant batch leakage
- Oban Iron Laws: string keys, no structs in args
- Cloak 32-zero-byte fallback with size guard
- Session salt compile-time/runtime separation correct in design (just needs build enforcement)
- `Oban.insert_all` refactor correct
- `Integer.parse` fallback in `parse_budget` correct
- `:invalid_payload` unification correct
