# Ecto + Migrations Review — week8-review-fixes

**Verdict:** CONDITIONAL PASS — 1 BLOCKER, 2 WARNINGS, 2 SUGGESTIONS

> ⚠️ Captured from ecto-schema-designer agent chat output (Write was denied).

## BLOCKER

### B1 — Missing `null: false` on `embedding` column

**File:** `priv/repo/migrations/20260501000002_create_embeddings.exs:14`

`add :embedding, :vector, size: 1536` has no `null: false`. The changeset marks `:embedding` as `@required`, but `bulk_upsert/1` bypasses the changeset (`Repo.insert_all` runs no changesets per the module docs). A row inserted via `bulk_upsert` with a nil embedding would land in the DB with no DB-level rejection. The `nearest/3` kNN query would then fail at runtime with a pgvector error when it hits the null-vector row. **Fix:** add `null: false`.

## Warnings

### W1 — `AdHealthScore` schema uses bare `field` for `ad_id` instead of `belongs_to`

**File:** `lib/ad_butler/analytics/ad_health_score.ex:26`

`field :ad_id, :binary_id` bypasses Ecto's association machinery and loses the `foreign_key_constraint/2` call in the changeset. Without the constraint, a deleted ad leaves orphan health-score rows with no DB-level protection. Either use `belongs_to :ad, AdButler.Ads.Ad` or add `foreign_key_constraint(changeset, :ad_id)` explicitly. *NOTE: this is PRE-EXISTING (not introduced by this plan).*

### W2 — `metadata` column on `ad_health_scores` is nullable with no default

**File:** `priv/repo/migrations/20260501000001_add_metadata_to_ad_health_scores.exs:10`

`add :metadata, :map` — no `default: %{}`. Callers pattern-matching on `score.metadata["key"]` would crash on `nil`. **NOTE:** the actual reader at `lib/ad_butler/analytics.ex:385-397` uses `with %AdHealthScore{metadata: %{"honeymoon_baseline" => ...}}` which gracefully falls through on nil metadata — so this is a defense-in-depth concern, not a current crash risk. Demoted from WARNING to SUGGESTION level in the consolidated view.

## Suggestions

### S1 — `@timestamps_opts` missing from `Embedding` schema

**File:** `lib/ad_butler/embeddings/embedding.ex:50`

`timestamps(type: :utc_datetime_usec)` works but deviates from the project convention of setting `@timestamps_opts [type: :utc_datetime_usec]` at the module level (every other schema in the codebase uses this). Minor consistency.

### S2 — HNSW migration `down` uses `CONCURRENTLY` on `DROP INDEX`

**File:** `priv/repo/migrations/20260501000003_add_embeddings_hnsw_index.exs:20`

`@disable_ddl_transaction true` already covers it, but worth a comment for future copy/paste.

## Summary table

| ID | Severity | File | Line | Issue |
|----|----------|------|------|-------|
| B1 | BLOCKER | `20260501000002_create_embeddings.exs` | 14 | `embedding` column missing `null: false`; bulk_upsert bypasses changeset |
| W1 | WARNING (PRE-EXISTING) | `ad_health_score.ex` | 26 | Bare `field :ad_id` — no `foreign_key_constraint` |
| W2 | SUGGESTION (after verification) | `20260501000001_add_metadata_to_ad_health_scores.exs` | 10 | `metadata` column has no default; readers handle nil safely |
| S1 | SUGGESTION | `embedding.ex` | 50 | Use module-level `@timestamps_opts` |
| S2 | SUGGESTION | `20260501000003_add_embeddings_hnsw_index.exs` | 20 | Comment that DOWN also needs `@disable_ddl_transaction` |
