# Consolidated Review — week8-review-fixes

**Verdict:** REQUIRES CHANGES — 1 BLOCKER (1-line migration fix), 4 WARNINGs (3 deferrable), Suggestions clean.

**Scope:** All v0.3 + Week 8 + Week 8 review-fixes work vs `main` (~30 files).

**Verification:** PASS — 449 tests, 0 failures; credo --strict clean; format clean; check.unsafe_callers clean.

---

## Counts by severity

| Severity | Count | Status |
|---|---|---|
| BLOCKER | 1 | Ecto B1 — `null: false` missing |
| WARNING | 4 | 1 actionable now (Testing W2 PERSISTENT), 1 deferred-to-W9 (Sec WARN-1), 1 plan-acknowledged tradeoff (Testing W1), 1 PRE-EXISTING (Ecto W1) |
| SUGGESTION | 7 | Cosmetic/consistency |
| Iron Law violations | 0 | Pass |

---

## BLOCKER

### B1 — `embedding` column missing `null: false`

**File:** [priv/repo/migrations/20260501000002_create_embeddings.exs:14](priv/repo/migrations/20260501000002_create_embeddings.exs#L14)

```elixir
add :embedding, :vector, size: 1536  # ← needs null: false
```

`Embeddings.bulk_upsert/1` calls `Repo.insert_all/3` which bypasses the changeset — the schema's `validate_required([:embedding, ...])` does NOT run. A nil-vector row could land in the table and would crash `nearest/3` at runtime when pgvector tries to compute cosine distance against `NULL`.

**Fix:** one line —
```elixir
add :embedding, :vector, size: 1536, null: false
```

Migration is unreleased — safe to amend in place.

---

## WARNINGS (deferrable, with caveats)

### Sec WARN-1 (release-gate for W9 chat-tool PR) — `content_excerpt` not scrubbed for user-facing surfaces

**File:** [lib/ad_butler/embeddings/embedding.ex:19-32](lib/ad_butler/embeddings/embedding.ex#L19-L32)

Moduledoc documents the rule but no code enforces it. Add `Embeddings.scrub_for_user/1` (nils `content_excerpt` for `kind != "doc_chunk"`) OR drop the field from user-facing projections in the first W9 chat-tool PR. **Defer to W9 plan.**

### Testing W2 (PERSISTENT) — hash-comparison tests couple to `ad_content/1` helper

**File:** [test/ad_butler/workers/embeddings_refresh_worker_test.exs:74, 96, 127](test/ad_butler/workers/embeddings_refresh_worker_test.exs#L74)

Expected hashes are derived by calling the worker's own helper, so the test cannot catch content-format regressions. The new `ad_content/1` unit tests at lines 202–225 anchor the contract; the hash tests should derive expected values from raw string literals (e.g., `"#{ad.name} | "`) instead. Worth fixing in this cycle — small change.

### Testing W1 (plan-acknowledged) — `drain_queue` asserts `failure: 0` only

**File:** [test/ad_butler/integration/week8_e2e_smoke_test.exs:88](test/ad_butler/integration/week8_e2e_smoke_test.exs#L88)

Plan explicitly relaxed this because the factory chain creates incidental ad_accounts (variable success count). Could strengthen to `assert success >= 1` without locking exact count.

### Ecto W1 (PRE-EXISTING, not introduced here) — `AdHealthScore.ad_id` is bare `field`, not `belongs_to`

**File:** [lib/ad_butler/analytics/ad_health_score.ex:26](lib/ad_butler/analytics/ad_health_score.ex#L26)

No `foreign_key_constraint(:ad_id)` in changeset. Either switch to `belongs_to :ad, AdButler.Ads.Ad` or add the constraint explicitly. Predates this plan; track separately.

---

## Suggestions (cosmetic / consistency)

- **Sec SUG-1**: `seed_help_docs.ex:48-63` — wrap `Path.wildcard` with `Path.safe_relative/2` (defend against future symlinks).
- **Sec SUG-2**: `embeddings.ex:179` — add a `# safe: doc_chunk admin-curated only — see seed_help_docs.ex` comment.
- **Ecto S1**: `embedding.ex:50` — use module-level `@timestamps_opts [type: :utc_datetime_usec]` for consistency with other schemas.
- **Ecto S2**: `20260501000003_add_embeddings_hnsw_index.exs:20` — add comment that `DOWN` also needs `@disable_ddl_transaction true` (already set).
- **Elixir S1**: `analytics.ex:374-375, 693-694, 824-825` — `Enum.sum_by/2` (Elixir 1.18+) instead of `Enum.sum(Enum.map(...))`.
- **Elixir S2**: `analytics.ex:371, 475, 690` — `Enum.count/1` instead of `length/1` for intent-signaling on bounded lists.
- **Testing S1**: rename `embeddings_refresh_worker_test.exs:135` describe to `"perform/1 — cross-tenant embedding (by design)"`.
- **Testing S3**: `embeddings_test.exs:105–130` — switch first ordering test to `partial_ones` (matches solution doc).

---

## Filtered findings (stale — NOT actionable)

| Agent | Claim | Reality |
|---|---|---|
| oban-specialist | `upsert_batch/3` missing `{:error, _}` arm | `Embeddings.bulk_upsert/1` spec is `{:ok, _}` only — Elixir 1.18 type checker rejects the dead branch (verified during work phase). |
| testing-reviewer | `analytics_insights_test.exs:99, 113` bare float `==` is PERSISTENT | Both lines now use `assert_in_delta` (P7-T3). Agent had stale context. |

---

## Pre-existing (out of scope)

- `lib/ad_butler/workers/embeddings_refresh_worker.ex:162` — comment incorrectly claims "Oban auto-bumps max_attempts on snooze." Already tracked in scratchpad; defer to a separate small PR.
- No `timeout/1` on `EmbeddingsRefreshWorker` — recommend `def timeout(_job), do: :timer.minutes(5)`. Low severity.

---

## What changed since prior review (`week8-fixes-triage.md`)

All 12 triaged items resolved (3 BLOCKER, 9 WARNING) — see [.claude/plans/week8-review-fixes/plan.md](.claude/plans/week8-review-fixes/plan.md) (28 tasks ✓). Two new solution docs captured during the work cycle:

- `.claude/solutions/ecto/per-kind-tenant-filter-after-knn-fail-closed-20260501.md`
- `.claude/solutions/oban/error-precedence-over-snooze-in-multi-step-perform-20260501.md`

---

## Recommendation

The single BLOCKER is a one-line migration tweak. After applying, re-run `mix test` and the codebase ships. The Testing W2 (hash tests) is also worth addressing in the same change since it's small and improves regression coverage. Other warnings can be batched into a follow-up PR (W9 prep + pre-existing AdHealthScore FK).
