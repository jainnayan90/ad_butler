# Oban Review: Week-1 Audit Fixes

⚠️ EXTRACTED FROM AGENT MESSAGE (Write permission denied in subagent context)

**Verdict**: REQUIRES CHANGES — 1 blocker, 2 warnings, 2 suggestions

---

## Blocker

### B1: Non-exhaustive pattern match in `do_refresh/1`

`token_refresh_worker.ex` line ~68 — the changeset arm has no catch-all:

```elixir
{:error, %Ecto.Changeset{} = changeset} ->
  Logger.error(...)
  {:error, :update_failed}
# ← no catch-all here
```

`Repo.update/1` spec says `{:ok, _} | {:error, Ecto.Changeset.t()}`, so this is exhaustive in practice. However, if a middleware, proxy, or future code returns `{:error, :some_atom}`, the `case` raises `CaseClauseError`. Oban rescues and retries, eventually discarding after 5 attempts with no clear log message — silent data loss.

Fix:
```elixir
{:error, reason} ->
  Logger.error("Token refresh update failed (unexpected)",
    meta_connection_id: id,
    reason: inspect(reason)
  )
  {:error, :update_failed}
```

---

## Warnings

### W1: 500-row limit is silent when hit
`list_expiring_meta_connections/2` returns exactly 500 rows with no signal when truncated. The 501st connection is picked up next 6h sweep cycle — no permanent loss — but the overflow is invisible in logs.
Fix: log a warning when `length(connections) == 500`.

### W2: `snooze` comment is OSS-Oban-specific
Comment at line ~99 says snooze consumes an attempt — true for OSS Oban. With Oban Pro Smart Engine it does not. A future Pro migration could introduce an infinite snooze loop.
Fix: add `# NOTE: with Oban Pro Smart Engine, snooze does NOT consume an attempt`.

---

## Suggestions

### S1: `TokenRefreshSweepWorker` has no `timeout/1`
Up to 500 sequential `Oban.insert/1` DB calls with no timeout is risky under DB load.
Recommend: `def timeout(_job), do: :timer.minutes(2)`

### S2: `Enum.each/2` discards all enqueue errors
If every enqueue fails, the sweep job completes `:ok` — Oban's retry machinery never fires even if the queue is truly broken.
Consider returning `{:error, _}` when zero connections are successfully enqueued.

---

## Idempotency Assessment

Both workers are safe to retry. Sweep deduplicates via `unique: [period: {6, :hours}, fields: [:worker]]`. Refresh deduplicates per connection via `unique: [period: {23, :hours}, keys: [:meta_connection_id]]`. Re-running `update_meta_connection` on retry is safe.
