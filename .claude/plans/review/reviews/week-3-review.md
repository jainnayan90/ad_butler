# Review: Week 2 — Sync Pipeline, Ads Context, Deployment

**Date**: 2026-04-22
**Verdict**: REQUIRES CHANGES
**Breakdown**: 3 blockers · 9 warnings · 8 suggestions

All prior findings (B1–B3, W1–W8, S1–S5) confirmed fixed.

---

## BLOCKERS (fix before merge)

### B1: Broadway consumer uses hardcoded default AMQP URL — never connects to production broker
**Source**: Security Analyzer
**Location**: `lib/ad_butler/sync/metadata_pipeline.ex:190-198`

`BroadwayRabbitMQ.Producer` spec omits `connection:`. Library defaults to `"amqp://guest:guest@localhost:5672"`. The publisher and topology setup both read `Application.fetch_env!(:ad_butler, :rabbitmq)[:url]` — Broadway silently diverges and consumes nothing in production.

**Fix**:
```elixir
url = Application.fetch_env!(:ad_butler, :rabbitmq)[:url]
{BroadwayRabbitMQ.Producer, queue: @queue, connection: url, qos: [prefetch_count: 10]}
```

### B2: PlugAttack throttles health check probes — Fly can self-inflict restarts
**Source**: Deploy Validator
**Location**: `lib/ad_butler_web/router.ex:48-50`; `lib/ad_butler_web/plugs/plug_attack.ex:17-25`

`:health_check` pipeline runs `AdButlerWeb.PlugAttack`, which throttles `/health` to 60 req/60s per IP. Fly's probers share internal IPs across machines and can exhaust this budget, receiving HTTP 429. A throttled readiness check marks the machine unhealthy and triggers a restart.

**Fix**: Remove PlugAttack from `:health_check` pipeline, or add an `allow` rule for `/health` paths before the throttle rule.

### B3: `x-message-ttl` on work queue, not DLQ — live sync messages expire in 5 minutes
**Source**: Elixir Reviewer
**Location**: `lib/ad_butler/messaging/rabbitmq_topology.ex:32`

`x-message-ttl: 300_000` is declared on `ad_butler.sync.metadata` (main work queue). Messages not consumed within 5 minutes (e.g. during Broadway restart) are dead-lettered. The DLQ has no TTL and accumulates indefinitely.

**Fix**: Move `x-message-ttl` to the DLQ declaration; remove from main queue.

---

## WARNINGS

### W1: `drain_dlq/3` acks before confirming publish — messages permanently lost on broker error
**Source**: Elixir Reviewer
**Location**: `lib/mix/tasks/ad_butler.replay_dlq.ex:36-38`

`AMQP.Basic.publish/5` return value is discarded. A failed publish still `ack`s the message — it's gone from the DLQ forever.

**Fix**: `nack` with `requeue: true` on publish failure; only `ack` after confirmed success.

### W2: Session salts baked into Docker image layers — extractable via `docker history`
**Source**: Security Analyzer
**Location**: `Dockerfile:24-27`

`ARG` + `ENV` pattern persists salts in layer metadata. Anyone with image read access can extract them.

**Fix**: Use BuildKit secrets (`--mount=type=secret`) so values never land in a layer. Also requires rotation on each rebuild — consider switching salts to runtime env vars.

### W3: `/health/readiness` SELECT 1 has no timeout — DB pool exhaustion risk
**Source**: Security Analyzer
**Location**: `lib/ad_butler_web/controllers/health_controller.ex:11-16`

Default 15s query timeout under load (60 req/min/IP × N IPs) can hold all DB pool slots and starve real traffic.

**Fix**: `SQL.query(Repo, "SELECT 1", [], timeout: 1_000, queue_target: 200)`. Tighten health rate limit to 10-20/min.

### W4: RabbitMQ publish on Oban retry causes duplicate downstream events
**Source**: Oban Specialist
**Location**: `lib/ad_butler/workers/fetch_ad_accounts_worker.ex` — `sync_account/2`

If one account's publish fails mid-`Enum.map`, Oban retries the full job. Previously-published accounts get re-published. The existing comment acknowledges at-least-once semantics but doesn't verify `MetadataPipeline` is idempotent for duplicate `{ad_account_id, sync_type: "full"}` messages.

**Fix**: Add a code comment documenting the idempotency guarantee in the pipeline, or decouple upsert and publish into two passes.

