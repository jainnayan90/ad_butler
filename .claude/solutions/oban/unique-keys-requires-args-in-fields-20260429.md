---
module: "AdButler.Workers.AuditSchedulerWorker / BudgetLeakAuditorWorker"
date: "2026-04-29"
problem_type: oban_behavior
component: oban_worker
symptoms:
  - "unique: [period: n, keys: []] described in comment as 'args not considered' — intent is wrong"
  - "unique: [period: n, keys: [:some_key]] silently ignored when fields excludes :args"
  - "Changing unique fields breaks per-key deduplication with no error"
root_cause: "Oban unique `keys:` option is an arg-subsetting filter that only applies when `fields` includes :args. Without explicit `fields`, the default includes :args which makes it work, but the relationship is implicit and fragile."
severity: medium
tags: [oban, unique, keys, fields, deduplication, uniqueness]
---

# Oban: `keys:` Only Applies When `fields` Includes `:args`

## Symptoms

Worker has `unique: [period: 21_600, keys: []]` with a comment saying "job args are not
considered". The comment is wrong — `keys: []` means args maps must be exactly equal
(all keys compared), not that args are ignored.

Separately: `unique: [period: n, keys: [:ad_account_id]]` works by accident when
`fields` defaults to `[:args, :queue, :worker]`, but if `fields` is later changed to
`[:queue, :worker]`, `keys` is silently ignored and per-account dedup breaks.

## Investigation

Checked `deps/oban/lib/oban/job.ex`:
- `@unique_fields ~w(args meta queue worker)a` — valid fields
- Default fields: `~w(args queue worker)a`
- `keys` filters which arg keys are compared — only meaningful when `:args` is in `fields`
- `keys == [] or fields == []` → Oban validates as `:ok` (no error raised)

`AuditSchedulerWorker` uses `perform(_job)` — args always `%{}`. So `keys: []` happened
to behave as "ignore args" because empty maps always equal empty maps. Not intentional.

## Root Cause

`keys:` is an arg-subsetting option, not an "ignore args" switch. The relationship with
`fields:` is implicit — `keys:` without explicit `fields: [..., :args, ...]` is fragile.

## Solution

**To ignore args entirely** (one job per worker+queue per period):
```elixir
# fields: [:queue, :worker] ignores args — one scheduler job per 6h window regardless of args
use Oban.Worker, queue: :audit, max_attempts: 3,
  unique: [period: 21_600, fields: [:queue, :worker]]
```

**To deduplicate by a specific arg key** (e.g. one job per ad_account_id):
```elixir
# Explicit fields makes the keys: relationship clear and safe to maintain
use Oban.Worker, queue: :audit, max_attempts: 3,
  unique: [period: 21_600, fields: [:args, :queue, :worker], keys: [:ad_account_id]]
```

Never use `keys:` without also specifying `fields: [..., :args, ...]` — the dependency
is invisible without it.

## Prevention

- [ ] Always set `fields:` explicitly when using `unique:` with `keys:`
- [ ] `keys: []` means exact args-map match, NOT "ignore args" — use `fields: [:queue, :worker]` to truly ignore args
- [ ] Search for `unique: [period:` and verify each has explicit `fields:` alongside any `keys:`
