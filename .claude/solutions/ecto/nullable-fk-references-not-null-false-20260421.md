---
title: "Ecto references/2 does not imply null: false — FK columns are nullable by default"
module: "Ecto.Migration"
date: "2026-04-21"
problem_type: schema_design
component: ecto_migration
symptoms:
  - "FK column accepts NULL even though the parent relationship is required"
  - "Orphaned rows possible: child row exists with NULL parent FK"
  - "Scope-based authorization queries silently exclude NULL rows, masking authz bugs"
  - "Quota enforcement fails when user_id is NULL (unbillable rows in ledger)"
root_cause: "Ecto's references/2 macro adds a FK constraint but does NOT add a NOT NULL constraint. The column must have null: false added explicitly."
severity: critical
tags: [migration, foreign-key, null, references, authorization, schema]
related_solutions: []
---

## Problem

When adding a foreign key column in Ecto migrations using `references/2`, it is natural to assume the column is non-null — after all, what does it mean to have a FK to a row that doesn't exist? However, Ecto adds only the FK constraint, not a NOT NULL constraint. The column is nullable by default.

```elixir
# This compiles and migrates without error — but ad_account_id CAN be NULL
add :ad_account_id, references(:ad_accounts, type: :binary_id, on_delete: :delete_all)
```

### Why This Matters

1. **Orphaned rows**: A row can be inserted with `ad_account_id: nil`, creating a record that belongs to no account.
2. **Authorization bypass**: Scope-based authorization (`where: a.ad_account_id == ^scope.ad_account_id`) silently excludes NULL rows. A NULL-keyed row is invisible to the owner, yet may surface in unscoped admin paths.
3. **Quota bypass**: A `llm_usage` row with `user_id: nil` bypasses per-user cost aggregation (`SUM(cost_cents_total) WHERE user_id = ^id`) and creates unbillable, unreconcilable rows.
4. **Data integrity**: Any downstream query joining on the FK will miss or mishandle NULL rows.

## Solution

Always add `null: false` explicitly to required FK columns:

```elixir
# Correct — enforced at DB level
add :ad_account_id, references(:ad_accounts, type: :binary_id, on_delete: :delete_all),
    null: false

add :campaign_id, references(:campaigns, type: :binary_id, on_delete: :delete_all),
    null: false

# Intentionally nullable (e.g., nilify_all for soft reference)
add :creative_id, references(:creatives, type: :binary_id, on_delete: :nilify_all)
# No null: false — this FK is intentionally optional
```

## Exceptions

Some FK columns are intentionally nullable:
- A column using `on_delete: :nilify_all` — the whole point is that it becomes NULL on parent delete. Do NOT add `null: false` here.
- Optional parent relationships in the domain (e.g., a user's optional profile).

## Detection

Review every `references/2` call in migrations and ask: "Can this legally be NULL?" If no, add `null: false`.

```bash
# Find all references() calls missing null: false
grep -n "references(" priv/repo/migrations/*.exs | grep -v "null: false" | grep -v "nilify_all"
```

This grep catches the pattern — review each hit. Lines using `nilify_all` are intentionally nullable; all others should have `null: false`.

## Prevention

**Code review checklist**: For every migration adding a `references/2` column, confirm `null: false` is present unless the column is intentionally optional.
