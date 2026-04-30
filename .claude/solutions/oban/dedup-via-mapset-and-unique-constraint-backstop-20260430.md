---
module: "AdButler.Workers.BudgetLeakAuditorWorker, AdButler.Workers.CreativeFatiguePredictorWorker"
date: "2026-04-30"
problem_type: oban_behavior
component: oban_worker
symptoms:
  - "Audit worker creates a Finding row but the side-effect that follows (score insert) fails — on retry, the Finding already exists and the score never gets written"
  - "Two concurrent workers race past `MapSet.member?(open_findings, {ad_id, kind})` and both call `Repo.insert` — Postgres raises a unique violation that surfaces as `{:error, %Ecto.Changeset{}}`, error-logged, Oban retries"
  - "After Oban retry on a transient failure, score rows are missing for some ads even though Findings exist"
root_cause: "Three independent invariants must hold for safe dedup-and-retry in audit workers: (1) the score-emit must NOT depend on whether `maybe_emit_finding` returned `:ok` or `:skipped`, because retries must always restore score data the first run lost; (2) the unique-constraint changeset error must be re-classified as `:skipped` so a concurrent-worker race surfaces as dedup, not an Oban error; (3) the changeset itself must declare `unique_constraint/3` matching the partial unique index name, otherwise Ecto returns the raw Postgrex exception instead of a clean changeset error."
severity: high
tags: [oban, worker, idempotency, retry, dedup, unique-constraint, ecto, ad-butler]
---

# Audit Workers: Dedup via MapSet + Unique-Constraint Backstop

## Symptoms

`BudgetLeakAuditorWorker` and `CreativeFatiguePredictorWorker` deduplicate
findings on `(ad_id, kind)` while unresolved, via:

1. A partial unique index `findings_ad_id_kind_unresolved_index`.
2. An in-process `MapSet` pre-check (`unsafe_list_open_finding_keys`) to
   skip the SQL roundtrip in the common case.

Two failure modes appeared in review:

- **Lost score rows on retry.** When `maybe_emit_finding` returned
  `:skipped` (dedup), the old code skipped emitting the per-ad score row
  too. If the *first* run had emitted both Finding and score, then
  crashed mid-way, retry would re-run heuristics, hit dedup, and never
  re-emit scores for already-flagged ads. Audit was non-idempotent.
- **Noisy Oban retries on concurrent races.** Two workers fanning out for
  the same ad account can race past the MapSet pre-check before either
  has inserted. The second insert raises a unique violation. Without
  `unique_constraint/3` on the changeset, Ecto wraps the Postgrex
  exception in `%Ecto.InvalidChangesetError{}` — old `maybe_emit_finding`
  treated this as a generic error, returned `{:error, _}`, the worker
  logged ERROR, and Oban retried.

## Investigation

1. **Read `BudgetLeakAuditorWorker.audit_account/1` for the existing
   pattern** — it emits a `leak_score` row for every ad that triggered
   a heuristic, regardless of whether the matching Finding was newly
   created or skipped via dedup. Score upsert is idempotent (`on_conflict`
   replaces score columns only).
2. **Trace the retry scenario** — kill the worker process between
   Finding insert and `bulk_insert_health_scores`. On retry, MapSet
   contains the existing Finding so `:skipped` fires. If the score path
   is gated on `:ok`, score is never written. Plan acceptance criterion:
   "kill between emit and score-write; on retry scores are still written."
3. **Trace the concurrency race** — two `AuditSchedulerWorker` runs (or a
   manual `Oban.insert/1` collision) can produce two simultaneous
   workers for the same ad account. The MapSet snapshot taken at the top
   of `audit_account` is stale before the first insert lands. Postgres'
   partial unique index is the only real backstop.
4. **Confirm the changeset path** — without `unique_constraint(:kind, name: ...)`,
   `Repo.insert/2` raises `%Postgrex.Error{...}` which Ecto re-raises as
   `%Ecto.InvalidChangesetError{}`. With the constraint declared, the
   error is converted to a normal `{:error, %Ecto.Changeset{errors: [kind: {_, [constraint: :unique, ...]}]}}`.

## Root Cause

Three invariants must all hold:

