# Iron Law Violations Report — week8-review-fixes

**Verdict:** PASS — 0 new violations
**Files scanned:** 14 (all modified/new `.ex`/`.exs` in scope)
**Iron Laws checked:** 18 of 23

All 12 previously-flagged items from `.claude/plans/week8-fixes/reviews/iron-law-review.md` are resolved in the current diff.

> ⚠️ NOTE: This file was captured from the iron-law-judge agent's chat output —
> the agent was denied Write permission and reported findings inline.

---

## Pre-existing (out of scope)

- `lib/ad_butler/workers/embeddings_refresh_worker.ex:162` — inaccurate snooze comment (known pre-existing, out of scope).

---

## Verification of resolved items

**[B1] Repo boundary** — `EmbeddingsRefreshWorker.build_candidates/2` now calls `Ads.unsafe_list_ads_with_creative_names/0` and `Analytics.unsafe_list_all_findings_for_embedding/0`. No direct `Repo`/Ecto calls remain in the worker. RESOLVED.

**[B2] Embeddings API return shape** — `nearest/3` and `list_ref_id_hashes/1` return `{:ok, _} | {:error, {:invalid_kind, _}}`. `refresh_kind/1` pattern-matches `{:ok, existing_hashes}` and raises on `{:error, _}`. RESOLVED.

**[B3] Factor key stringification** — `build_factors_map/1` stringifies atom keys via `to_string(k)`; `build_evidence/1` and `format_predictive_clause/1` read string keys consistently. RESOLVED.

**[W1] Mix task bulk_upsert** — `seed_help_docs.ex` calls `Embeddings.bulk_upsert/1` once with a zip-built row list; count compared against `length(docs)`. RESOLVED.

**[W2] Bulk upsert error handling** — `upsert_batch/3` uses `case` on `Embeddings.bulk_upsert/1`. RESOLVED.

**[W3] perform/1 error precedence** — both kinds run independently; errors take precedence over snoozes in the reduction. RESOLVED.

## Other laws checked — clean

- No `String.to_atom/1` on user input anywhere in scoped files.
- No `inspect/1` wrapping Logger metadata. (`embeddings.ex:183` uses `inspect` inside a `raise` message string — permitted per CLAUDE.md.)
- No PII in logs.
- All 3 migrations reversible (`change` for nullable add; explicit `up`/`down` for embeddings table and HNSW index with `CONCURRENTLY`).
- No `:float` for money fields (`AdHealthScore` uses `:decimal`).
- No implicit cross joins; all queries pin variables with `^`.
- `@moduledoc` on all new modules; `@doc` on all public `def`s (OTP callbacks covered by `@impl true`).
- Tenant scoping: user-facing queries scope through `scope_findings/2`; cross-tenant worker queries use `unsafe_` prefix.
