---
module: "AdButler.Accounts"
date: "2026-04-21"
problem_type: test_failure
component: ecto_migration
symptoms:
  - "get_user_by_email returns nil for uppercase input despite citext migration"
  - "information_schema.columns shows character varying for email, not citext"
  - "pg_extension has no row for citext even though migration calls CREATE EXTENSION IF NOT EXISTS citext"
root_cause: "Migration was already marked as 'up' in the test DB from a previous run where the column was :string; Ecto never re-runs an already-applied migration even when its content changes"
severity: medium
tags: [citext, migration, stale-schema, test-db, varchar, case-insensitive, ecto-migrate]
---

# Stale Test DB Schema: citext Column Shows as varchar

## Symptoms

- A migration adds `add :email, :citext` with `CREATE EXTENSION IF NOT EXISTS citext`
- `mix ecto.migrations` shows the migration as `up`
- But `SELECT data_type FROM information_schema.columns WHERE table_name = 'users' AND column_name = 'email'` returns `character varying`
- Case-insensitive lookup `Repo.get_by(User, email: String.upcase(email))` returns `nil`

## Investigation

1. **Checked `pg_extension`** — `SELECT extname FROM pg_extension WHERE extname = 'citext'` returned 0 rows → citext extension not installed
2. **Checked column type** — `character varying` instead of `citext` → migration ran before citext was configured
3. **Root cause**: the migration was previously run when the column was defined as `:string` (or before citext was added to the migration). Ecto records it as `up` by timestamp. When the migration file is later updated to use `:citext`, `mix ecto.migrate` is a no-op — the migration ID is already in `schema_migrations`.

## Root Cause

Ecto tracks migrations by their timestamp ID, not by their content. If you edit a migration after it has already been applied, the change is silently ignored. `mix ecto.migrate` will not re-apply it.

This commonly happens when:
- The test DB was set up from a `structure.sql` dump that predates the citext column change
- The `structure.sql` file is out of sync with migrations (captured varchar before citext was added)

## Solution

### Immediate fix (rebuild test DB)

```bash
MIX_ENV=test mix ecto.drop && MIX_ENV=test mix ecto.create && MIX_ENV=test mix ecto.migrate
```

### Test-time detection (guard for flaky environments)

Use `@tag :requires_citext` and auto-exclude in `test_helper.exs` when the extension is absent:

```elixir
# test/test_helper.exs
citext_ok =
  case AdButler.Repo.query("SELECT 1 FROM pg_extension WHERE extname = 'citext'") do
    {:ok, %{rows: [[1]]}} -> true
    _ -> false
  end

excludes = if citext_ok, do: [], else: [:requires_citext]
ExUnit.start(exclude: excludes)
```

```elixir
# In your test
@tag :requires_citext
test "lookup is case-insensitive (citext column)" do
  user = insert(:user, email: "test@example.com")
  assert %User{} = Accounts.get_user_by_email("TEST@EXAMPLE.COM")
end
```

### Sync structure.sql

After rebuilding, regenerate `structure.sql` so future setups start correctly:

```bash
mix ecto.dump   # regenerates priv/repo/structure.sql
```

Commit the updated `structure.sql` so `ecto.load` in CI uses the correct schema.

### Files Changed

- `test/test_helper.exs` — auto-exclude `:requires_citext` tests when extension missing
- `test/ad_butler/accounts_test.exs` — added `@tag :requires_citext` to citext test

## Prevention

- [ ] After any migration that changes a column type: rebuild test DB and re-run `mix ecto.dump`
- [ ] Commit `structure.sql` updates alongside migration changes
- [ ] CI should use `mix ecto.create && mix ecto.migrate` (not `mix ecto.load`) to always apply migrations from scratch
- [ ] Never edit a migration that has already been applied — create a new migration instead

## Related

- `.claude/solutions/ecto/duplicate-migration-timestamp-rapid-generation-20260421.md` — Related migration ID management issue
