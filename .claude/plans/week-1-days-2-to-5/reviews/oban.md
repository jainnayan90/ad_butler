# Oban Worker Review: AdButler.Workers.TokenRefreshWorker

## Summary

The worker is mostly correct and safe for initial use, but has several issues to address before relying on it at scale. Most pressing: no `unique` constraint allowing duplicate refresh chains to stack, a bare `{:ok, _} =` match that raises on DB failure instead of returning a retryable error, and no handling for permanent API failures (unauthorized/revoked) that should cancel rather than exhaust retries.

No Iron Law violations. String keys are used correctly, no structs in args, ID stored correctly.

---

## Critical (Must Fix Before Deploy)

**1. No `unique` constraint — duplicate refresh chains will stack**

`schedule_next_refresh` inserts a new job with no uniqueness guard. If `perform/1` is retried after the DB update succeeds but before returning `:ok`, you get two overlapping chains, each spawning another job on success indefinitely.

Fix — add to `use Oban.Worker`:
```elixir
unique: [period: {23, :hours}, keys: [:meta_connection_id]]
```

**2. `{:ok, _} = Accounts.update_meta_connection(...)` crashes instead of returning `{:error, reason}`**

A bare match raises `MatchError` on `{:error, changeset}`. Oban catches it and retries, but burns an attempt with a cryptic crash. After 3 attempts the job discards silently. Wrap in a `case` and return `{:error, reason}` explicitly.

**3. `get_meta_connection!/1` raises on deleted connection instead of cancelling**

If the connection is deleted, `Ecto.NoResultsError` is raised and Oban retries all 3 attempts uselessly. A missing connection is a permanent failure. Use `get_meta_connection/1` returning `nil` and return `{:cancel, "connection not found"}`.

---

## Warnings

**4. No differentiation between permanent and transient API errors**

`:unauthorized` / `:token_revoked` from Meta are retried 3 times then silently discarded. The connection remains appearing valid. Known permanent errors should return `{:cancel, reason}` and ideally update the connection's status to `:revoked`. Rate-limit errors should return `{:snooze, 3600}`.

**5. Atom key in `schedule_refresh/2` args**

`%{meta_connection_id: meta_connection_id}` uses an atom key at insertion. Works (Oban serializes to JSON), but inconsistent with `perform/1`'s string-key pattern. Use `%{"meta_connection_id" => meta_connection_id}`.

**6. No `timeout/1` callback**

The worker calls an external HTTP API. If Meta hangs, the job runs until Oban's shutdown grace period. Add:
```elixir
@impl Oban.Worker
def timeout(_job), do: :timer.seconds(30)
```

**7. No Lifeline or Pruner plugin configured**

`config.exs` sets up queues but no plugins. Without Lifeline, jobs stuck in `executing` after a node crash are never rescued. Without Pruner, `oban_jobs` grows unbounded.

---

## Suggestions

**8. Verify `expires_in` units from Meta API**

The `days = max(div(expires_in_seconds, 86_400) - 10, 1)` calculation is correct assuming seconds. If Meta ever returns milliseconds, `div` produces 0 and the clamp gives `days = 1` (daily refreshes — safe but wasteful). Add a comment or assertion.

**9. `max_attempts: 3` silent discard on exhaustion**

Consider attaching telemetry or an Oban hook to alert when the job is discarded after all attempts fail — otherwise a revoked/expired token goes completely unnoticed.

---

## Test Coverage Gaps

- No test for deleted connection (`get_meta_connection!` raising)
- No test for `:unauthorized` / `:revoked` error codes
- No test asserting duplicate jobs are NOT enqueued (uniqueness)
- No test for `schedule_next_refresh` scheduling interval math with very small `expires_in` values
