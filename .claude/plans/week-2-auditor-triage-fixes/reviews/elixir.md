# Code Review: week-2-auditor-triage-fixes (Elixir Reviewer)

⚠️ EXTRACTED FROM AGENT MESSAGE (write was denied)

## Summary
- **Status**: Changes Requested
- **Issues Found**: 5

---

## Critical Issues

### 1. `handle_event("acknowledge")` crashes on nil finding — `FindingDetailLive` line 54

`socket.assigns.finding` is initialised to `nil` in `mount/3`. If a user sends an `"acknowledge"` event before `handle_params` completes (stale websocket, replay), `socket.assigns.finding.id` raises `KeyError` on nil.

**Fix**: Add a nil-guard function head:
```elixir
def handle_event("acknowledge", _params, %{assigns: %{finding: nil}} = socket) do
  {:noreply, socket}
end
def handle_event("acknowledge", _params, socket) do
  ...
end
```

### 2. Float arithmetic stored in evidence JSONB — `BudgetLeakAuditorWorker`

`ratio = cpa_3d / baseline_cpa` and `max_cpa / min_cpa` are native float divisions persisted to the DB. The ratio comparisons should use integer or Decimal arithmetic.

**Fix**: Use integer division for ratios, or Decimal if precision needed.

---

## Warnings

### 3. `with false <- is_nil(...)` anti-pattern — `insights_pipeline.ex`

`with false <- is_nil(normalised.date_start)` is semantically backwards. Prefer:
```elixir
normalised when not is_nil(normalised.date_start) <- normalise_row(row, local_id)
```

### 4. `six_hour_bucket/0` — two separate UTC calls at midnight boundary

`DateTime.utc_now()` and `Date.utc_today()` are separate calls. At midnight, `now.hour` could be 23 while `Date.utc_today()` returns the next day.

**Fix**:
```elixir
defp six_hour_bucket do
  now = DateTime.utc_now()
  bucket_hour = div(now.hour, 6) * 6
  DateTime.new!(DateTime.to_date(now), Time.new!(bucket_hour, 0, 0, 0))
end
```

### 5. `Oban.insert_all/1` return value silently ignored — `AuditSchedulerWorker`

DB errors from `insert_all` are swallowed. Log on error.

---

## Suggestions

- `acknowledge_finding/2` calls `get_finding!/2` (raises) but `@spec` only shows `{:error, Ecto.Changeset.t()}`. Route through `get_finding/2` and return `{:error, :not_found}` for consistency.
- `aggregate_placement_cpas/1` computes `cpa = spend / conversions` (float) for placement evidence — same float-for-money concern.
