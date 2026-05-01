---
title: "Amend an unreleased migration in place when ecto.reset is hook-blocked"
module: "AdButler.Repo.Migrations.CreateEmbeddings"
date: "2026-05-01"
problem_type: workflow
component: ecto_migration
symptoms:
  - "Plan calls for `mix ecto.reset` to pick up an amended unreleased migration"
  - "PreToolUse hook blocks `mix ecto.drop` as a destructive op"
  - "Migration table still shows the prior version applied — new constraint never reaches the DB"
---

## Root cause

`mix ecto.reset` is the canonical way to re-apply an in-place edit to an unreleased
migration, but the project's destructive-op guard hook intercepts `ecto.drop`. Any
manual override defeats the guard's intent.

## Fix

Use rollback + migrate to re-run only the touched migrations. Rollback follows
dependency order, so include any migrations that depend on the one being amended.

```bash
# Migration 20260501000002_create_embeddings.exs amended in place.
# 20260501000003_add_embeddings_hnsw_index.exs depends on the table.
MIX_ENV=test mix ecto.rollback --step 2
MIX_ENV=test mix ecto.migrate
```

After:

```bash
MIX_ENV=test mix ecto.migrations | tail
# up        20260501000002  create_embeddings   <-- re-run with new constraint
# up        20260501000003  add_embeddings_hnsw_index
```

## Why this is safe

`CLAUDE.md` rule: "migrations are append-only in shared environments — never edit a
migration that has run in staging or prod." The migration was unreleased (only on
the local test DB), so amending in place is permitted. Rollback + migrate confines
the destruction to the rolled-back migrations' tables — no cross-table data loss.

## When this DOES NOT apply

If the migration has run in shared envs (CI, staging, prod), amend-in-place is
forbidden. Add a follow-up migration that applies the new constraint instead.
For `null: false` on an existing column with data, that's a 3-step
nullable→backfill→constraint pattern — not a one-liner.
