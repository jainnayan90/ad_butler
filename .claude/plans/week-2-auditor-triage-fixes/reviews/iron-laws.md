# Iron Law Violations — week-2-auditor-triage-fixes

⚠️ EXTRACTED FROM AGENT MESSAGE (write was denied)

**Files scanned**: 8 | **Iron Laws checked**: 16 of 23 | **Violations**: 5 (1 blocker, 2 warnings, 2 suggestions)

---

## Critical Violations (BLOCKER)

### [Project Law #6] `acknowledge_finding/2` raises instead of returning error tuple

- **File**: `lib/ad_butler/analytics.ex:83`
- **Code**: `finding = get_finding!(user, finding_id)`
- **Confidence**: DEFINITE
- The bang variant raises `Ecto.NoResultsError` on scope miss. `FindingDetailLive.handle_event("acknowledge", ...)` calls `Analytics.acknowledge_finding/2` and pattern-matches `{:error, _reason}` — it will never receive that; it gets an unhandled raise, producing a 500. The safe variant `get_finding/2` already exists.
- **Fix**: Replace `get_finding!` with `get_finding` inside `acknowledge_finding/2` and use `with {:ok, finding} <- get_finding(user, finding_id)` to propagate `{:error, :not_found}`.

---

## High Violations (WARNING)

### [Project Law #5] `unsafe_get_latest_health_score/1` — no scope enforcement on the function itself

- **File**: `lib/ad_butler/analytics.ex:141` / `lib/ad_butler_web/live/finding_detail_live.ex:32`
- **Confidence**: LIKELY
- The doc warns callers must verify ownership first. The LiveView does guard via `get_finding/2` before reaching this call, so the specific path is safe. But the function has no ownership enforcement — any future caller can skip the guard.
- **Fix**: Add a scoped `get_latest_health_score(%User{}, ad_id)` or enforce via code review with strong doc warning.

### [Oban Law #7] `AuditSchedulerWorker` `unique:` has no `keys:` — all scheduler jobs share one uniqueness slot

- **File**: `lib/ad_butler/workers/audit_scheduler_worker.ex:9`
- **Confidence**: REVIEW
- `unique: [period: 21_600]` with no `keys:` means exactly one scheduler job can exist in any 6-hour window. Manual triggers within that window are silently dropped.
- **Fix**: If intentional, add a comment. If not, add explicit `keys: []` or restrict via cron only.

---

## Suggestions

### [Project Law #3] Confirm cross-user isolation test for `get_finding/2`

- **Files**: `test/ad_butler/analytics_test.exs`
- New `get_finding/2` function — confirm a two-user tenant isolation test exists.

### [Project Law #6 / secondary] `get_finding!` in `acknowledge_finding/2` — same as BLOCKER

Same root cause — resolved by the BLOCKER fix above.

---

**Clean**: FindingsLive (streams, connected? guard, paginated), BudgetLeakAuditorWorker (string keys, unique with keys:, structured logs), migrations (append-only, reversible), schemas (decimal for scores).
