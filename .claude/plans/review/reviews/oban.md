# Oban Worker Review: FetchAdAccountsWorker + SyncAllConnectionsWorker

**Status: REQUIRES CHANGES | 1 Critical, 3 Warnings, 2 Suggestions**

All prior findings confirmed fixed (C1, C2, W4, W5).

⚠️ EXTRACTED FROM AGENT MESSAGE (agent could not write to output_file)

---

## Iron Law Violations

None.

---

## Critical

### C1: RabbitMQ publish on retry causes duplicate downstream events
**`lib/ad_butler/workers/fetch_ad_accounts_worker.ex` — `sync_account/2`**

`publisher().publish(payload)` is called for every account inside `Enum.map/2`. If any account's upsert or publish fails mid-map, Oban retries the full job. All accounts that published successfully in the prior attempt are published again. The comment "Re-publishing on Oban retry is accepted" acknowledges this but does not establish whether downstream `MetadataPipeline` consumers are idempotent for full syncs.

**Action required**: Verify `MetadataPipeline` handles duplicate `{ad_account_id, sync_type: "full"}` messages idempotently and add a code comment documenting that guarantee. If consumers are not idempotent, decouple upsert and publish into two separate passes so partial publish failures do not re-publish already-published accounts.

---

## Warnings

### W1: SyncAllConnectionsWorker silently truncates connections above 1000
**`lib/ad_butler/accounts.ex:86`; `sync_all_connections_worker.ex:14`**

`list_all_active_meta_connections/1` logs a warning when the 1000-row limit is hit but the job still returns `:ok`. Connections beyond 1000 are silently skipped. Fix: inspect the returned count in the worker and return `{:error, "connection_limit_exceeded"}` or log at `:error` severity, or add pagination.

### W2: Oban.insert_all/1 changeset failures silently drop jobs
**`sync_all_connections_worker.ex:21`**

The comment documents this but there is no post-insert inspection for `%Ecto.Changeset{}` entries. Add:
```elixir
results = Oban.insert_all(jobs)
failed = Enum.count(results, &match?(%Ecto.Changeset{}, &1))
if failed > 0, do: Logger.warning("FetchAdAccountsWorker jobs dropped on insert", count: failed)
```

### W3: Rate limit snooze of 60 seconds likely too short for Meta API
**`fetch_ad_accounts_worker.ex:49`**

Meta's app-level rate limit windows are typically 1 hour. A 60-second snooze will re-attempt and immediately hit the limit again. Recommend `:timer.minutes(15)` minimum.

---

## Suggestions

### S1: `unique` states exclude `completed` — confirm 5-minute dedup window sufficient
Intentional but worth confirming: manual-trigger use cases (e.g. OAuth callback) won't deduplicate if a previous run completed in the window.

### S2: AMQP reconnect window during large account lists
`publisher/1` returns `{:error, :not_connected}` during reconnect. Job will retry correctly but wastes the full 5-minute timeout. Acceptable at current scale; flag for revisit.

---

## Queue Configuration

- `sync: 20`, `default: 10`, `analytics: 5` — verify DB pool_size >= 40 in runtime.exs
- Lifeline `rescue_after: 30min` > 5-minute job timeout — correct
- Pruner 7-day retention — acceptable
- Cron staggered 5 min from TokenRefreshSweepWorker — good scheduling hygiene
- Telemetry hooks for discarded/cancelled/exception events — good observability

## Idempotency

DB upserts use `on_conflict: {:replace, [...]}` with composite conflict_target — fully idempotent. RabbitMQ publish is at-least-once (see C1).
