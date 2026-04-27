---
module: "AdButler.Ads.Insight"
date: "2026-04-27"
problem_type: database_issue
component: ecto_schema
symptoms:
  - "Repo.insert_all raises at runtime: unknown field `:updated_at` in schema given to insert_all"
  - "bulk_upsert_insights returns {:error, :upsert_failed} — tests fail with upsert_failed"
  - "Field is in on_conflict replace list but not in schema or migration"
root_cause: "Manually-managed Ecto schema (no timestamps() macro) did not have updated_at field — adding :updated_at to on_conflict replace list fails because Repo.insert_all validates fields against the schema"
severity: high
tags: ["insert-all", "on-conflict", "timestamps", "manually-managed-schema", "updated-at", "upsert"]
---

# Repo.insert_all fails with unknown field when schema omits timestamps()

## Symptoms

After adding `:updated_at` to the `on_conflict: {:replace, [...]}` list in
`bulk_upsert_insights/1`, the function returned `{:error, :upsert_failed}` and
tests failed with:

```
unknown field `:updated_at` in schema AdButler.Ads.Insight given to insert_all.
Unwritable fields, such as virtual and read only fields are not supported.
Associations are also not supported.
```

## Investigation

1. **Checked ads.ex** — `:updated_at` added to replace list and entry map
2. **Checked Insight schema** — manually-defined schema using `field :inserted_at, :naive_datetime`
   with no `timestamps()` macro, and no `updated_at` field
3. **Checked migration** — `insights_daily` table also lacked `updated_at` column
4. **Root cause found**: `Repo.insert_all` validates fields against the schema at runtime

## Root Cause

`Insight` uses a manually-managed schema (no `timestamps()`) because the table
is written exclusively via `insert_all`, not changesets:

```elixir
# Schema was missing updated_at
schema "insights_daily" do
  # ...fields...
  field :inserted_at, :naive_datetime
  # NO updated_at
end
```

```sql
-- Migration also lacked the column
CREATE TABLE insights_daily (
  -- ...columns...
  inserted_at TIMESTAMP NOT NULL DEFAULT NOW()
  -- NO updated_at
)
```

`Repo.insert_all` validates that every key in the entry maps and every field in
the `on_conflict` replace list exists in the schema. Absence = runtime error.

## Solution

Three parts must be in sync:

1. **Migration** — add `updated_at` column:
```sql
updated_at TIMESTAMP NOT NULL DEFAULT NOW()
```

2. **Schema** — add field:
```elixir
field :updated_at, :naive_datetime
```

3. **Context function** — add to entry maps and replace list:
```elixir
entries = Enum.map(rows, fn row ->
  row
  |> Map.put_new(:inserted_at, now)
  |> Map.put(:updated_at, now)   # <-- added
end)

on_conflict: {:replace, [..., :updated_at]}  # <-- added
```

Since the migration was untracked/new (feature branch), it was safe to amend
in-place. In shared environments, create a new `ALTER TABLE ADD COLUMN` migration.

### Files Changed

- `priv/repo/migrations/20260426100001_create_insights_daily.exs` — Added `updated_at` column
- `lib/ad_butler/ads/insight.ex` — Added `field :updated_at, :naive_datetime`
- `lib/ad_butler/ads.ex` — Added `:updated_at` to entry maps and replace list

## Prevention

- [ ] When writing `Repo.insert_all` with `on_conflict: {:replace, [...]}`, verify every field in the replace list exists in the schema AND the migration
- [ ] Manually-managed schemas should include a comment explaining why `timestamps()` is absent, to prevent future reviewers from adding it incorrectly
- Specific guidance: "For schemas without `timestamps()`, track `inserted_at` and
  `updated_at` manually as `field :x, :naive_datetime`. All three locations must
  agree: migration column, schema field, and insert_all entry map."
