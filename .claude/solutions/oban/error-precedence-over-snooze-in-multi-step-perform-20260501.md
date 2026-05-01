---
title: "Errors must take precedence over snoozes when reducing multi-step perform/1 results"
module: "AdButler.Workers.EmbeddingsRefreshWorker"
date: "2026-05-01"
problem_type: correctness
component: oban_worker
symptoms:
  - "Worker `perform/1` runs N independent steps and reduces their results to a single Oban return"
  - "Naive reduce orders branches as `{:ok, _} -> ... -> {:snooze, _} -> ... -> {:error, _}`, so a snooze on step A masks an error on step B"
  - "Hard failures get hidden behind transient rate-limit snoozes — the bad step keeps re-running silently every retry"
---

## Root cause

When `perform/1` decomposes into independent sub-steps (e.g. refresh kind="ad"
and kind="finding" against the same external API), each sub-step can return
`:ok | {:snooze, sec} | {:error, reason}`. The reduce that produces the final
Oban return must order branches with **errors before snoozes**.

Snooze means "transient — try again later." Error means "I failed and I want
Oban to count an attempt." If both happen and snooze wins:

1. Oban schedules the next attempt without burning a max_attempts slot.
2. The next attempt re-runs both kinds. The error kind fails again. The snooze
   kind may still be rate-limited.
3. Snooze still wins. Error never surfaces. The job drifts forever (or until
   the snooze condition resolves), accumulating silent failures.

## Fix

Order branches: `:ok` → `{:error, _}` → `{:snooze, _}`.

```elixir
# lib/ad_butler/workers/embeddings_refresh_worker.ex
def perform(_job) do
  ad_result = refresh_kind("ad")
  finding_result = refresh_kind("finding")

  # Errors take precedence over snoozes — snoozing on a rate limit must not
  # mask a hard failure on the other kind. Oban will retry on error and
  # re-attempt both kinds; the next retry's snooze (if still rate-limited)
  # will re-surface only after the error is resolved.
  case {ad_result, finding_result} do
    {:ok, :ok}        -> :ok
    {{:error, r}, _}  -> {:error, r}
    {_, {:error, r}}  -> {:error, r}
    {{:snooze, s}, _} -> {:snooze, s}
    {_, {:snooze, s}} -> {:snooze, s}
  end
end
```

## Why ordering each step independently is fine

Both kinds always run regardless of the first kind's result. This is desirable
when the steps are independent: a transient ad-API blip should not block a
finding refresh. The cost is one extra external call per failed attempt, but
the win is that one kind's slow recovery doesn't starve the other.

If you DO need short-circuit on first error, use `with`:

```elixir
def perform(_job) do
  with :ok <- refresh_kind("ad"),
       :ok <- refresh_kind("finding") do
    :ok
  end
end
```

This biases toward the first kind running first and only retrying the second
on success — appropriate when the second depends on the first.

## When this applies

- Any worker `perform/1` that calls multiple independent sub-steps and
  reduces to a single Oban return.
- Any `perform/1` that mixes snooze (rate-limit cooperation) with error
  (hard failure) returns.

## Related

- `.claude/solutions/oban/snooze-on-rate-limit-not-error-20260430.md` — the
  pattern for emitting snooze on HTTP 429 responses in the first place.
