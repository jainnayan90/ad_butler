# Week-3 Review Fixes

**Source**: `.claude/plans/review/reviews/week-3-triage.md`
**Date**: 2026-04-22
**Decision**: Fix everything — blockers → safety → behavior → suggestions

---

## Phase 1: Blockers

- [x] [B1] Wire BroadwayRabbitMQ.Producer to AMQP URL — added `connection:` key to producer_config/0
  - **File**: `lib/ad_butler/sync/metadata_pipeline.ex:196`
  - In `producer_config/0`, add `connection:` to the `BroadwayRabbitMQ.Producer` opts:
    ```elixir
    {BroadwayRabbitMQ.Producer,
      queue: @queue,
      qos: [prefetch_count: 10],
      connection: Application.fetch_env!(:ad_butler, :rabbitmq)[:url]}
    ```
  - Without this, BroadwayRabbitMQ uses a default localhost connection in prod.

- [x] [B2] Remove PlugAttack from `:health_check` pipeline — pipeline body now empty
  - **File**: `lib/ad_butler_web/router.ex:48-50`
  - Remove `plug AdButlerWeb.PlugAttack` from the `:health_check` pipeline entirely.
  - The PlugAttack rule for `/health` still exists (protects against malicious callers) but Fly
    probers share IPs and can hit 429 via the pipeline throttle, causing machine restart loops.
  - `:rate_limited` pipeline remains unchanged.

- [x] [B3] Move `x-message-ttl` from work queue to DLQ — TTL now on @dlq declaration only
  - **File**: `lib/ad_butler/messaging/rabbitmq_topology.ex:28-34`
  - Remove `{"x-message-ttl", :long, @dlq_ttl_ms}` from the `@queue` arguments.
  - Add `arguments: [{"x-message-ttl", :long, @dlq_ttl_ms}]` to the `@dlq` declaration instead.
  - Work queue TTL expires valid messages during Broadway restarts; DLQ TTL is correct behaviour.
  - ⚠️ Queue arguments are immutable once declared — run `mix ad_butler.delete_topology` (or
    manually delete queue via RabbitMQ Management UI) before re-declaring with updated args.

---

## Phase 2: Safety Warnings

- [x] [W1] Guard DLQ ack behind successful publish in `drain_dlq/3` — case on publish return, nack on error
  - **File**: `lib/mix/tasks/ad_butler.replay_dlq.ex:36-38`
  - Check `AMQP.Basic.publish/5` return value; nack on error instead of acking blindly:
    ```elixir
    case AMQP.Basic.publish(channel, @exchange, "", payload, persistent: true) do
      :ok ->
        AMQP.Basic.ack(channel, tag)
        drain_dlq(channel, limit, count + 1)
      {:error, _reason} ->
        AMQP.Basic.nack(channel, tag, requeue: true)
        count
    end
    ```

- [x] [W2] Switch session salt injection to BuildKit secrets — ARG/ENV replaced with --mount=type=secret
  - **File**: `Dockerfile:1,24-27`
  - Add `# syntax=docker/dockerfile:1.4` as first line of Dockerfile.
  - Replace the `ARG SESSION_SIGNING_SALT` / `ARG SESSION_ENCRYPTION_SALT` + `ENV ...` lines with
    `--mount=type=secret` in the `RUN mix compile` step:
    ```dockerfile
    RUN --mount=type=secret,id=SESSION_SIGNING_SALT \
        --mount=type=secret,id=SESSION_ENCRYPTION_SALT \
        SESSION_SIGNING_SALT=$(cat /run/secrets/SESSION_SIGNING_SALT) \
        SESSION_ENCRYPTION_SALT=$(cat /run/secrets/SESSION_ENCRYPTION_SALT) \
        mix assets.deploy && mix compile && mix release
    ```
  - Also collapse the separate `mix assets.deploy`, `mix compile`, `mix release` RUN steps into the
    single secret-mounting step above (secrets are per-RUN-step).
  - Remove `ARG SESSION_SIGNING_SALT`, `ARG SESSION_ENCRYPTION_SALT`, `ENV SESSION_SIGNING_SALT=...`,
    `ENV SESSION_ENCRYPTION_SALT=...` lines.
  - Build with: `docker build --secret id=SESSION_SIGNING_SALT,env=SESSION_SIGNING_SALT ...`

- [x] [W6] Add IPv6 env vars to fly.toml — ECTO_IPV6 and ERL_AFLAGS added to [env]
  - **File**: `fly.toml:10-12`
  - Append to `[env]` section:
    ```toml
    ECTO_IPV6 = "true"
    ERL_AFLAGS = "-proto_dist inet6_tcp"
    ```
  - Required for Fly's IPv6-only internal Postgres; without these, Ecto/Erlang cluster fail.

---

## Phase 3: Behavior Warnings

- [x] [W3] Add timeout to readiness `SELECT 1` query — timeout: 1_000, queue_target: 200
  - **File**: `lib/ad_butler_web/controllers/health_controller.ex:12`
  - Add `timeout: 1_000, queue_target: 200` to prevent pool exhaustion under probe flood:
    ```elixir
    SQL.query(Repo, "SELECT 1", [], timeout: 1_000, queue_target: 200)
    ```

