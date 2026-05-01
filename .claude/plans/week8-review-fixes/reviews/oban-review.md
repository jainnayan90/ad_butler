# Oban Review — week8-review-fixes

**Verdict:** APPROVED — agent flagged 1 NEW WARNING but it is **stale/incorrect** (see Filtered).

> ⚠️ Captured from oban-specialist agent chat output (Write was denied).

Workers: `EmbeddingsRefreshWorker`, `FatigueNightlyRefitWorker`, `CreativeFatiguePredictorWorker`.

All 28 plan tasks complete. Three prior-cycle blockers (B1, B2, B3) confirmed resolved.

## Pre-existing (deferred — out of scope)

- `lib/ad_butler/workers/embeddings_refresh_worker.ex:162` — inaccurate snooze comment. Already tracked.

## Filtered findings (incorrect — not actionable)

### ~~WARN: `upsert_batch/3` missing `{:error, _}` arm~~ (FILTERED)

Agent claimed P1-T1 updated `bulk_upsert/1` to return `{:ok, _} | {:error, _}`. **This is incorrect.** P1-T1 only updated `nearest/3` and `list_ref_id_hashes/1`. `bulk_upsert/1` spec is `{:ok, non_neg_integer()}` only — no error variant possible. Adding `{:error, _}` arm would be dead code and the Elixir 1.18 type checker rejects it (verified during the work phase — see week8-review-fixes scratchpad).

## Confirmed resolved

**B3 stringification**: `build_factors_map/1` (line 420) calls `Map.new(factors, fn {k, v} -> {to_string(k), v} end)`. `build_evidence/1` and `format_predictive_clause/1` read string keys consistently.

**W3 snooze precedence**: `perform/1` runs both kinds independently then reduces with `{:error, _}` arms before `{:snooze, _}`. Matches plan and inline comment.

## Cron + unique alignment

| Worker | Cron | Unique period | Result |
|---|---|---|---|
| `EmbeddingsRefreshWorker` | `*/30 * * * *` | 1,680s (28m) | Safe — 28m window inside 30m cadence |
| `FatigueNightlyRefitWorker` | `0 3 * * *` | 82,800s (23h) | Safe — 1h gap before next nightly tick |
| `CreativeFatiguePredictorWorker` | Enqueued by AuditScheduler (`3 */6`) + nightly refit | 21,600s (6h) | Correct — nightly at 03:00 dedupes against 03:03 audit |

No schedule conflicts.

## Idempotency

All three workers are safe to replay (hash-gated change detection; `(kind, ref_id)` upserts; `MapSet` pre-check + `dedup_constraint_error?` for finding creation).

## Queue config

Pool = 53; recommended `POOL_SIZE >= 65`. `embeddings: 3` is conservative — matches rate-limit buffer strategy. Lifeline `rescue_after: 30 min` covers `CreativeFatiguePredictorWorker.timeout/1` (10 min). No `timeout/1` on `EmbeddingsRefreshWorker` — recommend adding `def timeout(_job), do: :timer.minutes(5)`. Low severity; pre-existing.

## Iron Law summary

All workers pass: idempotent, IDs not structs in args, return values handled, string keys in args, unique constraints aligned, no large data in args.
