# Week 8 Triage

Based on [week8-review.md](.claude/plans/v0.3-creative-fatigue-chat-mvp/reviews/week8-review.md). User chose to fix all findings using the suggested fixes from the review.

**Status: 23 to fix, 0 skipped, 0 deferred.**

---

## Fix Queue

### Auto-approved (Iron Law / CLAUDE.md non-negotiable)

- [ ] **B1 — `EmbeddingsRefreshWorker.upsert_batch/3`**: Replace `Enum.each` + per-row `Embeddings.upsert/1` with a single `Repo.insert_all(Embedding, rows, on_conflict: ..., conflict_target: [:kind, :ref_id])`. Compare returned count vs `length(candidates)` and return `{:error, :partial_upsert_failure}` when they differ. Log `failure_count:`. Fixes both N+1 (Iron Law #15) and silent-failure issues. [embeddings_refresh_worker.ex:118-138](lib/ad_butler/workers/embeddings_refresh_worker.ex#L118-L138)
- [ ] **B2 — Tenant-isolation test for `EmbeddingsRefreshWorker`**: Add a two-tenant test inserting ads under two `meta_connection` owners; run worker; assert embeddings exist for both — encoding the deliberate cross-tenant invariant. [test/ad_butler/workers/embeddings_refresh_worker_test.exs](test/ad_butler/workers/embeddings_refresh_worker_test.exs)
- [ ] **W1 — `heuristic_predicted_fatigue/1` N+1**: Pre-batch the 14-day `insights_daily` window with `ad_id IN ^ad_ids` once per audit, group by ad_id in Elixir, pass pre-grouped rows into `fit_ctr_regression/1` (Iron Law #14). [creative_fatigue_predictor_worker.ex:256-275](lib/ad_butler/workers/creative_fatigue_predictor_worker.ex#L256-L275)
- [ ] **W6 — Misleading `ad_id:` log key**: Rename to `ref_id:` in upsert-failure log; add `:ref_id` to the `config/config.exs` allowlist. [embeddings_refresh_worker.ex:133](lib/ad_butler/workers/embeddings_refresh_worker.ex#L133)

### Architecture / Data integrity

- [ ] **W2 — `bulk_insert_fatigue_scores/1` metadata clobber on retry**: Document in `@doc` that callers must carry forward existing metadata or accept that nil clears the cache. Verify worker always sets `:metadata` (even when honeymoon baseline is `:insufficient_data`, write `%{}` or fetch+merge). [analytics.ex:207](lib/ad_butler/analytics.ex#L207)

### Operational / Worker tuning

- [ ] **W3 — `FatigueNightlyRefitWorker` unique window**: Change `period: 3_600` to `period: 82_800` (23h). Match `DigestSchedulerWorker` / `AuditSchedulerWorker` pattern. [fatigue_nightly_refit_worker.ex:16](lib/ad_butler/workers/fatigue_nightly_refit_worker.ex#L16)
- [ ] **W4 — Oban backoff thrashes on rate limits**: When `Embeddings.Service.embed/1` returns `{:error, :rate_limit}` (or any error matching ReqLLM's rate-limit shape), return `{:snooze, 90}` instead of `{:error, _}` so attempts aren't burned in the 60s rate-limit window. [embeddings_refresh_worker.ex:21](lib/ad_butler/workers/embeddings_refresh_worker.ex#L21)
- [ ] **W5 — Unique window vs cron interval**: Widen `period: 1_500` to `period: 1_680` (28 min) to prevent first-deploy backfill double-billing. [embeddings_refresh_worker.ex:24](lib/ad_butler/workers/embeddings_refresh_worker.ex#L24)

### Schema / migrations

- [ ] **W7 — CHECK constraint via raw execute**: Replace raw `execute "ALTER TABLE..."` with `create constraint(:embeddings, :embeddings_kind_check, check: "kind IN ('ad', 'finding', 'doc_chunk')")`. [20260501000002_create_embeddings.exs:23-27](priv/repo/migrations/20260501000002_create_embeddings.exs#L23-L27)
- [ ] **W8 — `down/0` drops vector extension**: Add an inline comment in `down/0` flagging that future vector columns require updating this rollback. [20260501000002_create_embeddings.exs:30-33](priv/repo/migrations/20260501000002_create_embeddings.exs#L30-L33)
- [ ] **W9 — `content_hash` hex validation**: Replace `validate_length(:content_hash, is: 64)` with `validate_format(:content_hash, ~r/\A[0-9a-f]{64}\z/)`. [embedding.ex:51](lib/ad_butler/embeddings/embedding.ex#L51)

### Forward-looking security gates (release prerequisites for W9)

- [ ] **W10 — `Embeddings.nearest/3` kind allowlist**: Add `when kind in @valid_kinds` guard mirroring `Embedding.@kinds` and the DB CHECK. Apply same guard to `list_ref_id_hashes/1`. [embeddings.ex:60-70](lib/ad_butler/embeddings.ex#L60-L70)
- [ ] **W11 — `Embeddings.nearest/3` limit ceiling**: Clamp `limit` via `min(limit, @max_limit)` with `@max_limit 50`. [embeddings.ex:60](lib/ad_butler/embeddings.ex#L60)
- [ ] **W12 — `content_excerpt` PII contract**: Add a docstring contract on `Embedding.content_excerpt`: "never write PII; user-typed conversation content must use a separate Cloak'd kind." [embedding.ex:29](lib/ad_butler/embeddings/embedding.ex#L29)

### Suggestions (test brittleness + style)

- [ ] **S1 — Idempotency test hardcoded content format**: Replace the literal `"#{ad.name} | "` with a call to the worker's content function (or assert the diff via `Embeddings.list_ref_id_hashes/1` instead of recomputing). [embeddings_refresh_worker_test.exs:71](test/ad_butler/workers/embeddings_refresh_worker_test.exs#L71)
- [ ] **S2 — `nearest/3` limit test verifies row identities**: Assert which 2 rows are returned (closest+second-closest), not just `length == 2`. [embeddings_test.exs:167](test/ad_butler/embeddings_test.exs#L167)
- [ ] **S3 — `expect` ordering assumption**: Document the ads-before-findings batch ordering contract in a test comment, OR restructure with `stub_with` and DB-only assertions. [embeddings_refresh_worker_test.exs:39-49](test/ad_butler/workers/embeddings_refresh_worker_test.exs#L39-L49)
- [ ] **S4 — Tighten `slope < 0.0` lower bound**: Change to `< -0.001` so a vanishing slope on noisy data fails the assertion. [analytics_test.exs:673](test/ad_butler/analytics_test.exs#L673)
- [ ] **S5 — `@moduletag :integration` on smoke test**: Add to `week8_e2e_smoke_test.exs`. Decide whether to move to `test/integration/` or document the `test/ad_butler/integration/` convention split. [test/ad_butler/integration/week8_e2e_smoke_test.exs](test/ad_butler/integration/week8_e2e_smoke_test.exs)
- [ ] **S6 — Extract async-DDL describes**: Move the 5 describes calling `create_insights_partition` from `analytics_test.exs` (async: true) into `analytics_insights_test.exs` with `async: false`. PERSISTENT from week 7. [test/ad_butler/analytics_test.exs](test/ad_butler/analytics_test.exs)
- [ ] **S7 — Inverted `count`/`expected` log keys**: Swap labels (or rename `vectors_received`) in the vector-mismatch log. [embeddings_refresh_worker.ex:103-108](lib/ad_butler/workers/embeddings_refresh_worker.ex#L103-L108)
- [ ] **S8 — Document model dim invariant**: Add comment to migration: `# 1536 = OpenAI text-embedding-3-small; dimension change requires a new migration`. [20260501000002_create_embeddings.exs:13](priv/repo/migrations/20260501000002_create_embeddings.exs#L13)
- [ ] **S9 — Hardening trio**:
  - Add `"api_key"`, `"openai_api_key"`, `"anthropic_api_key"` to `config/config.exs` `:filter_parameters` (S9a)
  - Add a one-line comment above `doc_ref_id/1` in `lib/mix/tasks/ad_butler.seed_help_docs.ex` explaining the SHA-256 → 16-byte → UUID derivation and why stability matters for the conflict_target invariant (S9b)
  - HNSW per-kind partial index flag-for-future — comment-only TODO in `lib/ad_butler/embeddings.ex` near `nearest/3` (S9c)

---

## Skipped

(none)

---

## Deferred

(none)

---

## User context captured

- "Just fix them all" — use the suggested fixes from the review as-is, no special direction.
- All forward-looking security items (W10–W12) included rather than deferred to W9 PR.
- S6 (async DDL race) included rather than deferred — addressing the persistent week-7 issue alongside week 8 fixes.
