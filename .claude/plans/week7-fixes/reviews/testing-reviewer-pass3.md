# Pass 3 — Testing Reviewer

**Verdict: PASS — both pass-2 findings resolved. One new SUGGESTION (regression-guard precondition).**

## B-1 — RESOLVED

Formula at line 483: `clicks = 80 - (6 - d) * 10` enumerates correctly:
- d=0 (today): 20, d=6 (6 days ago): 80
- OLS oldest→newest: [80, 70, 60, 50, 40, 30, 20] — descending, negative slope
- `heuristic_frequency_ctr_decay` fires for ad_b

Comment at lines 479–481 matches formula and heuristic semantics
exactly.

## W-3 — RESOLVED

Line 472: `assert reloaded.quality_ranking_history == %{"snapshots" => []}`.
Strict `==`, no nil branch, comment cites the migration default
explicitly.

## SUGGESTION (PASS-3): Regression-guard precondition

The tenant-isolation test's negative assertions (`score_count_b == 0`,
`finding_count_b == 0`) are logically sound because account B holds
non-zero firing-signal data — this is **not** a vacuous absence-pass.

But there is no machine-checkable precondition confirming the data
produces a firing slope. A future maintainer who tweaks the CTR-decay
threshold or fixture formula would see the negative assertions continue
to pass silently. This is exactly the failure mode captured in
`.claude/solutions/testing-issues/negative-assertion-test-passes-without-precondition-20260430.md`.

Two equally good options to make the precondition explicit:

**A. Pin data shape:**
```elixir
assert [80, 70, 60, 50, 40, 30, 20] ==
  Repo.all(from i in "insights_daily", where: i.ad_id == type(^ad_b.id, :binary_id),
           order_by: [asc: i.date_start], select: i.clicks)
```

**B. Pin firing behavior:**
```elixir
assert {:emit, _} = CreativeFatiguePredictorWorker.heuristic_frequency_ctr_decay(ad_b.id)
```

Option B is closer to the precondition the test claims; option A is
brittle to additive fixture changes. Either works. Low effort, high
value for future maintainers.

Severity: SUGGESTION. The test is correct as-is; this is a
defense-in-depth hardening that applies the lesson from the compound
doc to the very test that motivated writing it.
