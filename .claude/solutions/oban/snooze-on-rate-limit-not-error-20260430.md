---
title: "Return {:snooze, n} for transient rate-limit errors so retries don't burn max_attempts inside the rate-limit window"
module: "AdButler.Workers.EmbeddingsRefreshWorker"
date: "2026-04-30"
problem_type: oban_retry
component: oban_worker
symptoms:
  - "External service returns HTTP 429 / `:rate_limit` and worker returns `{:error, reason}` to surface the failure"
  - "Oban backoff retries inside the provider's 60s rate-limit window, hitting 429 again"
  - "Three attempts exhaust within ~40s; job moves to `discarded` and the row stays at its stale state until the next cron tick"
---

## Root cause

`{:error, reason}` increments the attempt counter. With `max_attempts: 3`, three closely-spaced retries can all land inside a 60s rate-limit window — same 429 each time, then the job is discarded. The cron tick recovers eventually, but the attempt budget is wasted on a pre-determined failure mode.

## Fix

Detect the rate-limit shape and return `{:snooze, n}` instead. Snoozing reschedules the job at `now + n` seconds and Oban auto-bumps `max_attempts` so the snooze itself doesn't consume an attempt:

```elixir
defp embed_and_upsert(kind, candidates) do
  case service.embed(texts) do
    {:error, reason} ->
      if rate_limit_error?(reason) do
        Logger.warning("embeddings_refresh: rate limited, snoozing", kind: kind)
        {:snooze, 90}
      else
        Logger.error("embeddings_refresh: embed failed", kind: kind, reason: reason)
        {:error, reason}
      end
  end
end

# Match ReqLLM's struct shape AND a simpler atom for tests/mocks.
defp rate_limit_error?(:rate_limit), do: true
defp rate_limit_error?(%{__struct__: ReqLLM.Error.API.Request, status: 429}), do: true
defp rate_limit_error?(_), do: false
```

## Why structural struct match (not `alias`)

Pattern matching `%{__struct__: ReqLLM.Error.API.Request, status: 429}` instead of `aliasing` and writing `%ReqLLM.Error.API.Request{status: 429}`:

- A future ReqLLM version that renames the module falls through to `_ -> false` at runtime — handled gracefully via the generic `{:error, reason}` log path.
- An `alias` would surface as a compile error, blocking the deploy. Worse, lazy-loading deps may miss it until the worker actually fires.
- The structural match is brittle to renames but never crashes. Document where the source of truth lives (`deps/req_llm/lib/req_llm/error.ex`) so the next maintainer knows.

## Sizing the snooze

- Default to `2× the typical rate-limit window` so the next attempt clears the cooldown.
- OpenAI's RPM reset is 60s → 90s snooze covers it with margin.
- Token-based (TPM) limits can be longer (300s+); if the worker frequently TPM-limits, raise to 120-180s or bump `max_attempts: 5`.

## Reference

- v0.3 / week 8 fix W4 in `.claude/plans/week8-fixes/plan.md` (P2-T6).
- Oban docs: `Oban.Worker` callbacks — `:snooze` return value.
