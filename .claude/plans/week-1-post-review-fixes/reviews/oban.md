# Oban Worker Review: AdButler.Workers.TokenRefreshWorker

**Standard Oban 2.18 detected — no Pro patterns required.**

## Summary

Well-structured and largely production-safe. String keys, ID-only args, full return-value coverage, unique constraint all present. Two deployment-blocking issues: silent scheduling failure and missing test coverage.

---

## Critical (Must Fix Before Deploy)

**1. `schedule_next_refresh/2` failure silently returns `:ok` — connection can be orphaned forever**

`perform/1` calls `schedule_next_refresh(connection.id, expires_in)` but discards the result (line 43). Internally, when `Oban.insert/1` fails, the error is logged but `:ok` is returned to Oban.

If scheduling fails (DB contention, unique conflict race), a successfully-refreshed token will never trigger another refresh. Because `unique: [period: {23, :hours}]` prevents re-scheduling within 23 hours, there is no automatic recovery path.

**Fix**: Return `{:error, :schedule_failed}` from `perform/1` when scheduling fails, letting Oban retry the whole job. On retry the token is already fresh so the refresh is a no-op, and scheduling succeeds.

---

## Warnings

**2. `timeout/1` returns 30 seconds — marginal for a cold Meta API call**
Meta Graph API can take 10–20 s under load; 30 s gives almost no headroom. Recommend `:timer.seconds(60)` or `:timer.minutes(2)`.

**3. `max_attempts: 3` is low for an infrastructure-critical task**
A multi-hour Meta outage exhausts all retries in ~5 min with default backoff. Consider `max_attempts: 5` or a dedicated `token_refresh` queue.

**4. No recovery cron for orphaned connections**
No `Oban.Plugins.Cron` is configured. If issue 1 occurs, or a connection is created without `schedule_refresh/2`, there is no sweep job to re-enqueue missing refreshes.

---

## Suggestions

- **S1.** Add a `def perform(%Oban.Job{args: args})` fallback clause returning `{:cancel, "invalid args"}` — prevents `FunctionClauseError` burning retries.
- **S2.** Inconsistent cancel reason strings: `"connection not found"` (line 20) vs `Atom.to_string(reason)` (line 78). A private `cancel_reason/1` normaliser improves consistency.
- **S3.** Add `dispatch_cooldown: 500` to `:default` queue to smooth token expiry bursts (many `{:snooze, 3600}` jobs re-firing simultaneously).

---

## Queue Config

```
queues: [default: 10, sync: 20, analytics: 5]
Lifeline: rescue_after 30 min  ✓
Pruner:   max_age 7 days       ✓
Cron:     not configured       ✗ (see issue 4)
```

---

## Idempotency: PASS with caveat

Running twice with a live token is safe. Revoke path is idempotent. Scheduling-failure path is NOT idempotent in outcome (issue 1).

---

## Test Coverage Gaps

- `{:error, :token_revoked}` branch untested (only `:unauthorized` tested; they share a clause)
- `update_meta_connection` failure inside the revoke branch (the `Logger.warning` path)
- Generic `{:error, reason}` catch-all
- `schedule_next_refresh` failure — exposes the silent `:ok` return
- Arithmetic edge cases: `expires_in: 0` (clamped to 1 day) and `expires_in: 70 * 86_400` (clamped to 60 days)
