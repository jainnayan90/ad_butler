# Code Review: Elixir/Phoenix — Week 2 Sync Pipeline + Ads Context

**Status: ⚠️ REQUIRES CHANGES | 1 Critical, 3 Warnings, 3 Suggestions**

All prior findings (B1–B3, W1–W8, S1–S5) confirmed fixed.

⚠️ EXTRACTED FROM AGENT MESSAGE (agent could not write to output_file)

---

## Critical Issues

### C1: `x-message-ttl` on the work queue, not the DLQ — live sync messages expire in 5 minutes
**`lib/ad_butler/messaging/rabbitmq_topology.ex:32`**

The `x-message-ttl` (300 000 ms) is declared on `ad_butler.sync.metadata` (the main work queue), not `ad_butler.sync.metadata.dlq`. Any message not consumed within 5 minutes — e.g. during a Broadway restart — is dead-lettered. The DLQ itself has no TTL so dead messages accumulate indefinitely.

Fix: declare the DLQ queue with the TTL argument, declare the main queue without it. The `x-dead-letter-exchange` arg on the main queue is correct.

---

## Warnings

### W1: `length/1` called twice on the same list — O(n) traversal doubled
**`lib/ad_butler/accounts.ex:93-97`**

`length(result)` is evaluated twice: once in the condition, once in log metadata. Bind once: `result_count = length(result)`.

### W2: `drain_dlq/3` acks before confirming publish succeeded — messages permanently lost on broker error
**`lib/mix/tasks/ad_butler.replay_dlq.ex:36-38`**

`AMQP.Basic.publish/5` returns `:ok | {:error, reason}`. The return value is discarded. If publish fails, the message is still `ack`'d and lost from the DLQ forever. Guard the `ack` behind a successful publish; `nack` with `requeue: true` on failure.

### W3: `bulk_upsert_*` generates client-side UUIDs that are silently discarded on conflict
**`lib/ad_butler/ads.ex:85-88`, `lib/ad_butler/ads.ex:118-121`**

Both bulk upsert functions call `Map.put(:id, Ecto.UUID.generate())`. On a conflict (common re-sync path), PostgreSQL keeps the existing row's id and the generated UUID is discarded. The `returning: [:id, :meta_id]` correctly returns the actual DB ids, but the generated id looks load-bearing when it is not. Remove the `Map.put(:id, ...)` calls to avoid misleading future maintainers.

---

## Suggestions

### S1: `Publisher.publish/1` resolves itself via `Application.get_env` on every call
**`lib/ad_butler/messaging/publisher.ex:17-19`**

In production this always resolves to `__MODULE__`, so it dispatches a `GenServer.call` to itself through app env indirection. Mocking is better handled at the caller (the worker's `publisher/0` helper already does this). `publish/1` should just call `GenServer.call(__MODULE__, {:publish, payload})`.

### S2: `handle_message/3` else arm `{:ok, _}` needs a comment — reads as dead code
**`lib/ad_butler/sync/metadata_pipeline.ex:37`**

The `{:ok, _}` else arm fires when `Jason.decode` succeeds but the map lacks `"ad_account_id"`. Without a comment, maintainers will read it as redundant and remove it.

### S3: `SyncAllConnectionsWorker` silently drops changeset validation failures
**`lib/ad_butler/workers/sync_all_connections_worker.ex:21`**

`Oban.insert_all/1` returns `[%Oban.Job{} | %Ecto.Changeset{}]`. Changeset entries indicate validation failures which are currently discarded with no log. Filter the result and warn on any changesets for observability.
