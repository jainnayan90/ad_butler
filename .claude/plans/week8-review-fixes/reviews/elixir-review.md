# Elixir Review — week8-review-fixes

**Verdict:** APPROVED — 0 BLOCKER, 1 WARNING, 2 SUGGESTIONS

> ⚠️ Captured from elixir-reviewer agent chat output (Write was denied).

All 3 prior BLOCKERs confirmed resolved (B1 Repo boundary, B2 tagged-tuple returns, B3 atom-key stringification). All 9 prior WARNINGs resolved per plan completion.

## Pre-existing (defer to separate PR)

- `lib/ad_butler/workers/embeddings_refresh_worker.ex:162` — comment claims "Oban auto-bumps max_attempts on snooze." Standard OSS Oban does not. Already tracked.

## Warnings

### W1 — `@external_resource` absent for priv/embeddings/help/ glob

`lib/mix/tasks/ad_butler.seed_help_docs.ex:27, 47-54` — `Path.wildcard/1` and `File.read!/1` run at task invocation time, not module-attribute compile time, so `@external_resource` is not strictly required. But `@help_dir` is a bare compile-time string; a future refactor moving doc discovery into a module attribute would silently skip recompilation. Add a comment explaining the deliberate absence.

## Suggestions

### S1 — `Enum.sum(Enum.map(...))` repeated 6 times across `analytics.ex`

`lib/ad_butler/analytics.ex:374-375, 693-694, 824-825` — collapse with `Enum.sum_by/2` (Elixir 1.18+). Cosmetic.

### S2 — `length/1` for threshold guards on small bounded lists

`lib/ad_butler/analytics.ex:371, 475, 690` — `if length(qualifying) < @honeymoon_window_days` traverses the list. Lists are bounded (3 and 10 max) so no perf risk. Idiomatic Elixir prefers `Enum.count/1` to signal intent. Cosmetic.

## Iron Law Checks (all pass)

| Law | Status |
|-----|--------|
| No `Repo` in workers | Pass |
| Tagged-tuple returns | Pass |
| Oban string-key args | Pass |
| `unsafe_` prefix on unscoped queries | Pass |
| `tenant_filter_results/2` fail-closed on unknown kind | Pass |
| Runtime config via `Application.get_env` | Pass |
| `@moduledoc` + `@doc` + `@spec` on public defs | Pass |
| Behaviour + Mox for embeddings service | Pass |
| Migrations reversible + `@disable_ddl_transaction` for HNSW | Pass |
| Logger metadata keys allowlisted | Pass |
| No `String.to_atom` on user input | Pass |
| Error precedence over snooze in worker reduce | Pass |
| Tenant isolation tests present | Pass |
