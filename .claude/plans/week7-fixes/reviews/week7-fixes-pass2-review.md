# Week 7 Review-Fixes — Pass 2 Consolidated Review

**Plan:** [.claude/plans/week7-fixes/plan.md](../plan.md)
**Triage:** [week7-fixes-triage.md](week7-fixes-triage.md)
**Pass 1 review:** [week7-fixes-review.md](week7-fixes-review.md)
**Verdict:** REQUIRES CHANGES (1 BLOCKER, 2 WARNINGS, 1 SUGGESTION)
**Reviewers:** elixir-reviewer, oban-specialist, testing-reviewer

## Summary

Pass-2 reviewed the W-1 + S-1..S-5 fixes landed via `/phx:work`. Three of six (W-1, S-2, S-4, S-5) verified clean. **One BLOCKER**: my S-1 fix inverted the slope direction — the regression guard for `heuristic_frequency_ctr_decay` is now silently broken. Plus two small but real follow-ups.

The W-1 dedup-constraint pattern itself is structurally correct (oban-specialist confirmed all 4 evaluation points pass). The follow-ups are about DRY and reachability, not behavior.

---

## Findings

### BLOCKER

#### B-1 (PASS-2): S-1 fix inverted the CTR slope — tenant-isolation regression guard broken
**File:** [test/ad_butler/workers/creative_fatigue_predictor_worker_test.exs:480-481](../../../../test/ad_butler/workers/creative_fatigue_predictor_worker_test.exs#L480)
**Source:** testing-reviewer

The S-1 fix was supposed to preserve numeric values while making intent explicit. It did not — the new formula reverses the assignment:

| `d` | Old `80 - (6 - d) * 10` | New `20 + (6 - d) * 10` |
|---|---|---|
| 0 (today) | **20** | **80** |
| 3 | 50 | 50 |
| 6 (oldest) | **80** | **20** |

OLS sorts oldest→newest:
- Old → ys = [80, 70, 60, 50, 40, 30, 20] → **negative slope** → heuristic fires for account B as intended (regression guard active).
- New → ys = [20, 30, 40, 50, 60, 70, 80] → **positive slope** → heuristic does **not** fire for account B. Test still passes (account B gets zero scores) but for the wrong reason — neither account triggers the heuristic, so the assertion no longer guards against a tenant-leak bug.

The inline comment is correct ("d=0 today is the lowest CTR, d=6 oldest is the highest"); only the formula contradicts it.

**Fix:** restore the original `clicks = 80 - (6 - d) * 10`. Keep the explanatory comment as-is.

### WARNINGS

#### W-2 (PASS-2): `dedup_constraint_error?/1` duplicated byte-for-byte across both audit workers
**Files:**
- [lib/ad_butler/workers/budget_leak_auditor_worker.ex:402](../../../../lib/ad_butler/workers/budget_leak_auditor_worker.ex#L402)
- [lib/ad_butler/workers/creative_fatigue_predictor_worker.ex:371](../../../../lib/ad_butler/workers/creative_fatigue_predictor_worker.ex#L371)

**Source:** elixir-reviewer

Both workers already `alias AdButler.Workers.AuditHelpers`. Move the helper there to prevent silent divergence (e.g. a future change to also check `constraint_name`).

**Fix:** add `AuditHelpers.dedup_constraint_error?/1` (public, `@doc`'d), drop the local duplicates, update both call sites.

#### W-3 (PASS-2): S-3 assertion has an unreachable `nil` branch
**File:** [test/ad_butler/ads_test.exs:472](../../../../test/ad_butler/ads_test.exs#L472)
**Source:** testing-reviewer

The migration `20260430000001_add_quality_ranking_history_to_ads.exs` sets `default: %{"snapshots" => []}`, so every newly-inserted row gets the default — `quality_ranking_history` is never `nil` on a fresh row. The `in [nil, %{"snapshots" => []}]` assertion gives false confidence.

**Fix:** tighten to `assert reloaded.quality_ranking_history == %{"snapshots" => []}`.

### SUGGESTION

#### S-6 (PASS-2): `handle_create_result` arity inconsistency between workers
**Source:** elixir-reviewer

`BudgetLeakAuditorWorker.handle_create_result/3` takes `(result, ad_id, kind)`; `CreativeFatiguePredictorWorker.handle_create_result/2` takes `(result, ad_id)` with `kind: "creative_fatigue"` hardcoded in the log call. Both work in isolation. Bundle with W-2 — if `dedup_constraint_error?/1` moves to `AuditHelpers`, consider pulling `handle_create_result/3` there too with a consistent signature.

**Fix:** optional — extract to `AuditHelpers.handle_create_result/3` with a unified `(result, ad_id, kind)` signature.

---

## Resolved (verified by pass-2 agents)

- **W-1** (Finding `unique_constraint`) — verified against Ecto source; `dedup_constraint_error?/1` pattern matches the actual error tuple. All 4 oban-specialist evaluation points pass: idempotency on dedup race, non-dedup errors still halt-and-retry, no score divergence under concurrent execution, no test order dependency.
- **S-2** (`async: false` rationale) — comment now correctly cites DDL non-transactionality.
- **S-4** (`find_drop/4` ordering invariant) — comment in place.
- **S-5** (`Ads.unsafe_list_ad_ids_for_account/1`) — single-column query; `unsafe_*` naming + docstring match surrounding context conventions.

---

## Verification State

| Check | Result |
|---|---|
| `mix compile --warnings-as-errors` | ✓ |
| `mix format --check-formatted` | ✓ |
| `mix credo --strict` | ✓ (only the 2 OOS pre-existing issues) |
| `mix check.unsafe_callers` | ✓ |
| `mix test` | ✓ 395 tests, 0 failures |

The test suite passes despite B-1 because **the test's negative assertion still holds for the wrong reason** — exactly the silent-failure mode B-1 calls out. A correct implementation needs to fail the test deliberately to confirm the heuristic fires for account B before the scope filter is applied (the test should be a regression guard against future tenant-leak bugs).
