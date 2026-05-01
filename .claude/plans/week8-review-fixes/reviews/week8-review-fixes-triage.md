# Triage — week8-review-fixes (post-/phx:review)

**Source:** [week8-review-fixes-review.md](week8-review-fixes-review.md)
**Decision:** Fix all 14 findings in this round (1 BLOCKER + 4 WARNINGs + 2 pre-existing + 8 SUGGESTIONs).
**Approach:** Single follow-up PR addressing the full review backlog before merging the v0.3 + Week 8 + Week 8 review-fixes work.

## Fix Queue

### BLOCKER

- [ ] **B1 (ECTO)** — Add `null: false` to embedding column.
  - File: [priv/repo/migrations/20260501000002_create_embeddings.exs:14](priv/repo/migrations/20260501000002_create_embeddings.exs#L14)
  - Change: `add :embedding, :vector, size: 1536` → `add :embedding, :vector, size: 1536, null: false`
  - Why: `bulk_upsert/1` bypasses changeset; nil vector would crash `nearest/3` at runtime.
  - Migration is unreleased — safe to amend in place.

### WARNINGs

- [ ] **Testing W2 (PERSISTENT)** — Decouple hash tests from `ad_content/1`.
  - File: [test/ad_butler/workers/embeddings_refresh_worker_test.exs:74, 96, 127](test/ad_butler/workers/embeddings_refresh_worker_test.exs#L74)
  - Change: derive expected hashes from raw string literals (e.g., `"#{ad.name} | "`) instead of `EmbeddingsRefreshWorker.ad_content/1`.
  - Why: tests should anchor the contract, not chase it. The new `describe "ad_content/1"` block (lines 202–225) already locks the format string.

- [ ] **Sec WARN-1** — Add `Embeddings.scrub_for_user/1` helper.
  - File: [lib/ad_butler/embeddings.ex](lib/ad_butler/embeddings.ex)
  - Change: add `scrub_for_user([Embedding.t()]) :: [Embedding.t()]` that nils `content_excerpt` for `kind != "doc_chunk"`.
  - Why: enforces in code what the moduledoc only documents. Eliminates "forget to scrub" risk for the first W9 chat-tool PR.
  - Add a `describe "scrub_for_user/1"` test block to [test/ad_butler/embeddings_test.exs](test/ad_butler/embeddings_test.exs).

- [ ] **Testing W1** — Strengthen smoke-test drain assertion.
  - File: [test/ad_butler/integration/week8_e2e_smoke_test.exs:88](test/ad_butler/integration/week8_e2e_smoke_test.exs#L88)
  - Change: `assert %{success: success, failure: 0} = Oban.drain_queue(queue: :fatigue_audit); assert success >= 1`
  - Why: keeps the loose-success-count tradeoff (factory chain creates incidental ad_accounts) but adds a floor so a future regression that no-ops the chain fails the test.

- [ ] **Ecto W1 (PRE-EXISTING)** — Add FK constraint to `AdHealthScore.ad_id`.
  - File: [lib/ad_butler/analytics/ad_health_score.ex:26](lib/ad_butler/analytics/ad_health_score.ex#L26)
  - Change: switch `field :ad_id, :binary_id` → `belongs_to :ad, AdButler.Ads.Ad`. Confirm migration FK has `on_delete:`.
  - Why: prevents orphan health-score rows. PRE-EXISTING item but worth folding in since we're touching nearby code.
  - Verify the existing migration has `references(:ads, on_delete: :delete_all)` (or similar). If not, add a new migration to add the FK.

### Pre-existing items (now in scope per user)

- [ ] **Snooze comment fix** — `lib/ad_butler/workers/embeddings_refresh_worker.ex:162`
  - Comment claims "Oban auto-bumps max_attempts on snooze" — false for standard OSS.
  - Replace with accurate comment: snoozes consume an attempt; the 90s buffer keeps us outside the typical 60s rate-limit window so one snooze is usually enough.

- [ ] **EmbeddingsRefreshWorker timeout/1** — add `def timeout(_job), do: :timer.minutes(5)` to the worker.
  - Why: worker has no explicit timeout; lifeline currently rescues at 30 min. 5 min is appropriate for the sequential Repo + HTTP work.

### SUGGESTIONS (cosmetic / consistency)

- [ ] **Sec SUG-1** — `lib/mix/tasks/ad_butler.seed_help_docs.ex:48-63`
  - Wrap `Path.wildcard` results with `Path.safe_relative/2` against `Application.app_dir(:ad_butler, "priv/embeddings/help")` to defend against future symlinks.

- [ ] **Sec SUG-2** — `lib/ad_butler/embeddings.ex:179`
  - Add `# safe: doc_chunk is admin-curated only — see seed_help_docs.ex` near the doc_chunk split so a future user-writable source forces a re-audit.

- [ ] **Ecto S1** — `lib/ad_butler/embeddings/embedding.ex:50`
  - Use module-level `@timestamps_opts [type: :utc_datetime_usec]` (matches every other schema in the codebase). Drop the inline `type:` arg from `timestamps/1`.

- [ ] **Ecto S2** — `priv/repo/migrations/20260501000003_add_embeddings_hnsw_index.exs:20`
  - Add inline comment that `DROP INDEX CONCURRENTLY` also requires `@disable_ddl_transaction true` (already set; just clarify for future copy/paste).

- [ ] **Elixir S1** — `lib/ad_butler/analytics.ex:374-375, 693-694, 824-825`
  - Replace `Enum.sum(Enum.map(list, & &1.field))` with `Enum.sum_by(list, & &1.field)` (Elixir 1.18+).

- [ ] **Elixir S2** — `lib/ad_butler/analytics.ex:371, 475, 690`
  - Replace `length(qualifying)` (in threshold guards) with `Enum.count(qualifying)` for intent-signaling on bounded lists.

- [ ] **Testing S1** — `test/ad_butler/workers/embeddings_refresh_worker_test.exs:135`
  - Rename describe `"perform/1 — tenant isolation"` → `"perform/1 — cross-tenant embedding (by design)"`.

- [ ] **Testing S3** — `test/ad_butler/embeddings_test.exs:105–130`
  - First `nearest/3` ordering test uses `shifted_vector` with small offsets. Switch to `partial_ones` (per the existing solution doc) for wider distance gaps, OR add a comment acknowledging HNSW approximation risk.

## Skipped

None. User approved every selectable finding.

## Deferred

None. All pre-existing items selected for this round.

## Filtered (NOT in fix queue — stale agent claims, see review)

- ~~oban-specialist: `upsert_batch/3` missing `{:error, _}` arm~~ — `bulk_upsert/1` spec is `{:ok, _}` only; type checker rejects dead branch.
- ~~testing-reviewer: `analytics_insights_test.exs:99, 113` bare float `==`~~ — already replaced with `assert_in_delta` in P7-T3.

## Counts

| Category | Count |
|---|---|
| BLOCKER | 1 |
| WARNING | 4 |
| Pre-existing (now in scope) | 2 |
| SUGGESTION | 8 |
| **Total fix queue** | **15** |
| Skipped | 0 |
| Deferred | 0 |
| Filtered (stale) | 2 |
