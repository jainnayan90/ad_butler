---
module: "AdButler.Ads"
date: "2026-04-27"
problem_type: logic_error
component: phoenix_context
symptoms:
  - "Broadway message fails with {:error, :upsert_failed} on transient DB connection error"
  - "DBConnection.ConnectionError swallowed — Broadway cannot distinguish transient from permanent failure"
  - "Worker retries don't recover because the error atom is the same for all failure types"
root_cause: "Blanket `rescue e ->` in context function catches DBConnection.ConnectionError and Postgrex.Error equally, returning the same {:error, :upsert_failed} atom for both — Broadway's retry semantics require the process to crash on transient errors"
severity: high
tags: ["rescue", "ecto", "dbconnection", "postgrex", "broadway", "error-handling", "context"]
---

# Blanket rescue in Ecto context swallows DBConnection transient errors

## Symptoms

`bulk_upsert_insights/1` was wrapped with a blanket `rescue e ->` to return
`{:error, :upsert_failed}` instead of raising. During a transient DB connection
drop, Broadway received `{:error, :upsert_failed}` and failed the message
permanently — rather than crashing and letting Broadway retry with backoff.

## Investigation

1. **Checked Broadway failure mode** — messages were being failed, not retried
2. **Traced error path** — `bulk_upsert_insights` returned `{:error, :upsert_failed}`
3. **Root cause found**: Blanket rescue catches `DBConnection.ConnectionError`,
   which should propagate as a crash so Broadway's at-least-once delivery handles it

## Root Cause

```elixir
# WRONG — catches everything, including transient DB errors
def bulk_upsert_insights(rows) do
  # ...Repo.insert_all...
  {:ok, count}
rescue
  e ->
    Logger.error("bulk_upsert_insights failed", reason: Exception.message(e))
    {:error, :upsert_failed}
end
```

Per CLAUDE.md: "rescue is for wrapping third-party code that raises — never
rescue your own code." `DBConnection.ConnectionError` is a transient error that
Broadway is designed to handle via retries — swallowing it defeats that mechanism.

`Postgrex.Error` (constraint violations, invalid data) is appropriate to rescue
because it indicates a permanent, non-retryable failure.

## Solution

Narrow rescue to `Postgrex.Error` only:

```elixir
def bulk_upsert_insights(rows) do
  # ...Repo.insert_all...
  {:ok, count}
rescue
  e in Postgrex.Error ->
    Logger.error("bulk_upsert_insights failed", reason: Exception.message(e))
    {:error, :upsert_failed}
end
```

`DBConnection.ConnectionError` (and any unexpected error) now propagates as a
crash, which Broadway catches and retries with its configured backoff.

### Files Changed

- `lib/ad_butler/ads.ex:599` — Narrowed `rescue e ->` to `rescue e in Postgrex.Error`

## Prevention

- [ ] Add to Iron Laws? — CLAUDE.md already says "rescue is for third-party code"
- [ ] Agent check: flag bare `rescue e ->` in context modules as a warning
- Specific guidance: "In context modules called from Broadway/Oban, only rescue 
  `Postgrex.Error`. Let `DBConnection.ConnectionError` propagate — the caller's 
  retry mechanism needs to see the crash."

## Related

- Iron Law: "rescue is for wrapping third-party code that raises — never rescue your own code"
