# Review: week-2-review-fixes-2 (Pass 4 — Targeted)

**Date**: 2026-04-29
**Verdict**: PASS WITH WARNINGS
**Breakdown**: 0 blockers · 1 warning · 1 suggestion

---

## Warnings

### [WARNING] `Oban.insert/2` returns `{:ok, %Job{conflict?: true}}` on unique conflict — `not_inserted` always 0
**Source**: Oban Specialist + Elixir Reviewer (converging)
**Location**: `lib/ad_butler/workers/audit_scheduler_worker.ex:35-45`

The B1 fix switches to per-changeset `Oban.insert/2` so unique-job dedup fires correctly. However, the Basic Engine returns `{:ok, %Job{conflict?: true}}` — not `{:error, _}` — when a unique constraint prevents insertion. The `flat_map` currently only drops `{:error, _}` tuples, so conflicted (deduped) jobs still match `{:ok, job}` and land in `results`. Consequence: `not_inserted` is always 0, the dedup log line never fires, and the "enqueued" count overcounts by including conflicted jobs.

Additionally, `{:error, _} -> []` silently discards any real DB error (e.g., DB down) alongside expected unique conflicts. Real errors should be logged.

**Suggested fix:**
```elixir
results =
  Enum.flat_map(valid, fn cs ->
    case Oban.insert(cs) do
      {:ok, job} -> [job]
      {:error, reason} ->
        Logger.error("audit_scheduler: unexpected insert error", reason: inspect(reason))
        []
    end
  end)

{inserted, conflicted} = Enum.split_with(results, fn job -> not job.conflict? end)

if length(conflicted) > 0,
  do: Logger.info("audit_scheduler: jobs skipped (unique conflict)", count: length(conflicted))

Logger.info("audit_scheduler: enqueued jobs", count: length(inserted))
```

---

## Suggestions

### [SUGGESTION] Migration rollback omits `DESC` on `computed_at`
**Source**: Oban Specialist
**Location**: `priv/repo/migrations/20260429000001_drop_redundant_ad_health_scores_index.exs:8`

The rollback `CREATE INDEX` recreates `(ad_id, computed_at)` without `DESC`, while the original was `(ad_id, computed_at DESC)`. Minor inconsistency — only matters on rollback, and the unique index covers the column regardless.

---

## Clean (All Pass-3 Fixes Verified)

- B1 (pass3): `insert_all` → `insert/2` — unique-job dedup now fires ✓
- W1 (pass3): `else` clause in `audit_account/1` — failure logged ✓
- W2 (pass3): redundant plain index migration — correct ✓
- W3 (pass3): `@spec` on `FindingHelpers` — correct, specs match actual contracts ✓
- Test change: `{:error, :not_found}` assertion — accurately reflects fixed contract ✓
