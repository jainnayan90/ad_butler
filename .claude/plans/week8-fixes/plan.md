# Plan: Week 8 Review Fix-up

**Source**: [.claude/plans/v0.3-creative-fatigue-chat-mvp/reviews/week8-triage.md](.claude/plans/v0.3-creative-fatigue-chat-mvp/reviews/week8-triage.md)
**Scope**: 23 findings (2 BLOCKERs, 12 WARNINGs, 9 SUGGESTIONs) from the Week 8 review, organized into 5 phases.
**Verification**: `mix compile --warnings-as-errors` per task; `mix test <affected>` per phase; `mix credo --strict` + full `mix test` at the end.

## Goal

Resolve every Week 8 review finding before merging the v0.3 predictive fatigue + embeddings work. No new functionality — pure cleanup pass against the suggested fixes captured in the triage doc.

## What Exists

- Week 8 work landed on `main`-tracked working tree (uncommitted). All 438 tests pass on baseline.
- Triage doc at [week8-triage.md](.claude/plans/v0.3-creative-fatigue-chat-mvp/reviews/week8-triage.md) lists every finding with file:line refs and suggested fixes.
- The implementation files this plan modifies: [embeddings_refresh_worker.ex](lib/ad_butler/workers/embeddings_refresh_worker.ex), [embeddings.ex](lib/ad_butler/embeddings.ex), [embedding.ex](lib/ad_butler/embeddings/embedding.ex), [creative_fatigue_predictor_worker.ex](lib/ad_butler/workers/creative_fatigue_predictor_worker.ex), [analytics.ex](lib/ad_butler/analytics.ex), [fatigue_nightly_refit_worker.ex](lib/ad_butler/workers/fatigue_nightly_refit_worker.ex), [20260501000002_create_embeddings.exs](priv/repo/migrations/20260501000002_create_embeddings.exs), [analytics_test.exs](test/ad_butler/analytics_test.exs), [embeddings_refresh_worker_test.exs](test/ad_butler/workers/embeddings_refresh_worker_test.exs), [week8_e2e_smoke_test.exs](test/ad_butler/integration/week8_e2e_smoke_test.exs), [config/config.exs](config/config.exs).

## Phases

### Phase 1 — Schema + Migration cleanups

Small, isolated changes that don't depend on other phases.

