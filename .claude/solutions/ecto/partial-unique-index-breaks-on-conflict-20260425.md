---
module: "AdButler.Repo.Migrations"
date: "2026-04-25"
problem_type: database_issue
component: ecto_migration
symptoms:
  - "Postgrex.Error: there is no unique or exclusion constraint matching the ON CONFLICT specification"
  - "Ecto Repo.insert with on_conflict: :nothing and conflict_target: [:col] raises at runtime"
  - "Migration creates a unique index with a WHERE clause (partial index), but ON CONFLICT silently fails"
root_cause: "Ecto's conflict_target: [:col] generates ON CONFLICT (col) with no WHERE predicate. PostgreSQL requires the ON CONFLICT clause to include the exact WHERE predicate of a partial unique index. A non-matching predicate raises at query time."
severity: high
tags: [migration, unique-index, partial-index, on-conflict, idempotency, telemetry, ecto]
---

# Partial Unique Index Breaks `ON CONFLICT (col) DO NOTHING`

## Symptoms

```
%Postgrex.Error{
  postgres: %{
    code: :invalid_column_reference,
    message: "there is no unique or exclusion constraint matching the ON CONFLICT specification"
  }
}
```

Seen when `Repo.insert/2` is called with:

```elixir
Repo.insert(changeset,
  on_conflict: :nothing,
  conflict_target: [:request_id]
)
```

And the unique index was created as a **partial** index:

```elixir
create unique_index(:llm_usage, [:request_id],
  where: "request_id IS NOT NULL",
  name: :llm_usage_request_id_unique
)
```

## Investigation

1. **Read the Postgres error**: `invalid_column_reference` — the ON CONFLICT spec does not match any constraint.
2. **Checked the migration**: `create unique_index ... where: "request_id IS NOT NULL"` → creates a partial index.
3. **Checked Ecto docs**: `conflict_target: [:request_id]` generates `ON CONFLICT (request_id)` — no WHERE.
4. **Root cause**: PostgreSQL requires the `ON CONFLICT (col) WHERE predicate` to exactly match the partial index's WHERE clause. Ecto's `conflict_target` list syntax cannot express a WHERE predicate, so the partial index is never matched.

## Root Cause

`conflict_target: [:col]` generates `ON CONFLICT (col)` — no predicate. A partial unique index has a predicate. PostgreSQL will not use a partial index for `ON CONFLICT` unless the INSERT statement also includes the identical `WHERE` clause. Ecto's high-level `conflict_target` option does not support this.

```elixir
# BROKEN — partial index: WHERE predicate doesn't match ON CONFLICT clause
create unique_index(:llm_usage, [:request_id],
  where: "request_id IS NOT NULL"
)
```

Note: multiple NULLs in a regular (non-partial) unique index are still permitted in PostgreSQL — each NULL is treated as distinct. The `WHERE IS NOT NULL` guard was unnecessary.

## Solution

Replace the partial index with a non-partial unique index:

```elixir
# FIXED — non-partial index: ON CONFLICT (request_id) matches
create unique_index(:llm_usage, [:request_id],
  name: :llm_usage_request_id_unique
)
```

If the partial index already ran as a migration, create a new migration to drop and recreate:

```elixir
def up do
  drop_if_exists index(:llm_usage, [:request_id], name: :llm_usage_request_id_unique)
  create unique_index(:llm_usage, [:request_id], name: :llm_usage_request_id_unique)
end

def down do
  drop_if_exists index(:llm_usage, [:request_id], name: :llm_usage_request_id_unique)
  create unique_index(:llm_usage, [:request_id],
    where: "request_id IS NOT NULL",
    name: :llm_usage_request_id_unique
  )
end
```

### Files Changed

- `priv/repo/migrations/20260425000002_fix_llm_usage_request_id_index.exs`

## Prevention

- [ ] When using `conflict_target: [:col]` in Ecto, **never** create the backing unique index as partial (`where:` clause). PostgreSQL requires exact predicate matching.
- [ ] PostgreSQL's NULL handling in regular unique indexes is safe: `NULL != NULL` means multiple NULL rows are always allowed in a non-partial unique index. The `WHERE col IS NOT NULL` guard adds no value and breaks `ON CONFLICT`.
- [ ] After running migrations against the dev DB, also run `MIX_ENV=test mix ecto.migrate` — the test sandbox has its own schema and will fail independently if migrations are missing.

## Related

- `solutions/ecto/non-unique-index-on-oauth-identity-users-20260421.md`
- PostgreSQL docs: [ON CONFLICT Clause](https://www.postgresql.org/docs/current/sql-insert.html#SQL-ON-CONFLICT)
