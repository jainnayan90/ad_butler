# Oban Worker Review: week-2-review-fixes-2

⚠️ EXTRACTED FROM AGENT MESSAGE (agent Write access denied)

**Status**: REQUIRES CHANGES
**Issues**: 1 blocker · 2 warnings · 1 suggestion

---

## Blocker

### B1 — `Oban.insert_all` failure detection is dead code

`Oban.insert_all/1` returns `[%Oban.Job{}]` — a flat list of inserted job structs. Jobs skipped via uniqueness deduplication are absent from the list, not returned as `{:error, _}`. The function raises on DB error rather than returning error tuples.

```elixir
failed = Enum.filter(results, &match?({:error, _}, &1))
```

`match?({:error, _}, &1)` **never matches**. `failed` is always `[]`. The `Logger.error` line is dead code.

**Fix**: replace with deduplication count:
```elixir
results = Oban.insert_all(valid)
skipped = length(valid) - length(results)
if skipped > 0, do: Logger.info("audit_scheduler: jobs deduplicated", count: skipped)
Logger.info("audit_scheduler enqueued jobs", count: length(results))
```

---

## Warnings

### W1 — `keys: []` comment is misleading

`keys: []` means exact args-map match (both args must be identical), NOT "args ignored". Works today only because `AuditSchedulerWorker` is always called with `%{}` args. A future change that adds args will silently break the intended uniqueness scope.

**Correct form** to truly ignore args: `unique: [period: 21_600, fields: [:queue, :worker]]`

### W2 — Float division still in display strings

The threshold comparisons are correctly integer-based, but:
- `Float.round(cpa_3d / baseline_cpa, 2)` in evidence map
- `Float.round(max_cpa / min_cpa, 1)` in body string

These are display-only and acceptable, but inconsistent with the fix goal stated in the plan.

---

## Suggestions

### S1 — Verify `unique_constraint` in `Analytics.create_finding/1` changeset

The TOCTOU DB guard (partial unique index `findings_ad_id_kind_unresolved_index`) produces clean `{:error, changeset}` on concurrent duplicates only if `unique_constraint` is declared in the Finding changeset. Without it, DB error surfaces as a raw `Postgrex.Error` raise, which Oban's `max_attempts: 3` handles but logs spuriously.

---

## Clean Checks

- **`div(spend, conversions)`**: Correct. Truncates toward zero for positive integers. Guard `conversions > 0` precedes every call. No division-by-zero risk. ✓
- **`six_hour_bucket/0` fix**: Using `DateTime.to_date(now)` with same `now` as for the hour is correct. Midnight race eliminated. ✓
- **TOCTOU comment**: Accurate. DB partial unique index does enforce uniqueness at DB level and concurrent inserts raise `Ecto.ConstraintError`. ✓
- **Idempotency/retry safety**: Both workers safe to retry. ✓
