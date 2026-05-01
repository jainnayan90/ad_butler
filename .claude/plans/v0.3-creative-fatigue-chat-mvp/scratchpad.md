# Scratchpad: v0.3-creative-fatigue-chat-mvp

## Dead Ends (DO NOT RETRY)

- **fit_ctr_regression test fixtures: do NOT make frequency or daily reach perfectly linear in day_index.** A test with `frequency = 1.0 + 0.1 * day_index` and constant daily reach makes the design matrix rank-deficient → solver returns `:singular` → `:insufficient_data`. Use a non-linear/zig-zag pattern for at least one of frequency or reach_count. Verified: declining test fails this way.
- **`Ecto.UUID.dump!(ad.id)` is wrong for `bulk_insert_fatigue_scores/1` entries.** insert_all goes through Ecto's schema-aware path which expects the string UUID, not the binary dump form. Pass `ad.id` directly. The worker's `build_entry/4` already does this correctly.
- **fatigue_factors map carries atom keys in `values`, string keys at the top level.** `build_factors_map/1` produces `%{"kind" => %{"weight" => N, "values" => factors}}` — top-level keys are strings (the kind), but inner `values` keep whatever shape the heuristic returned (atom-keyed for all four heuristics). After Postgres JSONB roundtrip, all keys become strings. Pattern matchers on `factors` BEFORE the write (e.g. `build_evidence/1`, `format_predictive_clause/1`) must use atom keys for the inner values. Pattern matchers on data READ FROM DB (test assertions, finding renderers in LiveView) use string keys.

## Local Setup Steps

- **pgvector binary install**: `brew install pgvector` was required on macOS (Postgres@17). The Elixir pgvector package alone is insufficient; the Postgres extension control file `/opt/homebrew/share/postgresql@17/extension/vector.control` must exist before `CREATE EXTENSION vector` succeeds.

## Decisions

### Week 8

- **W8D1-T2 regression features**: model is CTR ~ β₀ + β_day·day_index + β_freq·frequency + β_reach·cumulative_reach. `cumulative_reach` is computed as `SUM(reach_count) OVER (ORDER BY date_start)` within the 14-day window — `insights_daily` has no native cumulative_reach column. `slope_per_day` is the β_day coefficient; `projected_ctr_3d` extrapolates day_index forward 3 days while holding freq/cumulative_reach at their last linear trend.
- **W8D1 cache location**: honeymoon baseline cached on `ad_health_scores.metadata` (new column, separate migration). Append-only table — cache lives on each per-bucket row, written via the worker's existing `bulk_insert_fatigue_scores/1` upsert. Will need to extend the upsert column list to include `metadata`.
- **Migration prefix sequence**: last applied is `20260430000002`. W8 uses `20260501000001` (metadata column), `20260501000002` (pgvector ext), `20260501000003` (embeddings table + HNSW).

## Open Questions

(none yet)

## Handoff

### 2026-04-30 16:55: Week 8 implementation complete (W8D5-T3 deferred)

- Branch: main (uncommitted)
- Plan: .claude/plans/v0.3-creative-fatigue-chat-mvp/plan.md
- Status: 17/18 W8 tasks complete. W8D5-T3 (Jido pause-ad iex spike) is deferred — throwaway exploration is best done by the developer interactively, not via automated tooling. Recommended next session: 30-min iex spike, capture findings as a new "Decisions" entry above (e.g., Jido.AgentServer init signature, how to wire a Tool that calls Meta.Client.pause_ad/2, surprises about callbacks).
- Next: commit + open PR. Diff spans Analytics (regression + honeymoon), CreativeFatiguePredictorWorker (predictive layer), FatigueNightlyRefitWorker, pgvector migrations + Embeddings context + Service behaviour, EmbeddingsRefreshWorker, 13 help docs, mix task, and 24+ new tests.

### Verification snapshot
- mix compile --warnings-as-errors: clean
- mix format --check-formatted: clean
- mix deps.unlock --unused: clean
- mix check.unsafe_callers: clean
- mix test: 438/438 passing, 8 excluded (`:requires_citext`, `:integration`)
- mix credo --strict: 0 issues across 141 source files
- mix precommit: still fails at `hex.audit` task (pre-existing — same gap noted in week7-fixes scratchpad)

### Files added this session
- priv/repo/migrations/20260501000001_add_metadata_to_ad_health_scores.exs
- priv/repo/migrations/20260501000002_create_embeddings.exs
- priv/repo/migrations/20260501000003_add_embeddings_hnsw_index.exs
- lib/ad_butler/postgrex_types.ex
- lib/ad_butler/embeddings.ex
- lib/ad_butler/embeddings/embedding.ex
- lib/ad_butler/embeddings/service.ex
- lib/ad_butler/embeddings/service_behaviour.ex
- lib/ad_butler/workers/embeddings_refresh_worker.ex
- lib/ad_butler/workers/fatigue_nightly_refit_worker.ex
- lib/mix/tasks/ad_butler.seed_help_docs.ex
- priv/embeddings/help/{ctr,findings,fatigue,budget-leak,cpa,frequency,quality-ranking,learning-phase,conversions,severity,acknowledge,cpm,honeymoon}.md
- test/ad_butler/embeddings_test.exs
- test/ad_butler/workers/embeddings_refresh_worker_test.exs
- test/ad_butler/integration/week8_e2e_smoke_test.exs

### Files modified
- lib/ad_butler/analytics.ex — added get_ad_honeymoon_baseline/1, fit_ctr_regression/1 + Gauss-Jordan helpers
- lib/ad_butler/analytics/ad_health_score.ex — added :metadata field
- lib/ad_butler/workers/creative_fatigue_predictor_worker.ex — added heuristic_predicted_fatigue/1, finding evidence/title prefix
- test/ad_butler/analytics_test.exs — 11 new tests (5 regression, 6 honeymoon)
- test/ad_butler/workers/creative_fatigue_predictor_worker_test.exs — 7 new tests (5 heuristic, 2 integration)
- config/config.exs — Postgrex types, Oban embeddings queue (concurrency 3), embeddings cron, fatigue nightly cron
- config/test.exs — embeddings_service mock binding
- test/support/mocks.ex — Embeddings.ServiceMock
