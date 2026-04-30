# Week 7 Review-Fixes — Pass 3 Consolidated Review

**Plan:** [.claude/plans/week7-fixes/plan.md](../plan.md)
**Pass-2 review:** [week7-fixes-pass2-review.md](week7-fixes-pass2-review.md)
**Pass-2 triage:** [week7-fixes-pass2-triage.md](week7-fixes-pass2-triage.md)
**Verdict:** PASS WITH WARNINGS (1 SUGGESTION)
**Reviewers:** elixir-reviewer (PASS, no new), testing-reviewer (PASS, 1 SUGGESTION)

## Summary

The pass-2 BLOCKER (B-1, formula inversion) and both WARNINGS (W-2 helper
duplication, W-3 unreachable nil branch) are resolved and verified.
S-6 (handle_create_result arity inconsistency) remains deferred —
confirmed safe to defer; the asymmetry is intentional (one worker emits
one finding kind, the other emits multiple).

One new SUGGESTION surfaces — a defense-in-depth hardening of the
tenant-isolation test, applying the lesson from the compound doc
written this session.

---

## Findings

### SUGGESTION

#### S-7 (PASS-3): Regression-guard test could pin its firing precondition explicitly
**File:** [test/ad_butler/workers/creative_fatigue_predictor_worker_test.exs ~line 518](../../../../test/ad_butler/workers/creative_fatigue_predictor_worker_test.exs#L518)
**Source:** testing-reviewer

The tenant-isolation test seeds account B with firing data so the
negative `score_count_b == 0` assertion is non-vacuous (this is what
B-1 was about). However, no machine-checked precondition verifies the
firing data actually fires the heuristic. A future fixture refactor or
threshold tweak could break that precondition silently — exactly the
failure mode B-1 hit and the failure mode the new compound doc
([negative-assertion-test-passes-without-precondition-20260430.md](../../../solutions/testing-issues/negative-assertion-test-passes-without-precondition-20260430.md))
calls out.

**Two equally good fixes:**

A. Pin data shape:
```elixir
assert [80, 70, 60, 50, 40, 30, 20] ==
  Repo.all(from i in "insights_daily", where: i.ad_id == type(^ad_b.id, :binary_id),
           order_by: [asc: i.date_start], select: i.clicks)
```

B. Pin firing behavior:
```elixir
assert {:emit, _} = CreativeFatiguePredictorWorker.heuristic_frequency_ctr_decay(ad_b.id)
```

Option B more directly verifies the precondition the test relies on.
Option A is mechanical and doesn't depend on the heuristic's internals.

**Why this is a SUGGESTION not a WARNING:** the test is correct
today. This is preventive — applying the institutional lesson to the
test that motivated writing it.

---

## Resolved (verified by pass-3 agents)

- **B-1**: Formula `clicks = 80 - (6 - d) * 10` produces oldest=80,
  today=20 → negative slope → heuristic fires. Comment matches formula.
- **W-2**: `AuditHelpers.dedup_constraint_error?/1` is the single
  canonical implementation; both workers call it; no local copies
  remain. `@moduledoc false` + `@doc` consistency confirmed compliant
  (already established in pass-2).
- **W-3**: Strict `== %{"snapshots" => []}` assertion replaces the
  unreachable `in [nil, ...]` branch. Comment cites the migration
  default.

## Deferred (carried forward from pass-2)

- **S-6**: `handle_create_result/N` arity inconsistency between the two
  workers. Pass-3 elixir-reviewer confirmed this is intentional (one
  worker varies kind per heuristic, the other emits one fixed kind) and
  safe to defer indefinitely.

---

## Verification State

| Check | Result |
|---|---|
| `mix compile --warnings-as-errors` | ✓ |
| `mix format --check-formatted` | ✓ |
| `mix credo --strict` | ✓ (only the 2 OOS pre-existing) |
| `mix check.unsafe_callers` | ✓ |
| `mix hex.audit` | ✓ |
| `mix test` | ✓ 395 tests, 0 failures |
