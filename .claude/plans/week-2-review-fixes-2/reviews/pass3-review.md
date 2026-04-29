# Review: week-2-review-fixes-2 (Pass 3 — Final)

**Date**: 2026-04-29
**Verdict**: REQUIRES CHANGES
**Breakdown**: 1 blocker · 3 warnings · 4 suggestions

---

## BLOCKER

### [BLOCKER] `Oban.insert_all` does not honour `unique:` with the Basic Engine
**Source**: Elixir Reviewer
**Location**: `lib/ad_butler/workers/audit_scheduler_worker.ex:33`

`BudgetLeakAuditorWorker` declares `unique: [period: 21_600, fields: [:args, :queue, :worker], keys: [:ad_account_id]]`.
Oban's unique-job resolution (which checks existing jobs by state) only fires when inserting via `Oban.insert/2`.
`Oban.insert_all/1` with the Basic Engine (plain `oban`, no Pro) uses raw `on_conflict: :nothing` at the DB level,
which is NOT equivalent — there is no unique index on `(args, queue, worker)` in `oban_jobs`, so the dedup does not fire.

If the `AuditSchedulerWorker` is retried within the 6-hour window (max_attempts: 3), every ad account gets a second
auditor job. The `BudgetLeakAuditorWorker` has finding-level dedup via `get_unresolved_finding/2`, so duplicate
*findings* are avoided, but duplicate *load* is real and duplicate health-score rows are possible.

**Suggested fix** — insert one at a time so unique resolution fires:
```elixir
results =
  Enum.flat_map(valid, fn cs ->
    case Oban.insert(cs) do
      {:ok, job} -> [job]
      {:error, _changeset} -> []
    end
  end)
```

The `not_inserted` count becomes `length(valid) - length(results)` as before.

---

## Warnings

### [WARNING] Missing `else` clause in `with` — errors silently lost
**Source**: Oban Specialist
**Location**: `lib/ad_butler/workers/budget_leak_auditor_worker.ex:59-68`

`audit_account/1` uses `with` without `else`. If either step returns `{:error, reason}`, Oban correctly retries,
but there is no log entry at the failure site — the reason is silently dropped.

**Suggested fix**:
```elixir
else
  {:error, reason} ->
    Logger.error("budget_leak_auditor: audit failed",
      ad_account_id: ad_account.id,
      reason: inspect(reason)
    )
    {:error, reason}
```

---

### [WARNING] Redundant plain index on `ad_health_scores` after unique index added
**Source**: Elixir Reviewer
**Location**: `priv/repo/migrations/20260427000001_create_ad_health_scores.exs:17-20` and `20260428000001_add_unique_index_ad_health_scores.exs`

Migration `20260427000001` creates a plain composite index on `(ad_id, computed_at DESC)`. Migration `20260428000001`
adds a unique index on the same two columns. Both now coexist — every insert pays the cost of maintaining two indexes.
Since neither has run in prod, a fourth migration should drop the redundant plain index.

---

### [WARNING] `FindingHelpers` public functions missing `@spec`
**Source**: Elixir Reviewer
**Location**: `lib/ad_butler_web/helpers/finding_helpers.ex:5-23`

All four public functions have `@doc` but no `@spec`. CLAUDE.md requires `@spec` on every public `def`.

---

## Suggestions

### [SUGGESTION] `unsafe_get_latest_health_score/1` signature encodes no ownership precondition
**Source**: Security Analyzer
**Location**: `lib/ad_butler/analytics.ex:144-152`

The function skips tenant scope by design; correctness depends on callers passing an already-scoped `ad_id`.
Consider accepting `%Finding{}` instead of bare `binary()` so the type signature encodes the precondition.

### [SUGGESTION] Add inline comment to `acknowledge` handler noting scope re-check
**Source**: Security Analyzer
**Location**: `lib/ad_butler_web/live/finding_detail_live.ex:56-66`

`acknowledge_finding/2` re-runs `get_finding/2` (scoped), so trust-assigns pattern is safe. A one-line comment
preserves the invariant for future maintainers.

### [SUGGESTION] `check_stalled_learning/5` uses nested `if` — flatten with `with`
**Source**: Elixir Reviewer
**Location**: `lib/ad_butler/workers/budget_leak_auditor_worker.ex:308-332`

Two nested `if` blocks; correct but less readable than the `with ... else _ -> :skip` pattern used by other heuristics.

### [SUGGESTION] Verify `Oban.insert_all/1` return type comment in `insert_all` compound doc
**Source**: Oban Specialist
**Location**: `lib/ad_butler/workers/audit_scheduler_worker.ex:33-39`

Low risk (documented in `.claude/solutions/oban/insert-all-returns-list-not-tagged-tuple-20260422.md`). No code change
required — informational only.

---

## Clean (All Prior Findings Resolved)

- B1 (pass 1): `Oban.insert_all` dead error filter → fixed ✓
- W1 (pass 1): `keys: []` wrong — fixed: `fields: [:queue, :worker]` on scheduler ✓
- W2 (pass 1): float comparisons — fixed: integer arithmetic ✓
- W3 (pass 1): `async: false` comment — fixed ✓
- W5 (pass 1): `get_finding/2` CastError rescue — fixed ✓
- W1 (pass 2): `BudgetLeakAuditorWorker` missing `fields:` — fixed: `fields: [:args, :queue, :worker]` ✓
- W2 (pass 2): log label "jobs deduplicated" — fixed: `count: not_inserted` ✓
- S1-S4 (pass 1+2): deferred suggestions — documented ✓

## Pre-existing (Not In Diff)

- B2 PERSISTENT: `/app/bin/migrate` missing — Fly deploys will fail
- B3 PERSISTENT: Docker ARG not exported as ENV
- PERSISTENT: `Task.start/1` unsupervised, `/health/readiness` no rate limit