### W5: `SyncAllConnectionsWorker` silently skips connections beyond 1000
**Source**: Oban Specialist
**Location**: `lib/ad_butler/accounts.ex:86`; `sync_all_connections_worker.ex:14`

Row-limit warning is logged but job still returns `:ok`. Connections beyond 1000 are silently skipped with no error signal.

**Fix**: Return `{:error, "connection_limit_exceeded"}` or log at `:error` when truncation occurs, or paginate.

### W6: `ECTO_IPV6` and `ERL_AFLAGS` missing from fly.toml `[env]`
**Source**: Deploy Validator
**Location**: `fly.toml:10-12`

`runtime.exs` checks `ECTO_IPV6` but it's never set. Fly's internal Postgres is IPv6-only — DB connections will fail without it.

**Fix**:
```toml
[env]
  ECTO_IPV6 = "true"
  ERL_AFLAGS = "-proto_dist inet6_tcp"
```

### W7: Rate limit snooze of 60s too short for Meta API rate limits
**Source**: Oban Specialist
**Location**: `fetch_ad_accounts_worker.ex:49`

Meta's app-level windows are typically 1 hour. 60s snooze will immediately re-hit the limit, burning retries and producing log noise.

**Fix**: Minimum `:timer.minutes(15)`.

### W8: `Oban.insert_all/1` changeset failures silently dropped — no observability
**Source**: Oban Specialist / Elixir Reviewer
**Location**: `sync_all_connections_worker.ex:21`

Comment documents this correctly but there's no inspection of the result list for `%Ecto.Changeset{}` entries.

**Fix**:
```elixir
results = Oban.insert_all(jobs)
failed = Enum.count(results, &match?(%Ecto.Changeset{}, &1))
if failed > 0, do: Logger.warning("FetchAdAccountsWorker jobs dropped", count: failed)
```

### W9: `length/1` called twice on same list — unnecessary O(n) double traversal
**Source**: Elixir Reviewer / Oban Specialist
**Location**: `lib/ad_butler/accounts.ex:93-97`

`length(result)` evaluated twice (condition + log metadata). Bind once:
```elixir
result_count = length(result)
if result_count >= limit do ...count: result_count...
```

---

## SUGGESTIONS

### S1: `bulk_upsert_*` generates client-side UUIDs that are discarded on conflict
**`lib/ad_butler/ads.ex:85-88`, `lib/ad_butler/ads.ex:118-121`**

`Map.put(:id, Ecto.UUID.generate())` on the conflict path — PostgreSQL keeps the existing row's id. The generated UUID is discarded but looks load-bearing. Remove the `Map.put(:id, ...)` calls.

### S2: `get_campaign!/2`, `get_ad_set!/2`, `get_ad!/2` missing happy-path tests
**`test/ad_butler/ads_test.exs:156,358,376`**

Only cross-tenant error cases tested. Add passing cases (retrieve own record).

### S3: `Publisher.publish/1` resolves to itself via `Application.get_env` on every call
**`lib/ad_butler/messaging/publisher.ex:17-19`**

In production always resolves to `__MODULE__`. Remove indirection; call `GenServer.call(__MODULE__, {:publish, payload})` directly.

### S4: `SyncAllConnectionsWorker` test missing string-key args assertion
**`test/ad_butler/sync/scheduler_test.exs:33`**

`all_enqueued(worker: FetchAdAccountsWorker)` only checks count. Add `assert_enqueued(args: %{"meta_connection_id" => conn.id})` per job to guard atom-key regression.

### S5: Missing `HEALTHCHECK` directive in Dockerfile
Add: `HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 CMD wget -qO- http://localhost:4000/health/liveness || exit 1`

### S6: `handle_message/3` `{:ok, _}` else arm needs a comment
**`lib/ad_butler/sync/metadata_pipeline.ex:37`**

Fires when JSON decodes but lacks `"ad_account_id"`. Without a comment, looks like dead code.

### S7: No structured (JSON) logging in production
**`config/config.exs:64`**

Plain text format makes log aggregation harder. Add JSON formatter or `logger_json` in `prod.exs`.

### S8: No error tracking configured
No Sentry/AppSignal/equivalent. Crashes in GenServers, Oban workers only surface in raw logs.

---

## Deduplication Notes

- W8/S3(elixir) and W2(oban) are merged into single W8 (insert_all observability)
- W9(elixir) and S1(oban) merged into W9 (length/1 twice)
- Deploy B1 (PlugAttack on health) is distinct from elixir health rate limit — kept separate
