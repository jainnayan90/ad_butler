# Review: week-2-auditor-triage-fixes

**Verdict**: REQUIRES CHANGES  
**Date**: 2026-04-28  
**Agents**: elixir-reviewer, iron-law-judge, security-analyzer, testing-reviewer, oban-specialist  
**Tests at review time**: 316 passed, 0 failures

---

## Blockers (must fix before merge)

### B1 — `acknowledge_finding/2` uses `get_finding!` — crashes instead of returning error tuple

**Files**: `lib/ad_butler/analytics.ex:83`  
**Agents**: iron-law-judge (DEFINITE), elixir-reviewer (SUGGESTION)

`acknowledge_finding/2` internally calls `get_finding!(user, finding_id)` which raises `Ecto.NoResultsError` on scope miss. `FindingDetailLive.handle_event("acknowledge")` pattern-matches `{:error, _reason}` — it will never receive that; instead it gets an unhandled raise → 500. The safe variant `get_finding/2` already exists.

```elixir
# Fix: replace in acknowledge_finding/2
def acknowledge_finding(%User{} = user, finding_id) do
  with {:ok, finding} <- get_finding(user, finding_id) do
    finding
    |> Finding.acknowledge_changeset(user.id)
    |> Repo.update()
  end
end
```

Update `@spec` to include `{:error, :not_found}`.

---

### B2 — `handle_event("acknowledge")` KeyError on nil finding

**Files**: `lib/ad_butler_web/live/finding_detail_live.ex:54`  
**Agent**: elixir-reviewer (CRITICAL)

`socket.assigns.finding` is `nil` in mount. If a user sends `"acknowledge"` before `handle_params` completes (stale websocket, replay attack), `socket.assigns.finding.id` raises `KeyError` on nil.

```elixir
# Add nil-guard function head before the main clause
@impl true
def handle_event("acknowledge", _params, %{assigns: %{finding: nil}} = socket) do
  {:noreply, socket}
end

@impl true
def handle_event("acknowledge", _params, socket) do
  # existing implementation
end
```

---

## Warnings (should fix)

### W1 — `Analytics.get_finding/2` has zero test coverage

**Files**: `test/ad_butler/analytics_test.exs`  
**Agent**: testing-reviewer (CRITICAL)

New public context function used by `FindingDetailLive` for graceful redirect has no tests. Need at minimum:
1. Returns `{:ok, finding}` for owning user
2. Returns `{:error, :not_found}` for cross-tenant access
3. Returns `{:error, :not_found}` for nonexistent UUID

---

### W2 — `six_hour_bucket/0` midnight race condition

**Files**: `lib/ad_butler/workers/budget_leak_auditor_worker.ex`  
**Agents**: elixir-reviewer, oban-specialist (both flagged)

`DateTime.utc_now()` and `Date.utc_today()` are separate calls. At midnight, `now.hour` could be 23 (bucket=18) while `Date.utc_today()` returns the next day → incorrect bucket timestamp.

```elixir
# Fix: derive date from same instant
defp six_hour_bucket do
  now = DateTime.utc_now()
  bucket_hour = div(now.hour, 6) * 6
  DateTime.new!(DateTime.to_date(now), Time.new!(bucket_hour, 0, 0, 0))
end
```

---

### W3 — `Oban.insert_all/1` return value silently ignored

**Files**: `lib/ad_butler/workers/audit_scheduler_worker.ex:30`  
**Agents**: elixir-reviewer, oban-specialist (both flagged)

`Oban.insert_all(valid)` returns `[{:ok, job} | {:error, changeset}]`. DB errors are silently dropped; scheduler returns `:ok` regardless.

```elixir
results = Oban.insert_all(valid)
failed = Enum.filter(results, &match?({:error, _}, &1))
unless failed == [] do
  Logger.error("audit_scheduler: some jobs failed to insert", count: length(failed))
end
```

---

### W4 — Float arithmetic for CPA ratios stored in evidence JSONB

**Files**: `lib/ad_butler/workers/budget_leak_auditor_worker.ex:186-198, 254`  
**Agent**: elixir-reviewer

`ratio = cpa_3d / baseline_cpa` and `max_cpa / min_cpa` use native Elixir float division then persist to JSONB. For ratio-only comparisons (not stored money amounts) integer division is sufficient; for stored evidence, use `Decimal`.

---

### W5 — URL filter params bypass allowlist in `handle_params`

**Files**: `lib/ad_butler_web/live/findings_live.ex:42-52`  
**Agent**: security-analyzer (LOW)

`handle_params/3` reads `severity`, `kind`, `ad_account_id` without validation. `filter_changed` event validates, but direct URL navigation bypasses it. No data leak (scope still applies), but inconsistent surface. Apply allowlist + `Ecto.UUID.cast/1` for `ad_account_id` in `handle_params`.

---

### W6 — `with false <- is_nil(...)` anti-pattern

**Files**: `lib/ad_butler/sync/insights_pipeline.ex`  
**Agent**: elixir-reviewer

```elixir
# Replace:
false <- is_nil(normalised.date_start)

# With:
normalised when not is_nil(normalised.date_start) <- normalise_row(row, local_id)
```

---

## Suggestions

### S1 — Health score idempotency not tested
Running the worker twice within the same 6h bucket should produce exactly one health score row. Add test asserting `count == 1` after two `perform_job` calls.

### S2 — `AuditSchedulerWorker` `unique:` missing explicit `keys: []`
`unique: [period: 21_600]` without `keys: []` is correct in intent but a future footgun if args are added. Make it explicit.

### S3 — `unsafe_get_latest_health_score/1` — future footgun
Any caller can skip the ownership guard. Consider a scoped variant or enforce via strong `@doc` warning. Current call site is safe.

### S4 — TOCTOU in finding dedup
`get_unresolved_finding/2` → `create_finding/1` is check-then-act. Migration `20260427000002` already adds a partial unique index `ON (ad_id, kind) WHERE resolved_at IS NULL` — **verify this index is applied**. If it is, race condition is mitigated by DB constraint.

### S5 — `async: false` in worker tests undocumented
Add one-line comment explaining why `async: false` is required (materialized view `REFRESH` cannot run `CONCURRENTLY` inside sandbox transaction).

---

## Deconfliction Notes

- B1 and the "never raise in happy path" suggestion from elixir-reviewer are the same root cause — fixed by B1.
- Oban TOCTOU (S4) is mitigated by the existing partial unique index in migration 20260427000002 — lower severity than Oban agent reported.
- Security L1/L2 consolidated into W5.

---

## Clean Areas

- `FindingsLive` — streams, `connected?` guard, pagination, event allowlist (L1/L2 aside)
- `BudgetLeakAuditorWorker` — string keys, `unique: [keys: [:ad_account_id]]`, structured logs, `cond` refactor clean
- Migrations — append-only, reversible, concurrent partial index correct
- Tenant scoping — `scope_findings/2` JOIN is airtight across all surfaces
- CSRF/XSS — HEEx auto-escapes; strict CSP; no raw/1
- `filter_valid_rows/2` extraction — correct fix for Credo nesting