- **Always emit the score entry on `:skipped`.** Scoring is idempotent;
  retries must restore data.
- **Re-classify unique-constraint changeset errors as `:skipped`.** A
  concurrent-worker race that hits the unique index is functionally
  identical to a MapSet-detected dedup. It is not an error condition.
- **Declare `unique_constraint/3` on the changeset.** Otherwise the
  unique violation surfaces as a Postgrex exception, not a clean
  `{:error, changeset}` — and `maybe_emit_finding` cannot pattern-match it.

## Solution

### 1. Changeset declares the constraint

```elixir
# lib/ad_butler/analytics/finding.ex
def create_changeset(finding, attrs) do
  finding
  |> cast(attrs, @content_fields)
  |> validate_required(@required)
  |> validate_inclusion(:severity, @valid_severities)
  |> validate_inclusion(:kind, @valid_kinds)
  |> unique_constraint(:kind, name: :findings_ad_id_kind_unresolved_index)
end
```

### 2. Worker re-classifies the constraint error

```elixir
defp maybe_emit_finding(ad_id, kind, attrs, open_findings) do
  if MapSet.member?(open_findings, {ad_id, kind}) do
    :skipped
  else
    handle_create_result(Analytics.create_finding(attrs), ad_id, kind)
  end
end

defp handle_create_result({:ok, finding}, ad_id, kind), do: ...

defp handle_create_result({:error, %Ecto.Changeset{} = changeset}, ad_id, kind) do
  if dedup_constraint_error?(changeset) do
    :skipped  # concurrent worker raced past MapSet pre-check
  else
    Logger.error("finding creation failed",
      ad_id: ad_id, kind: kind, reason: inspect(changeset.errors)
    )
    {:error, changeset}
  end
end

defp handle_create_result({:error, reason}, ad_id, kind), do: ...

defp dedup_constraint_error?(%Ecto.Changeset{errors: errors}) do
  Enum.any?(errors, fn
    {:kind, {_, opts}} -> Keyword.get(opts, :constraint) == :unique
    _ -> false
  end)
end
```

### 3. Score entry built regardless of `:ok` vs `:skipped`

```elixir
# CreativeFatiguePredictorWorker.audit_one_ad/4
case maybe_emit_finding(ad_id, ad_account_id, score, factors, open_findings) do
  {:error, reason} -> {:error, reason}        # halt-on-error → Oban retries
  _ok_or_skipped   -> {:ok, build_entry(...)} # :ok and :skipped both emit score
end
```

### Files Changed

- `lib/ad_butler/analytics/finding.ex` — `unique_constraint` added
- `lib/ad_butler/workers/budget_leak_auditor_worker.ex` — `handle_create_result/3` + `dedup_constraint_error?/1`
- `lib/ad_butler/workers/creative_fatigue_predictor_worker.ex` — same pattern + `audit_one_ad/4` always emits score on `:skipped`

## Prevention

- [ ] Whenever a worker pre-checks dedup via in-process state (MapSet,
      ETS, etc.), the underlying schema MUST declare a matching
      `unique_constraint/3`. The pre-check is a performance optimization;
      the database is the only authoritative dedup boundary.
- [ ] Whenever a worker has a "create then write side-effect" sequence
      that retries via Oban, the side-effect MUST be emitted on dedup
      (`:skipped`) too. Otherwise retries never restore data the first
      run dropped. Mirror BudgetLeakAuditorWorker's "always write health
      score per audited ad" rule.
- [ ] Pattern-match `{:error, %Ecto.Changeset{}}` separately from
      `{:error, _}` in worker error paths — the constraint-violation
      branch is a *control-flow signal*, not an error.
- [ ] `mix credo --strict` will flag deeply-nested `case`+`if` patterns.
      Extract `handle_create_result/N` clauses by `def`-pattern-match
      head; keeps each branch ≤ 2 levels deep and reads better.

## Related

- `solutions/ecto/partial-unique-index-breaks-on-conflict-20260425.md`
- `solutions/oban/oban-schedule-failure-should-not-retry-already-completed-work-20260421.md`
- Migration: `priv/repo/migrations/20260427000002_create_findings.exs` (partial index)
- Plan: `.claude/plans/week7-fixes/plan.md` (B2 + W-1 fixes)
