# Oban Worker Review: TokenRefreshWorker + TokenRefreshSweepWorker

⚠️ EXTRACTED FROM AGENT MESSAGE (write permission denied)

Both workers are generally well-structured. The `TokenRefreshWorker` changes are correct. The `TokenRefreshSweepWorker` has one critical runtime bug and a few warnings.

---

## CRITICAL — Type mismatch in pending_ids JSONB query

**File**: `lib/ad_butler/workers/token_refresh_sweep_worker.ex:19-25`

`fragment("?->>'meta_connection_id'", j.args)` extracts a PostgreSQL `text` value. The `mc.id not in ^pending_ids` then compares that `text[]` against `MetaConnection.id` which is a `uuid` column. PostgreSQL will not implicitly cast `text` to `uuid` — this raises `Postgrex.Error` at runtime (`operator does not exist: uuid = text`), or silently returns zero results.

**Fix**: cast in the fragment: `fragment("(?->>'meta_connection_id')::uuid", j.args)` or rewrite as a left-join.

---

## WARNING — Thundering herd on sweep recovery

All orphaned connections enqueued with `schedule_in: {1, :days}` (flat 1 day). After extended downtime with many orphans, all jobs become available simultaneously. A connection expiring in 2 days would be scheduled 1 day from now — cutting it very close.

**Recommendations**: (1) add random jitter (`1..14_400` seconds) on each enqueue, (2) compute delay proportional to actual expiry as `schedule_next_refresh/2` already does.

---

## WARNING — Sweep returns :ok on partial failure

If some `schedule_refresh/2` calls fail mid-sweep, the job completes successfully and isn't retried until the next 6-hour tick. Consider collecting errors and returning `{:error, reason}` if any enqueue fails.

---

## Suggestion — Queue isolation for sweep

Sweep shares `:default` with operational refresh jobs. A dedicated `:maintenance` queue (concurrency 1–2) would improve observability and prevent sweep work from consuming slots needed for actual token refreshes.

---

## PASS items

- **Idempotency**: `TokenRefreshWorker` unique constraint prevents duplicate jobs. Sweep is safe to retry.
- **Iron Laws**: No violations. String keys used correctly, no structs in args, all return paths handled.

## Note

Queue concurrency sum is 35 (`default:10 + sync:20 + analytics:5`). Default Ecto pool is 10 — likely undersized for production under full load.