- [x] [W4] Document at-least-once publish semantics in FetchAdAccountsWorker — comment expanded
  - **File**: `lib/ad_butler/workers/fetch_ad_accounts_worker.ex:42-43`
  - Existing comment on line 42 already mentions idempotency for Oban retries. Expand it to also
    cover `publisher().publish/1` at-least-once delivery — the Broadway pipeline handles duplicate
    `{ad_account_id, sync_type: "full"}` messages idempotently via DB upserts with conflict target.
    ```elixir
    # At-least-once delivery: RabbitMQ may redeliver on restart; MetadataPipeline
    # handles duplicates via idempotent upserts (conflict target: ad_account_id + meta_id).
    ```

- [x] [W5] Error-level log (or error return) when connection limit hit — Logger.error + result_count bound
  - **File**: `lib/ad_butler/accounts.ex:93-97`
  - Upgrade the `Logger.warning` to `Logger.error` when `result_count >= limit` — silent truncation
    is a data-loss risk. Bind `length(result)` once (also covers W9):
    ```elixir
    result_count = length(result)
    if result_count >= limit do
      Logger.error("list_all_active_meta_connections hit row limit — results truncated",
        count: result_count,
        limit: limit
      )
    end
    ```

- [x] [W7] Increase rate-limit snooze to 15 minutes — {:snooze, :timer.minutes(15)}, test updated
  - **File**: `lib/ad_butler/workers/fetch_ad_accounts_worker.ex:49`
  - Change `{:snooze, 60}` to `{:snooze, :timer.minutes(15)}`.
  - Meta API rate-limit windows are ~1 hour; 60s snooze immediately re-hits the limit on retry.

- [x] [W8] Log warning when `Oban.insert_all/1` returns changeset failures — count logged
  - **File**: `lib/ad_butler/workers/sync_all_connections_worker.ex:21`
  - Capture result and filter for changesets:
    ```elixir
    results = Oban.insert_all(jobs)
    failed_count = Enum.count(results, &match?(%Ecto.Changeset{}, &1))
    if failed_count > 0 do
      Logger.warning("Oban.insert_all had changeset failures", count: failed_count)
    end
    ```
  - Remove the `_jobs =` binding.

- [x] [W9] Bind `length(result)` once in `list_all_active_meta_connections/1` — resolved with W5
  - **File**: `lib/ad_butler/accounts.ex:93-97`
  - This is resolved together with W5 — bind `result_count = length(result)` and reuse in the
    condition and log metadata.

---

## Phase 4: Code Quality

- [x] [S1] Remove client-side UUID generation from `bulk_upsert_*` — Map.put(:id, ...) removed from both
  - **File**: `lib/ad_butler/ads.ex:85`, `lib/ad_butler/ads.ex:118`
  - Remove `|> Map.put(:id, Ecto.UUID.generate())` from entries mapping in both
    `bulk_upsert_campaigns/2` and `bulk_upsert_ad_sets/2`.
  - On conflict the supplied id is discarded; on insert Postgres generates via `gen_random_uuid()`
    default. `returning: [:id, :meta_id]` still returns the correct db-generated id.

- [x] [S2] Add happy-path tests for `get_campaign!/2`, `get_ad_set!/2`, `get_ad!/2` — 3 tests added
  - **File**: `test/ad_butler/ads_test.exs:156,358,376`
  - Each describe block currently only has a cross-tenant raise test. Add one test per function
    asserting a user can retrieve their own record and the correct struct is returned.

- [x] [S3] Remove `Application.get_env` indirection from `Publisher.publish/1` — GenServer.call(__MODULE__, ...)
  - **File**: `lib/ad_butler/messaging/publisher.ex:17-19`
  - In production this always resolves to `__MODULE__`; in tests the caller overrides via the
    `:messaging_publisher` config in `FetchAdAccountsWorker`. The indirection in Publisher itself
    is circular — call GenServer directly.

- [x] [S4] Add string-key args assertion to `SyncAllConnectionsWorker` test — Map.has_key? assertions added
  - **File**: `test/ad_butler/sync/scheduler_test.exs:33`

- [x] [S5] Add `HEALTHCHECK` directive to Dockerfile — wget-based check before CMD
  - **File**: `Dockerfile` (add before `CMD`)

- [x] [S6] Add comment to `handle_message/3` `{:ok, _}` else arm — "JSON decoded but missing ad_account_id key"
  - **File**: `lib/ad_butler/sync/metadata_pipeline.ex:37`

- [x] [S7] Add structured JSON logging for production — logger_json 6.x added, LoggerJSON backend configured
  - **File**: `mix.exs`, `config/prod.exs`

- [x] [S8] Add error tracking integration (Sentry) — sentry + hackney added, DSN from SENTRY_DSN env var
  - **File**: `mix.exs`, `config/runtime.exs`, `config/prod.exs`
  - Note: run `fly secrets set SENTRY_DSN=...` before deploying.

---

## Verification

- [x] `mix compile --warnings-as-errors`
- [x] `mix format --check-formatted`
- [x] `mix test`
- [x] `mix credo --strict`
