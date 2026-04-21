# Oban Review: TokenRefreshWorker

⚠️ EXTRACTED FROM AGENT MESSAGE (Write access unavailable)

Reviewed against Oban 2.18.x (OSS). All iron laws satisfied. Three correctness issues, one misleading log message.

## Iron Law Violations
None. String keys, only ID in args, all return values handled, unique constraint present.

## Warnings

**W1. `{:cancel, reason}` with atom reason — inconsistent error storage** (`token_refresh_worker.ex:64`)
Jason encodes atoms fine, but stored error string becomes Elixir inspect form (`:unauthorized`) instead of readable string. Fix: `{:cancel, "token_revoked: #{reason}"}` or just `{:cancel, "unauthorized"}`.

**W2. `schedule_next_refresh/2` silently discards `{:error, _}` from `Oban.insert/1`** (`token_refresh_worker.ex:77`)
If next-refresh job fails to insert (DB pressure), the self-scheduling chain breaks permanently with no log.

```elixir
defp schedule_next_refresh(id, expires_in_seconds) do
  days = max(div(expires_in_seconds, 86_400) - 10, 1)
  case schedule_refresh(id, days) do
    {:ok, _} -> :ok
    {:error, reason} ->
      Logger.error("Failed to schedule next token refresh",
        meta_connection_id: id, reason: inspect(reason))
  end
end
```

**W3. `update_meta_connection(connection, %{status: "revoked"})` result ignored on cancel path** (`token_refresh_worker.ex:57`)
If this DB call fails, connection is not marked revoked, but job is cancelled so no retry will fix it. Log the failure at minimum.

## Suggestions

**S4. Telemetry: `:cancelled` logged as "exhausted all attempts"** (`application.ex:37`)
Both `:discarded` (exhausted) and `:cancelled` (explicit cancel) use same message. Split with distinct messages; use `Logger.warning` for `:cancelled` vs `Logger.error` for `:discarded`.

**S5. Missing test for `{:error, :update_failed}` DB-update-failure branch.**

**S6. `max_attempts: 3` backoff window is tight** — with fib backoff, attempts 2→3 are ~15s apart. Consider `max_attempts: 5` or custom `backoff/1`.

## Positive Assessment
Retry-safe across all branches. Success path overwrites token (last-write-wins). Revoked path is idempotent. 23-hour unique window correct. `timeout/1` at 30s provides layered defense before Lifeline. Lifeline + Pruner correctly configured.
