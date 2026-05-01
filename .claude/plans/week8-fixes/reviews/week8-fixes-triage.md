# Triage — week8-fixes review

**Date:** 2026-05-01
**Source:** [week8-fixes-review.md](week8-fixes-review.md)
**Status: 12 to fix, 8 skipped, 0 deferred.**

---

## Fix Queue

### Auto-approved (Iron Law / non-negotiable)

- [ ] **B1 — Repo boundary in `EmbeddingsRefreshWorker.build_candidates/2`** (Iron Law #1). Extract `Ads.unsafe_list_ads_with_creative_names/0` and `Analytics.unsafe_list_all_findings_for_embedding/0`; drop `Repo`/`Ad`/`Creative`/`Finding` aliases from the worker. [embeddings_refresh_worker.ex:53-64](lib/ad_butler/workers/embeddings_refresh_worker.ex#L53-L64)

### Correctness — BLOCKERs

- [ ] **B2 — `nearest/3` + `list_ref_id_hashes/1` invalid-kind handling**: Add fallback clauses returning `{:error, {:invalid_kind, kind}}`. Update `@spec` to `{:ok, [Embedding.t()]} | {:error, {:invalid_kind, String.t()}}` for `nearest/3` and `{:ok, %{binary() => String.t()}} | {:error, {:invalid_kind, String.t()}}` for `list_ref_id_hashes/1`. Update existing call sites that bind the bare list. [embeddings.ex:60-70, 78-85](lib/ad_butler/embeddings.ex#L60-L85)

- [ ] **B3 — `build_evidence/1` atom-key fragility**: Stringify the inner `:values` map immediately in `build_factors_map/1`, then update `build_evidence/1` and `format_predictive_clause/1` to read string keys. Delete the line-484 caveat comment. [creative_fatigue_predictor_worker.ex:407-418, 484-493](lib/ad_butler/workers/creative_fatigue_predictor_worker.ex#L407-L418)

### Worker / Iron Law — WARNINGs

- [ ] **W1 — Seed task uses `Embeddings.upsert/1` loop instead of `bulk_upsert/1`** (Iron Law #7/8). Replace `Enum.each` with one `bulk_upsert/1` call; check returned count vs `length(docs)`. [seed_help_docs.ex:72-89](lib/mix/tasks/ad_butler.seed_help_docs.ex#L72-L89)

- [ ] **W2 — Bare `{:ok, count} = Embeddings.bulk_upsert(rows)` match**: Replace with a `case` that handles both `{:ok, _}` and `{:error, _}` cleanly. [embeddings_refresh_worker.ex:179](lib/ad_butler/workers/embeddings_refresh_worker.ex#L179)

- [ ] **W3 — Rate-limit snooze on "ad" silently skips "finding"**: Run both kinds independently in `perform/1`, then reduce: snooze if either, error if either, else `:ok`. [embeddings_refresh_worker.ex:41-43](lib/ad_butler/workers/embeddings_refresh_worker.ex#L41-L43)

### Tests — WARNINGs

- [ ] **W4 — Tests couple to internal `EmbeddingsRefreshWorker.ad_content/1`**: Add a dedicated unit test for `ad_content/1` (anchor its contract), keeping the helper public. The existing tests can keep using it. [embeddings_refresh_worker_test.exs:74,96,127](test/ad_butler/workers/embeddings_refresh_worker_test.exs#L74)

- [ ] **W5 — `week8_e2e_smoke_test` `@moduledoc` describes a chain the test doesn't exercise**: Add `perform_job(FatigueNightlyRefitWorker, %{})` + `assert_enqueued worker: CreativeFatiguePredictorWorker` so the moduledoc's claimed sequence is actually validated. [week8_e2e_smoke_test.exs:3-14, 73](test/ad_butler/integration/week8_e2e_smoke_test.exs#L3-L14)

- [ ] **W9 — Float `==` on `get_7d_frequency/1`** (PERSISTENT): `assert_in_delta result, 4.0, 0.0001` instead of `==`. [analytics_insights_test.exs:99,113](test/ad_butler/analytics_insights_test.exs#L99)

### Security — forward-looking (chose to fix now)

- [ ] **W6 — `nearest/3` tenant-filter helper**: Add `AdButler.Chat.tenant_filter_embedding_results/2` (or pick a context that exists) that takes `[Embedding.t()]` + `%User{}` and returns only embeddings whose `ref_id` resolves through the user's scoped contexts (`Ads.list_ad_account_ids_for_user/1` for kind="ad", `Analytics.get_finding/2` for kind="finding", pass-through for kind="doc_chunk"). Don't wire any caller yet (W9 PR will). Document the helper as the *required* path before exposing kNN results. [embeddings.ex:104-116](lib/ad_butler/embeddings.ex#L104-L116)

- [ ] **W7 — `content_excerpt` advertiser-PII contract**: Tighten `Embedding`'s moduledoc to explicitly acknowledge advertiser-typed strings (ad/creative names) can carry third-party PII, and document the rule that `content_excerpt` must be dropped for `kind` ∈ {"ad", "finding"} before user-facing render. [embedding.ex:17-19](lib/ad_butler/embeddings/embedding.ex#L17-L19)

### Style — WARNING

- [ ] **W8 — `if latest_score == nil` → `is_nil/1`** for codebase consistency. [creative_fatigue_predictor_worker.ex:161](lib/ad_butler/workers/creative_fatigue_predictor_worker.ex#L161)

---

## Skipped (8 — all SUGGESTIONs)

- `:embeddings_model` config-key wiring (currently falls through to default; works fine).
- `Enum.flat_map` → `for` comprehension in `filter_to_changed/3` (style nit).
- `PostgrexTypes` `@moduledoc` clarification comment (low value).
- `EmbeddingsRefreshWorker.timeout/1` callback (`max_attempts: 3` + Lifeline 30 min covers the hung-connection case in practice).
- Rename `"tenant isolation"` describe to `"cross-tenant by design"` (current comment block already explains).
- Split `"compute_ctr_slope/2 / get_7d_frequency/1"` describe heading.
- `Path.safe_relative` defense in seed_help_docs (priv/ is dev-controlled).
- Inline comment `# safe: Finding has no token/PII fields` on changeset.errors log.

---

## Deferred

(none — W6/W7 chosen to land in this batch rather than at first W9 PR)

---

## User context captured

- B2: chose the `{:error, :invalid_kind}` fallback path (more defensive; callers must handle the tagged tuple).
- W6/W7: chose to land the helper + docstring tightening in this batch rather than at first W9 PR — cheap forward-looking work.
- "Just fix them all per the review" — use suggested fixes verbatim, no special direction beyond the choices above.
