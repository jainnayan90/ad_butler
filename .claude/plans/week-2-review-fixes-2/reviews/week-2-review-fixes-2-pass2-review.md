# Review: week-2-review-fixes-2 (Pass 2 — Triage Fixes)

**Date**: 2026-04-29
**Verdict**: PASS WITH WARNINGS
**Breakdown**: 0 blockers · 3 warnings · 4 suggestions

All 4 triage fixes confirmed correct. The integer arithmetic in `check_bot_traffic` was explicitly verified (CTR > 5% ≡ `clicks * 100 > impressions * 5`; CVR < 0.3% ≡ `conversions * 1000 < clicks * 3`; division-by-zero on display path safe because CTR condition guarantees clicks ≥ 51). The `Ecto.Query.CastError` rescue in `get_finding/2` is appropriate — CastError is raised by external code (Ecto/Postgrex), not project code. `fields: [:queue, :worker]` verified correct against Oban source.

---

## WARNINGS

### W1: `BudgetLeakAuditorWorker` unique config should be explicit about fields
**Source**: Elixir Reviewer
**Location**: `lib/ad_butler/workers/budget_leak_auditor_worker.ex:14`

```elixir
unique: [period: 21_600, keys: [:ad_account_id]]
```

`keys:` only applies when `fields` includes `:args`. This works today because the Oban default `fields` includes `:args`, but the intent is implicit. If someone copies the scheduler's `fields: [:queue, :worker]` pattern here, `keys:` would be silently ignored and per-account dedup would break with no error.

**Suggested fix** (defense-in-depth):
```elixir
unique: [
  period: 21_600,
  fields: [:args, :queue, :worker],
  keys: [:ad_account_id]
]
```

### W2: `"jobs deduplicated"` log label is semantically misleading
**Source**: Oban Specialist
**Location**: `lib/ad_butler/workers/audit_scheduler_worker.ex:35`

The count reflects DB-level `on_conflict: :nothing` skips (Basic Engine), not Oban application-level unique resolution. Rename key to `not_inserted` or add a comment clarifying the distinction. Not a bug, but misleads debugging.

### W3: Dedup count returns 0 in tests (Oban inline engine)
**Source**: Elixir Reviewer
**Location**: `lib/ad_butler/workers/audit_scheduler_worker.ex:33–35`

The `inline` engine used by `Oban.Testing` / `perform_job` may return all inserted rows regardless of conflicts, making `skipped` always 0 in tests even when dedup fires in production. The production behavior is correct; the test environment cannot exercise this path.

---

## SUGGESTIONS

### S1: Make `BudgetLeakAuditorWorker` unique state scope explicit
**Source**: Oban Specialist

Confirm `unique:` covers both `available` and `scheduled` states (Oban default includes both). Worth a comment for future readers.

### S2: Add bot-traffic boundary test
**Source**: Testing Reviewer

No test validates the integer arithmetic near the threshold boundary (CTR ≈ 5%, CVR ≈ 0.3%). An off-by-one in the multipliers would be undetected.

### S3: Add bot-traffic negative test for non-risky placement
**Source**: Testing Reviewer

No test covers the `risky_placement = false` branch — high CTR + low CVR on `"facebook_feed"` should skip. This branch is currently untested.

### S4: Unnecessary `insert_ad_account_for_user` in malformed UUID test
**Source**: Testing Reviewer
**Location**: `test/ad_butler/analytics_test.exs:138`

`CastError` fires before the scope join runs, so the inserted account is unused. Minor DB overhead — can be removed.

---

## Confirmed Fixed (All Triage Items)

- **B1 FIXED**: `Oban.insert_all` dead code replaced with deduplication count ✓
- **W1 FIXED**: `keys: []` → `fields: [:queue, :worker]` — verified correct against Oban source ✓
- **W2 FIXED**: `check_bot_traffic` integer comparisons — math verified correct ✓
- **W3 FIXED**: `async: false` comments updated with accurate reason ✓
- **W4 N/A**: `list_ad_accounts/1` already had `limit(200)` ✓
- **W5 FIXED**: `get_finding/2` rescues `Ecto.Query.CastError` → `{:error, :not_found}` ✓

---

## Pre-existing (Not In Diff)

- B2 PERSISTENT: `/app/bin/migrate` missing — Fly deploys will fail
- B3 PERSISTENT: Docker ARG not exported as ENV
- W PERSISTENT: `Task.start/1` unsupervised, `/health/readiness` no rate limit