- [x] [P1-T1][ecto] **W7** — replace raw `execute "ALTER TABLE..."` CHECK constraint in [20260501000002_create_embeddings.exs:23-27](priv/repo/migrations/20260501000002_create_embeddings.exs#L23-L27) with `create constraint(:embeddings, :embeddings_kind_check, check: "kind IN ('ad', 'finding', 'doc_chunk')")`. Roll the migration back+forward in dev/test to verify reversibility.
- [x] [P1-T2][ecto] **W8** — add an inline comment in `down/0` of the embeddings migration warning future authors that adding a second `vector` column requires updating the `DROP EXTENSION` rollback path.
- [x] [P1-T3][ecto] **W9** — replace `validate_length(:content_hash, is: 64)` in [embedding.ex:51](lib/ad_butler/embeddings/embedding.ex#L51) with `validate_format(:content_hash, ~r/\A[0-9a-f]{64}\z/)` (covers length + hex in one rule).
- [x] [P1-T4][ecto] **S8** — add a comment to [20260501000002_create_embeddings.exs:13](priv/repo/migrations/20260501000002_create_embeddings.exs#L13): `# 1536 = OpenAI text-embedding-3-small; dimension change requires a new migration`.

### Phase 2 — Worker correctness (BLOCKERs + Iron-Law N+1s)

Highest-impact fixes. Some span multiple files.

- [x] [P2-T1][oban] **B1** — rewrite `EmbeddingsRefreshWorker.upsert_batch/3` ([embeddings_refresh_worker.ex:118-138](lib/ad_butler/workers/embeddings_refresh_worker.ex#L118-L138)) to use a single `Repo.insert_all(Embedding, rows, on_conflict: ..., conflict_target: [:kind, :ref_id], returning: false)`. Compare returned count to `length(candidates)`; on mismatch log `failure_count:` and return `{:error, :partial_upsert_failure}` so Oban retries. Update the worker's `embed_and_upsert/2` to propagate the new error tuple. Add to `Embeddings` context a new `bulk_upsert/1` helper that wraps the `insert_all` call so the Repo boundary stays in the context.
- [x] [P2-T2][ecto] **W1 (part 1)** — add `Analytics.unsafe_list_insights_window_for_ads/2` (ad_ids, window_days) returning `%{ad_id => [rows]}` (single query: `where: i.ad_id in ^ad_ids and i.date_start >= ^cutoff`, group in Elixir). `unsafe_` prefix because it skips tenant scope; worker callers are responsible.
- [x] [P2-T3][ecto] **W1 (part 2)** — split `Analytics.fit_ctr_regression/1` and `Analytics.get_ad_honeymoon_baseline/1` into a public arity-1 (legacy single-ad path, queries DB) AND a public arity-2 that accepts pre-fetched `insights_daily` rows. Internal `do_fit_regression`/`compute_honeymoon_baseline` already operate on rows — just expose a parallel entry point.
- [x] [P2-T4][oban] **W1 (part 3)** — update `CreativeFatiguePredictorWorker.audit_account/1` ([creative_fatigue_predictor_worker.ex:216](lib/ad_butler/workers/creative_fatigue_predictor_worker.ex#L216)) to call `Analytics.unsafe_list_insights_window_for_ads(ad_ids, 14)` once and pass per-ad slices into `heuristic_predicted_fatigue/1` and the regression/baseline functions. Update `heuristic_predicted_fatigue/2` signature to accept the row slice. Other heuristics (`heuristic_frequency_ctr_decay/1`, etc.) keep their solo signatures — only the predictive path is bulk-fetched.
- [x] [P2-T5][oban] **W6** — rename `ad_id:` to `ref_id:` in the upsert-failure log at [embeddings_refresh_worker.ex:133](lib/ad_butler/workers/embeddings_refresh_worker.ex#L133); add `:ref_id` to the metadata allowlist at [config/config.exs:90](config/config.exs#L90).
- [x] [P2-T6][oban] **W4** — handle `{:error, :rate_limit}` (and any ReqLLM rate-limit error shape — verify by checking `deps/req_llm`) in `EmbeddingsRefreshWorker.embed_and_upsert/2` ([embeddings_refresh_worker.ex:91-109](lib/ad_butler/workers/embeddings_refresh_worker.ex#L91-L109)) by returning `{:snooze, 90}` instead of `{:error, _}` so attempts aren't burned in the OpenAI 60s rate-limit window.
- [x] [P2-T7][oban] **W3** — change `unique: [period: 3_600, ...]` to `unique: [period: 82_800, ...]` (23h) in [fatigue_nightly_refit_worker.ex:16](lib/ad_butler/workers/fatigue_nightly_refit_worker.ex#L16). Matches the daily cron intent and the `DigestSchedulerWorker`/`AuditSchedulerWorker` patterns.
- [x] [P2-T8][oban] **W5** — change `unique: [period: 1_500, ...]` to `unique: [period: 1_680, ...]` (28 min) in [embeddings_refresh_worker.ex:24](lib/ad_butler/workers/embeddings_refresh_worker.ex#L24).
- [x] [P2-T9][oban] **S7** — fix the inverted `count`/`expected` log labels at [embeddings_refresh_worker.ex:103-108](lib/ad_butler/workers/embeddings_refresh_worker.ex#L103-L108). `count:` is what was sent (already correct semantics); `expected:` should be `vectors_received:` since it's what came back from the service. Add `:vectors_received` to the allowlist.
- [x] [P2-T10][ecto] **W2** — document on `Analytics.bulk_insert_fatigue_scores/1`'s `@doc` ([analytics.ex:194](lib/ad_butler/analytics.ex#L194)) that `:metadata` is replaced unconditionally on conflict and callers must carry forward existing metadata or accept that nil clears the cache. Verify `CreativeFatiguePredictorWorker.build_entry/4` ([creative_fatigue_predictor_worker.ex:276](lib/ad_butler/workers/creative_fatigue_predictor_worker.ex#L276)) always sets `:metadata` — if the honeymoon baseline returns `:insufficient_data`, store `%{}` (preserves the dict; subsequent runs can populate). If it does, no code change is needed beyond the doc.

### Phase 3 — Embeddings API hardening (forward-looking gates for W9)

These don't change today's behavior but lock the API down before the Week 9 chat tools start calling `Embeddings.nearest/3`.

- [x] [P3-T1][ecto] **W10** — add a `@valid_kinds ~w(ad finding doc_chunk)` module attribute to `AdButler.Embeddings` ([embeddings.ex](lib/ad_butler/embeddings.ex)). Add `when kind in @valid_kinds` guard to `nearest/3` and `list_ref_id_hashes/1`. Mirrors `Embedding.@kinds` and the DB CHECK.
- [x] [P3-T2][ecto] **W11** — add `@max_nearest_limit 50` to `AdButler.Embeddings` and clamp via `min(limit, @max_nearest_limit)` in `nearest/3`. Document the ceiling in the moduledoc.
- [x] [P3-T3][ecto] **W12** — add a docstring contract to `Embedding.content_excerpt` ([embedding.ex:29](lib/ad_butler/embeddings/embedding.ex#L29)): "never write user-typed PII; conversation content must use a separate Cloak'd kind." (No code change.)

### Phase 4 — Test coverage + cleanup

Tenant isolation + test brittleness items. Some are PERSISTENT from week 7.

- [x] [P4-T1][test] **B2** — add a `describe "tenant isolation"` block to [embeddings_refresh_worker_test.exs](test/ad_butler/workers/embeddings_refresh_worker_test.exs) with a two-tenant test: insert ads under two `meta_connection` owners, run `EmbeddingsRefreshWorker.perform/1`, assert `Embeddings.list_ref_id_hashes("ad")` contains both ad ids. Documents the deliberate cross-tenant invariant.
- [x] [P4-T2][test] **S5** — add `@moduletag :integration` to [week8_e2e_smoke_test.exs:1](test/ad_butler/integration/week8_e2e_smoke_test.exs#L1). Also decide convention: either move to `test/integration/` or document the `test/ad_butler/integration/` split with a one-liner in test_helper.exs / README.
- [x] [P4-T3][test] **S6** (PERSISTENT) — extract the 5 describes in [analytics_test.exs](test/ad_butler/analytics_test.exs) that call `create_insights_partition` (`compute_ctr_slope/2 / get_7d_frequency/1`, `get_7d_frequency/1`, `get_cpm_change_pct/1`, `get_ad_honeymoon_baseline/1`, `fit_ctr_regression/1`) into a new `test/ad_butler/analytics_insights_test.exs` with `use AdButler.DataCase, async: false`. Carries from week 7.
- [x] [P4-T4][test] **S1** — replace the hardcoded `"#{ad.name} | "` content format in [embeddings_refresh_worker_test.exs:71](test/ad_butler/workers/embeddings_refresh_worker_test.exs#L71) with a call to a (newly-extracted) `EmbeddingsRefreshWorker.ad_content/1` public helper, OR assert the diff via `Embeddings.list_ref_id_hashes/1` so the test fails loudly if the worker's content format ever changes.
- [x] [P4-T5][test] **S2** — strengthen the `nearest/3` limit test at [embeddings_test.exs:167](test/ad_butler/embeddings_test.exs#L167) to assert WHICH 2 rows return (closest + second-closest), not just `length == 2`.
- [x] [P4-T6][test] **S3** — document the ads-before-findings batch ordering contract at [embeddings_refresh_worker_test.exs:39-49](test/ad_butler/workers/embeddings_refresh_worker_test.exs#L39-L49) in a test comment. Alternative: restructure with `stub_with` and DB-only assertions if the ordering coupling becomes a maintenance burden.
- [x] [P4-T7][test] **S4** — tighten [analytics_test.exs:673](test/ad_butler/analytics_test.exs#L673) `slope < 0.0` to `slope < -0.001` so a vanishing slope on near-noise data fails the assertion.

### Phase 5 — Polish + hardening

- [x] [P5-T1] **S9a** — add `"api_key"`, `"openai_api_key"`, `"anthropic_api_key"` to `:filter_parameters` in [config/config.exs:144](config/config.exs#L144) (Phoenix Plug.Logger param redaction).
- [x] [P5-T2] **S9b** — add a one-line comment above `doc_ref_id/1` in [lib/mix/tasks/ad_butler.seed_help_docs.ex:93-96](lib/mix/tasks/ad_butler.seed_help_docs.ex#L93-L96) explaining the `SHA-256("doc_chunk:" <> filename) → first 16 bytes → UUID` derivation and why stability matters for the `(kind, ref_id)` upsert invariant.
- [x] [P5-T3] **S9c** — add a flag-for-future TODO comment in [embeddings.ex](lib/ad_butler/embeddings.ex) near `nearest/3` noting that per-kind partial HNSW indexes (`WHERE kind = 'ad'`) become worthwhile at >50k rows per kind.

## Final Verification

- [x] [VF-T1] `mix compile --warnings-as-errors` clean
- [x] [VF-T2] `mix format --check-formatted` clean
- [x] [VF-T3] `mix credo --strict` clean across all 141+ files
- [x] [VF-T4] `mix check.unsafe_callers` clean
- [x] [VF-T5] `mix test` 100% green (≥438 tests, plus 1 new tenant-isolation test → expect 439+)
- [x] [VF-T6] Roll the embeddings migration back+forward (`mix ecto.rollback --to 20260501000001 && mix ecto.migrate`) to verify P1-T1's CHECK constraint refactor is reversible
- [x] [VF-T7] Smoke-run [week8_e2e_smoke_test.exs](test/ad_butler/integration/week8_e2e_smoke_test.exs) once it carries `@moduletag :integration`: `mix test --only integration test/ad_butler/integration/week8_e2e_smoke_test.exs`

## Risks

- **W1 (predictor N+1) is the most invasive change** — splitting `fit_ctr_regression`/`get_ad_honeymoon_baseline` into row-accepting variants touches the public Analytics API. Existing tests rely on the arity-1 form; keep backward compatibility via delegation. If the refactor cascades, fall back to leaving the per-ad path and adding a TODO instead.
- **B1's `Repo.insert_all` change** moves the `Repo` call from the context (`Embeddings.upsert/1`) into the worker — violates the Repo-boundary Iron Law. Mitigation: introduce `Embeddings.bulk_upsert/1` as a context wrapper so Repo stays inside.
- **P1-T1 migration refactor** — the existing migration has already been applied locally. Either: (a) rollback to before T1, edit T1, re-apply; or (b) leave T1 as-is and add T1-prime (a new migration to drop and re-create the constraint). The plan currently assumes (a) since the migration is uncommitted; if it's already in shared environments use (b).

## Files Modified Summary

| File | Phase tasks |
|---|---|
| `priv/repo/migrations/20260501000002_create_embeddings.exs` | P1-T1, P1-T2, P1-T4 |
| `lib/ad_butler/embeddings/embedding.ex` | P1-T3, P3-T3 |
| `lib/ad_butler/embeddings.ex` | P2-T1 (bulk_upsert helper), P3-T1, P3-T2, P5-T3 |
| `lib/ad_butler/workers/embeddings_refresh_worker.ex` | P2-T1, P2-T5, P2-T6, P2-T8, P2-T9 |
| `lib/ad_butler/workers/fatigue_nightly_refit_worker.ex` | P2-T7 |
| `lib/ad_butler/workers/creative_fatigue_predictor_worker.ex` | P2-T4 |
| `lib/ad_butler/analytics.ex` | P2-T2, P2-T3, P2-T10 |
| `config/config.exs` | P2-T5 (`:ref_id` allowlist), P2-T9 (`:vectors_received` allowlist), P5-T1 (filter_parameters) |
| `lib/mix/tasks/ad_butler.seed_help_docs.ex` | P5-T2 |
| `test/ad_butler/embeddings_test.exs` | P4-T5 |
| `test/ad_butler/workers/embeddings_refresh_worker_test.exs` | P4-T1, P4-T4, P4-T6 |
| `test/ad_butler/analytics_test.exs` | P4-T7 |
| `test/ad_butler/integration/week8_e2e_smoke_test.exs` | P4-T2 |
| `test/ad_butler/analytics_insights_test.exs` (NEW) | P4-T3 |
