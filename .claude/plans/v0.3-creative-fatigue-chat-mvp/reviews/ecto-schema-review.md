# Week 8 Ecto Schema + Migration Review

⚠️ EXTRACTED FROM AGENT MESSAGE (Write was denied for the agent)

Scope: `20260501000001–3`, `embedding.ex`, `ad_health_score.ex`, `analytics.ex` (`bulk_insert_fatigue_scores/1`), `embeddings.ex`.

---

## BLOCKER — T2: CHECK constraint uses raw `execute` against project convention

`priv/repo/migrations/20260501000002_create_embeddings.exs:23-27`

Every existing CHECK constraint in this codebase uses `create constraint(:table, :name, check: "...")` — see `20260420155228_create_llm_usage.exs:30-46`, `20260420155107_create_meta_connections.exs:20`, `20260420155227_create_user_quotas.exs:29`. The embeddings migration instead calls raw `execute "ALTER TABLE embeddings ADD CONSTRAINT ..."`. This is convention drift and bypasses Ecto's reversible constraint DSL.

**Fix:**
```elixir
create constraint(:embeddings, :embeddings_kind_check,
  check: "kind IN ('ad', 'finding', 'doc_chunk')")
```
Remove the raw `execute` block. `down/0` needs no change (table drop removes it).

---

## CLEARED — T3 concurrency flags

`priv/repo/migrations/20260501000003_add_embeddings_hnsw_index.exs:7-8`

T3 has both `@disable_ddl_transaction true` and `@disable_migration_lock true`, matching `20260427000002_create_findings.exs`. T2 uses `create unique_index` (not CONCURRENTLY) so it needs no flags. No issue.

---

## WARNING — T2 `down/0` drops extension; breaks if a second vector table is added later

`priv/repo/migrations/20260501000002_create_embeddings.exs:30-33`

```elixir
def down do
  drop table(:embeddings)
  execute "DROP EXTENSION IF EXISTS vector"
end
```

Safe now (only one `vector` column). If a future migration adds another `vector` column and T2 is rolled back, `DROP EXTENSION` will fail or cascade-drop. Document inside `down/0` so the author of the next vector column knows to update it.

---

## WARNING — `validate_length(:content_hash, is: 64)` doesn't enforce hex characters

`lib/ad_butler/embeddings/embedding.ex:51`

A 64-character non-hex string passes. `hash_content/1` always produces lowercase hex, so the gap only opens if a caller bypasses the helper.

**Fix:** Replace with `validate_format(:content_hash, ~r/\A[0-9a-f]{64}\z/)`.

---

## WARNING — `bulk_insert_fatigue_scores/1` can clobber existing `:metadata` with nil

`lib/ad_butler/analytics.ex:207`

`on_conflict: {:replace, [:fatigue_score, :fatigue_factors, :metadata, :inserted_at]}` replaces `:metadata` unconditionally. If a retry or parallel run produces an entry without `:metadata` (nil), it overwrites a stored honeymoon baseline. Same-bucket collision is rare given the 6h `computed_at` design, but the `@doc` is silent.

**Fix:** Document explicitly that callers must either carry forward the existing `metadata` value or accept that nil clears it. The cache-lookup path in `cached_honeymoon_baseline/1` reads from this column — a nil overwrite forces an unnecessary `insights_daily` recompute on the next audit.

---

## SUGGESTION — HNSW index unused for `kind`-filtered queries at scale

`lib/ad_butler/embeddings.ex:65-69`

HNSW index is on `(embedding vector_cosine_ops)` only. The `WHERE kind = ^kind` predicate is not pushed into the index. PostgreSQL executes a sequential scan filtered by `kind`, then applies distance order. For <1k rows per kind this is faster than HNSW anyway. At >50k rows per kind, per-kind partial HNSW indexes (`WHERE kind = 'ad'`) would be needed. Flag for future.

---

## SUGGESTION — Vector dimension 1536 not documented at migration or schema level

`priv/repo/migrations/20260501000002_create_embeddings.exs:13`

Embeddings moduledoc mentions HNSW parameters but not the model name. Migration comment is silent.

**Fix:** Add comment: `# 1536 = OpenAI text-embedding-3-small; dimension change requires a new migration`.

---

## CLEARED — `Pgvector.new/1` vs plain list in tests

`lib/ad_butler/embeddings.ex:62`, `test/ad_butler/embeddings_test.exs:127`

Tests pass plain float lists to `upsert/1` — `Pgvector.Ecto.Vector` casts them transparently. `nearest/3` wraps in `Pgvector.new/1` explicitly before passing to the raw fragment (where Ecto's type system doesn't apply). Behavior is consistent and correct.

---

## Summary

| # | Severity | File:line | Issue |
|---|----------|-----------|-------|
| 1 | BLOCKER | `20260501000002:23-27` | Raw `execute` for CHECK; use `create constraint/3` per project convention |
| 2 | cleared | `20260501000003:7-8` | Both DDL flags present |
| 3 | WARNING | `20260501000002:30-33` | `down/0` drops extension; comment for future vector tables |
| 4 | WARNING | `embedding.ex:51` | `validate_length` passes non-hex; replace with hex regex |
| 5 | WARNING | `analytics.ex:207` | `on_conflict` replaces `:metadata` with nil on retry; document |
| 6 | SUGGESTION | `embeddings.ex:65-69` | HNSW index not engaged for `kind`-filtered ANN |
| 7 | SUGGESTION | `20260501000002:13` | Document model name + dim-change requirement |
| 8 | cleared | `embeddings.ex:62` | Pgvector.new vs plain list — consistent |

The one must-fix before merging is finding 1 (CHECK constraint convention). Findings 4 and 5 are low-risk given current call patterns but should be addressed before production.
