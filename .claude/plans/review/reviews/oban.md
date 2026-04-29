## Oban Worker Review — Pass 3

**1 Blocker · 3 Warnings · 3 Suggestions**

---

## BLOCKER

**DigestWorker.perform/1 silently mishandles SMTP errors**
`lib/ad_butler/workers/digest_worker.ex:18-21`

`deliver_digest/2` returns `:ok | {:skip, :no_findings} | {:error, term()}`. The inner `case` matches only the first two. SMTP failure raises `CaseClauseError` — Oban retries but logs a misleading error making on-call debugging harder.

Fix:
```elixir
case Notifications.deliver_digest(user, period) do
  :ok                   -> :ok
  {:skip, :no_findings} -> :ok
  {:error, reason}      -> {:error, reason}
end
```

---

## WARNINGS

**W1 — `timeout/1` of 30s may be tight for SMTP**
`lib/ad_butler/workers/digest_worker.ex:26`

30s can be too short on cold-start TLS handshakes under load. Consider `:timer.seconds(60)` or removing the override and relying on the SMTP adapter's own socket timeout.

**W2 — Daily and weekly cron both fire at 08:00 on Mondays**
`config/config.exs` (cron schedules)

`"0 8 * * *"` (daily) and `"0 8 * * 1"` (weekly) overlap every Monday. Unique constraint correctly distinguishes them by args (daily vs weekly), so both fan-outs proceed — safe but likely sends two digests on Monday. If only weekly digest is desired on Mondays, change daily to `"0 8 * * 2-7"`.

**W3 — DB connection pool size comment stale**
`config/config.exs`

Comment says `POOL_SIZE >= 25` but queue concurrency sums to 45+ (default:10 + sync:20 + analytics:5 + audit:5 + notifications:5). Minimum pool should be ~50.

---

## SUGGESTIONS

- Idempotency: 25h unique window on DigestWorker and 23h on DigestSchedulerWorker both correct.
- Fan-out partial failure: chunks 0..N-1 already committed on DB error; retried chunks dedup-suppressed — correct, but worth a comment.
- notifications queue concurrency of 5 may lag at scale; consider raising to 10-15.
