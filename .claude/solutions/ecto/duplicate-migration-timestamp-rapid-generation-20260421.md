---
title: "Duplicate migration version error when generating migrations in rapid succession"
module: "mix ecto.gen.migration"
date: "2026-04-21"
problem_type: tooling
component: ecto_migration
symptoms:
  - "mix ecto.migrate fails with: migrations can't be executed, migration version XXXXXXXXXXXXXXXX is duplicated"
  - "Two migration files share the same timestamp prefix (e.g., 20260420155128_create_campaigns.exs and 20260420155128_create_ad_sets.exs)"
  - "Ecto rejects the entire migration run, not just the duplicate"
root_cause: "mix ecto.gen.migration uses a second-precision timestamp as the version number. When multiple migrations are generated within the same second (e.g., in a shell loop or rapid successive calls), they receive identical timestamps and Ecto considers them duplicates."
severity: medium
tags: [migration, tooling, timestamp, version, generation]
related_solutions: []
---

## Problem

When generating multiple migrations rapidly (e.g., in a loop or pipeline), two or more files receive the same second-precision timestamp:

```
priv/repo/migrations/20260420155128_create_campaigns.exs
priv/repo/migrations/20260420155128_create_ad_sets.exs  ← same timestamp!
```

Running `mix ecto.migrate` then fails:

```
** (Ecto.MigrationError) migrations can't be executed, migration version 20260420155128 is duplicated
```

This is especially problematic when the duplicated migrations have FK dependencies on each other (e.g., `ad_sets` references `campaigns`) — alphabetical sort determines run order, and if the dependant sorts before the dependency, migration fails with a FK violation.

## Solution

**Rename the file** with a unique timestamp. Ecto's version is the integer prefix of the filename — just rename the file and the module name doesn't need to change.

```bash
# Check current files
ls priv/repo/migrations/*.exs

# Rename one to a unique timestamp (increment by 1 or 2)
mv priv/repo/migrations/20260420155128_create_ad_sets.exs \
   priv/repo/migrations/20260420155129_create_ad_sets.exs

# Cascade any later files that were also bumped
mv priv/repo/migrations/20260420155129_create_ads.exs \
   priv/repo/migrations/20260420155130_create_ads.exs
```

The module name inside the file (`defmodule AdButler.Repo.Migrations.CreateAdSets`) does **not** need to change — Ecto uses the filename timestamp as the version, not the module name.

## Important: Dependency Ordering

When bumping timestamps to fix duplicates, verify the new order respects FK dependencies:

```
campaigns (155128) must run BEFORE ad_sets (155129)
ad_sets   (155129) must run BEFORE ads     (155130)
```

With the same timestamp, alphabetical sort determines order — `create_ad_sets` sorts before `create_campaigns`, which would break if ad_sets has a FK to campaigns.

## Prevention

Generate migrations one at a time with a small pause between:

```bash
mix ecto.gen.migration create_campaigns
sleep 1
mix ecto.gen.migration create_ad_sets
sleep 1
mix ecto.gen.migration create_ads
```

Or generate all stubs first and fill in the content afterward, accepting that some will need renaming.

After generating a batch, verify uniqueness before filling in content:

```bash
ls priv/repo/migrations/*.exs | cut -d'_' -f1 | sort | uniq -d
# Any output = duplicate timestamps that need fixing
```
