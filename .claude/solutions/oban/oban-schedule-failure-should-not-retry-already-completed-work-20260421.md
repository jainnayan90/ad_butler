---
module: "AdButler.Workers.TokenRefreshWorker"
date: "2026-04-21"
problem_type: oban_behavior
component: oban_worker
symptoms:
  - "Token is refreshed successfully but Oban retries the job because scheduling the next run failed"
  - "Token gets refreshed twice (or more) in rapid succession due to Oban retry after {:error, :schedule_failed}"
  - "Worker returns {:error, :schedule_failed} after a successful token update"
root_cause: "Returning {:error, _} from perform/1 after a successful side-effect causes Oban to retry the entire job, re-executing already-completed work"
severity: high
tags: [oban, worker, idempotency, retry, token-refresh, schedule, error-handling]
---

# Oban: Return :ok After Successful Work Even When Post-Work Scheduling Fails

## Symptoms

`TokenRefreshWorker.perform/1` successfully updates the access token in the DB, then attempts
to schedule the next refresh job. If `schedule_next_refresh/2` fails (e.g., DB briefly
unavailable, Oban unique constraint race), the worker returns `{:error, :schedule_failed}`.

Oban sees `{:error, _}` and retries the job. On retry, the worker re-fetches the connection
and calls `Meta.Client.refresh_token/1` again — refreshing a token that was already refreshed,
potentially causing token invalidation or API rate-limit issues.

## Investigation

1. **Read `do_refresh/1`** — the `{:ok, _}` branch from `update_meta_connection` called
   `schedule_next_refresh`, then matched `{:error, reason}` from that and returned
   `{:error, :schedule_failed}`.
2. **Oban retry behavior** — any `{:error, _}` from `perform/1` triggers a retry (subject
   to `max_attempts`). The retry re-executes the entire `do_refresh` logic.
3. **The work was already done** — the token update succeeded. The only failure was the
   scheduling of the *next* job.
4. **Recovery exists** — `TokenRefreshSweepWorker` runs every 6 hours and re-queues any
   connection whose token is expiring and has no pending refresh job. Missing one schedule
   is always recovered within 6 h.

## Root Cause

```elixir
# Problematic — scheduling failure causes retry of already-completed token refresh
case schedule_result do
  :ok -> :ok
  {:error, reason} ->
    Logger.error("Token re-schedule failed", ...)
    {:error, :schedule_failed}   # ← triggers Oban retry of the WHOLE job
end
```

The job conflated "the work failed" with "a post-work housekeeping step failed". Oban
retries assume the entire `perform/1` needs to be re-run — not just the failed tail.

## Solution

Return `:ok` when the primary work (token update) succeeded, even if the follow-up
scheduling failed. Log the scheduling failure at `:error` level so it's visible in
monitoring. Rely on the sweep worker for recovery.

```elixir
# Fixed — scheduling failure is logged but does not trigger retry of token refresh
case schedule_result do
  :ok -> :ok
  {:error, reason} ->
    Logger.error("Token re-schedule failed",
      meta_connection_id: id,
      reason: reason
    )
    :ok   # primary work succeeded; sweep worker covers missed schedule within 6 h
end
```

### Files Changed

- `lib/ad_butler/workers/token_refresh_worker.ex:52-63` — Changed `{:error, :schedule_failed}` to `:ok`

## Prevention

- [ ] In Oban workers, distinguish between "primary work failed" (return `{:error, _}`) and "housekeeping after successful work failed" (return `:ok`, log the failure)
- [ ] Before returning `{:error, _}`, ask: "If Oban retries this job, will it redo already-completed side effects?"
- [ ] When a sweep/recovery mechanism exists, prefer `:ok` + alert over `{:error, _}` for scheduling/notification failures
- [ ] Use `{:cancel, reason}` for permanent failures where retrying is pointless (e.g., connection not found, token revoked)
- [ ] Use `{:snooze, seconds}` for transient delays (rate limits) — but document that snooze consumes `max_attempts`

## Related

- Iron Law: Oban `perform/1` must be idempotent — the same job must be safe to run multiple times
- Oban docs: `{:ok, value}` or `:ok` = success; `{:error, reason}` = retry; `{:cancel, reason}` = permanent stop; `{:snooze, seconds}` = delay
