# Scratchpad: week8-fixes

## Dead Ends (DO NOT RETRY)

(none yet — fresh plan)

## Decisions

### From the Week 8 review

Carrying forward the most load-bearing decisions/gotchas from the v0.3 scratchpad to keep this plan's session self-contained:

- **fatigue_factors map keys**: top-level strings, inner `values` atoms (heuristics return atom-keyed maps). Pattern matchers BEFORE Postgres write use atoms; AFTER write all keys are strings. Relevant when adding tests for `build_evidence/1` or `format_predictive_clause/1` behavior.
- **`Ecto.UUID.dump!(ad.id)` is wrong for `bulk_insert_fatigue_scores/1` entries**. Pass `ad.id` directly. The `bulk_upsert/1` to be added in P2-T1 should follow the same convention — pass UUID strings, not binary dumps.
- **Regression test fixtures must avoid collinearity**: do NOT make frequency or daily reach perfectly linear in day_index — the design matrix becomes rank-deficient and `solve_normal_equations` returns `:singular` → `:insufficient_data`. P4-T7 just tightens an assertion, not the fixture.
- **`bulk_insert_fatigue_scores/1` on_conflict** replaces `:metadata` unconditionally (W2). The worker's `build_entry` always passes the metadata map, but P2-T10 documents the invariant for future callers.

### New for week8-fixes

- **B1 mitigation for the Repo-boundary Iron Law**: introduce `Embeddings.bulk_upsert/1` as a context wrapper rather than calling `Repo.insert_all` from the worker. Keeps the Iron Law (Repo only inside contexts) intact while collapsing the N+1.
- **W1 backward compatibility**: keep `Analytics.fit_ctr_regression/1` (arity 1) as the legacy single-ad entry that internally calls the new arity-2 form. Existing tests don't change.
- **W7 migration rollback strategy**: assume the migration is uncommitted locally → edit T2 in place, rollback+migrate to verify. If anyone has run this migration in a shared env, switch to a new "fix-up" migration instead of editing.

## Open Questions

- **P4-T2 directory convention**: `test/ad_butler/integration/` vs `test/integration/` — pick one. The existing test structure has `test/ad_butler/<context>/` mirror, suggesting `test/ad_butler/integration/` is consistent. Recommend keeping where it is and documenting in test_helper.exs.

## Handoff (2026-04-30 — /phx:full complete)

- Branch: main (uncommitted, ready to commit + open PR)
- Plan: .claude/plans/week8-fixes/plan.md — all 34 tasks complete
- Verification: 439 tests pass, credo --strict clean (0 issues), format clean, migration roundtrip OK, integration smoke OK (1 test)
- Solution docs captured:
  - `.claude/solutions/ecto/bulk-upsert-context-wrapper-keeps-repo-boundary-20260430.md`
  - `.claude/solutions/oban/snooze-on-rate-limit-not-error-20260430.md`
  - `.claude/solutions/testing-issues/hnsw-pgvector-knn-needs-orthogonal-vectors-20260430.md`

## Decisions made during fix-up

- **W1 / honeymoon arity-2 design**: `get_ad_honeymoon_baseline/2` cache-checks first, falls back to deriving from the 14-day pre-fetched slice. For old ads with cache miss, the slice doesn't reach far enough back → returns `:insufficient_data`, predictor heuristic skips that cycle. Cache populates on subsequent runs via the worker's metadata write (W2 fix). Tradeoff accepted vs adding a wider-than-14-day fetch.
- **W2 / metadata clobber**: predictor's `build_entry/5` now always sets `:metadata`. When honeymoon computes successfully, the baseline is written into `metadata["honeymoon_baseline"]` so future cache reads find it. When `:insufficient_data`, write `%{}` instead of nil.
- **W4 / rate-limit handling**: pattern-matches both `%{__struct__: ReqLLM.Error.API.Request, status: 429}` (real shape from `deps/req_llm/lib/req_llm/error.ex`) AND `:rate_limit` atom (test/mocks). Structural struct match (no `alias`) is intentional — a future ReqLLM rename falls through to the generic `{:error, _}` log path instead of a compile error.
- **W7 / migration refactor**: edited the uncommitted migration in place; verified with `MIX_ENV=test mix ecto.rollback --to 20260501000001 && mix ecto.migrate`. Roundtrip clean (the rollback also reverses 20260501000001 since `--to N` rolls back through N inclusive).
- **S6 / async-DDL extract**: 5 describes calling `create_insights_partition` moved from `analytics_test.exs` (async: true) to NEW `analytics_insights_test.exs` (async: false). Carried forward from week 7. P4-T7's slope < -0.001 tightening lives in the new file.
- **P4-T5 / HNSW kNN test**: switched from magnitude-shifted vectors (`shifted_vector`) to direction-distinguishable vectors (`partial_ones`) — HNSW's approximate search couldn't reliably order vectors that differed only in magnitude. See `testing-issues/hnsw-pgvector-knn-needs-orthogonal-vectors-20260430.md`.

## Review findings applied (post-fix)

From elixir-reviewer + oban-specialist + testing-reviewer (all 3 ran in parallel):

Applied:
- Documented "rows must be scoped to ad_id" caller invariant on `fit_ctr_regression/2` and `get_ad_honeymoon_baseline/2`.
- `ctr / 1` → `ctr * 1.0` with comment explaining JSON-decoded-int-to-float coercion.
- Documentation comment above the `ReqLLM.Error.API.Request` structural match explaining why we don't `alias`.

Skipped (with rationale):
- `length/1` vs `Enum.count/1` — bounded lists (3-14 items), no perf concern.
- `with` chain for `bulk_upsert` result — current `{:ok, count} = ...` is explicit; spec is `{:ok, _}`-only.
- `assert_in_delta` for `== 4.0` in `get_7d_frequency` tests — values are deterministic int-averages, exact equality is correct.
- `defp upsert_doc/2` placement in `embeddings_test.exs` — between describes is allowed in ExUnit.
