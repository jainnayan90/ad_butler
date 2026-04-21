---
module: "Repo.Migrations.CreateUsers"
date: "2026-04-21"
problem_type: database_issue
component: ecto_migration
symptoms:
  - "PR description states meta_user_id should be unique, but migration uses create index (non-unique)"
  - "Concurrent OAuth callbacks for the same Meta user can silently create duplicate app users"
root_cause: "create index used instead of create unique_index for an OAuth identity field that is used as a lookup key in upsert logic"
severity: high
tags: [migration, unique-index, oauth, meta, identity, duplicate-users]
---

# Non-Unique Index on OAuth Identity Field Allows Duplicate Users

## Symptoms

Migration creates a plain `index` on an OAuth identity field (`meta_user_id`) that is
used as a lookup key in `create_or_update_user/1` during the OAuth callback. The field
appears unique by convention, but the database does not enforce it.

Concurrent OAuth callbacks for the same Meta user can race and insert two `users` rows
with the same `meta_user_id`, silently creating duplicate accounts.

## Investigation

1. **Read the migration** — `create index(:users, [:meta_user_id])` is a non-unique index.
2. **Read the plan doc** — `03-token-monitoring.md` and `plan-adButlerV01Foundation.prompt.md`
   both show `create index` (non-unique), so the plan doc had the same oversight.
3. **Read the OAuth callback** — `Accounts.create_or_update_user/1` is called with
   `meta_user_id: user_info["id"]` on every callback. Without a unique constraint the
   upsert relies entirely on application-layer logic with no DB safety net.
4. **Root cause**: intent was unique, both the migration and plan doc used the wrong helper.

## Root Cause

`meta_user_id` is a Meta OAuth user identifier stored on `users` as a lookup key.
The OAuth callback upserts by this field. A non-unique index allows the DB to accept
duplicate rows for the same Meta identity if application logic fails or races.

```elixir
# Problematic — plain index, no uniqueness guarantee
create index(:users, [:meta_user_id])
```

## Solution

```elixir
# Fixed — unique index prevents duplicate Meta identities
create unique_index(:users, [:meta_user_id])
```

`meta_user_id` is nullable (user may not have connected Meta yet). Postgres unique
indexes treat NULLs as distinct, so multiple NULL rows are allowed — only non-null
duplicates are blocked. This is the correct behavior.

### Files Changed

- `priv/repo/migrations/20260420155045_create_users.exs:17` — Changed to `unique_index`

## Prevention

- [ ] When an OAuth identity column is used as an upsert key, always use `unique_index`
- [ ] Review plan docs for `create index` on identity/external-id columns — plan docs can carry the same oversight
- Specific guidance: any column described as "from OAuth" or used in `create_or_update_*` should have a unique index unless the design explicitly allows multiple users per identity

## Related

- Iron Law: verify DB constraints match application-layer uniqueness assumptions
