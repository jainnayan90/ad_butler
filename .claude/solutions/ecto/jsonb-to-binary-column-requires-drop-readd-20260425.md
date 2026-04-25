---
module: "AdButler.Repo.Migrations"
date: "2026-04-25"
problem_type: database_issue
component: ecto_migration
symptoms:
  - "Ecto.Migration: ALTER TABLE USING hint error from Postgres when modifying jsonb column to binary"
  - "hint: You might need to specify 'USING metadata::bytea'"
  - "Ecto modify/3 does not support USING cast clauses"
root_cause: "PostgreSQL cannot cast jsonb to bytea automatically. Ecto's alter/modify DDL does not support the USING clause needed for this cast. Drop+re-add is required."
severity: medium
tags: [migration, jsonb, binary, bytea, cloak, encryption, alter-table, ecto]
---

# `jsonb` Column Cannot Be Modified to `binary` via Ecto `modify`

## Symptoms

```
hint: You might need to specify "USING metadata::bytea".
** (Postgrex.Error) ERROR 42804 (datatype_mismatch)
  column "metadata" cannot be cast automatically to type bytea
```

Appears when running a migration that uses:

```elixir
alter table(:llm_usage) do
  modify :metadata, :binary, null: true
end
```

Where the existing column type is `:jsonb`.

## Investigation

1. **Ran `mix ecto.migrate`** — got `USING metadata::bytea` hint from Postgres.
2. **Checked Ecto docs** — `modify/3` generates `ALTER COLUMN col TYPE new_type`. There is no option to add `USING expr`.
3. **Root cause**: `jsonb → bytea` is not an implicit Postgres cast; it requires `USING col::text::bytea` or equivalent. Ecto's DDL builder has no `using:` option.
4. **Table was empty** (newly created migration, never had data inserted) — drop+re-add is safe.

## Root Cause

Ecto's `Ecto.Migration.modify/3` generates `ALTER COLUMN TYPE` without a `USING` clause. PostgreSQL requires an explicit `USING` expression to cast between types with no implicit coercion path (`jsonb → bytea` is one such pair). Ecto has no `using:` option for this DDL.

## Solution

Drop the column and re-add with the new type. Safe when the table is empty:

```elixir
def up do
  # Drop and re-add: table empty so no data to preserve.
  # jsonb → bytea requires USING cast; Ecto modify/3 does not support it.
  alter table(:llm_usage) do
    remove :metadata
  end

  alter table(:llm_usage) do
    add :metadata, :binary, null: true
  end
end

def down do
  alter table(:llm_usage) do
    remove :metadata
  end

  alter table(:llm_usage) do
    add :metadata, :jsonb, null: true, default: fragment("'{}'")
  end
end
```

If data must be preserved, use `execute/1` with raw SQL:

```elixir
def up do
  execute "ALTER TABLE llm_usage ALTER COLUMN metadata TYPE bytea USING metadata::text::bytea"
end
```

### Files Changed

- `priv/repo/migrations/20260425000000_alter_llm_usage_metadata_to_binary.exs`

## Prevention

- [ ] When altering a column type in Postgres that has no implicit cast, use `execute/1` with raw SQL (`USING` clause) or drop+re-add if the table is empty.
- [ ] Types that commonly require `USING`: `jsonb → bytea`, `text → integer`, `varchar → uuid`, `json → jsonb` (actually fine), `bytea → text`.
- [ ] If you're changing a column to support `Cloak.Ecto.Binary` encryption, plan for a `:binary` column from the start — altering an existing `:jsonb` or `:text` column to `:binary` always requires a migration workaround.

## Related

- `solutions/config/cloak-key-must-be-32-bytes-aes-256-gcm-20260421.md`
- Ecto Migration docs: `modify/3`
