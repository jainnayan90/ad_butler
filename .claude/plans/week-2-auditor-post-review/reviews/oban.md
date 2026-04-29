# Oban Review: week-2-auditor-post-review

⚠️ EXTRACTED FROM AGENT MESSAGE (agent denied Write access)

## Summary
Both workers follow most Oban iron laws correctly. One **critical bug** exists in `AuditSchedulerWorker` where the `Oban.insert_all/1` return type is misunderstood, silently swallowing insert failures.

---

## Critical

### O1 — `Oban.insert_all/1` does NOT return `[{:ok, job} | {:error, _}]` in Oban 2.18
`audit_scheduler_worker.ex:23-33`

Verified in `deps/oban/lib/oban/engines/basic.ex` line 82: `insert_all_jobs` returns `[Job.t()]` — a flat list of job structs. The scheduler's `Enum.filter(results, &match?({:error, _}, &1))` will always produce `[]`. If any changeset is invalid or the DB rejects an insert, the job is silently dropped with no log.

**Fix:** Validate changesets before passing to `insert_all`:
```elixir
{valid, invalid} = Enum.split_with(changesets, &(&1.valid?))
Enum.each(invalid, &Logger.error("audit_scheduler: invalid job changeset", errors: &1.errors))
Oban.insert_all(valid)
```

---

## Warnings

### O2 — `insert_health_scores` is NOT idempotent — retries produce duplicate rows
`budget_leak_auditor_worker.ex:71`

`Analytics.insert_ad_health_score/1` is append-only with no upsert guard. Oban retries (max_attempts: 3) will produce duplicate health score rows for ads processed before the failure.

**Fix:** Add unique constraint on `(ad_id, trunc(computed_at to 6h))` and use upsert with `on_conflict: {:replace, [:leak_score, :leak_factors]}`.

### O3 — `:skipped` findings counted as `fired` — leak score may misrepresent signals
`budget_leak_auditor_worker.ex:124-129`

When `maybe_emit_finding/3` returns `:skipped`, the kind is still prepended to `acc`, contributing weight to `compute_leak_score`. If intent is "what newly fired today" this is wrong. Add a comment explaining the decision.

### O4 — Redundant `unique:` override in `AuditSchedulerWorker.new/2`
`audit_scheduler_worker.ex:27-29`

The module-level `use Oban.Worker, unique: [...]` already sets this. Passing the identical `unique:` in `new/2` is misleading. Remove the runtime override.

---

## Suggestions

- `audit_account/1` `with` has no `else` clause — add explicit `Logger.error` for failure observability
- Scheduler `unique:` lacks `keys: []` declaration — add with comment explaining intent
- Pool size comment in `config.exs` says `POOL_SIZE >= 25` but total queue concurrency is 40 — must be 45+ in prod
