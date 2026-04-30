---
module: "AdButler.Workers.CreativeFatiguePredictorWorkerTest"
date: "2026-04-30"
problem_type: testing_pattern
component: regression_guard
symptoms:
  - "Tenant-isolation test passes after a code change, but reviewer points out it would still pass if the worker were broken"
  - "Test asserts `count_for_other_tenant == 0` and remains green even when the heuristic that should fire for the other tenant no longer fires at all"
  - "A 'readability' refactor of test fixture data silently inverts the precondition the test relies on, but the test stays green"
  - "Originally-flagged code-review finding 'tenant isolation by absence' — test only proved the absence of data, not the presence of a working scope filter"
root_cause: "Negative assertions like `assert other_tenant_count == 0` hold whether the system-under-test (a) correctly filtered out other-tenant data OR (b) never had any other-tenant data to filter in the first place. A regression guard requires a *positive* precondition: the test must guarantee the SUT would produce a non-zero result *but for* the boundary being tested. Without verifying that precondition, a future refactor can break the precondition (no firing data) while the assertion remains green — the guard fails silently."
severity: high
tags: [testing, exunit, regression-guard, tenant-isolation, scope, fatigue-predictor, dead-test]
---

# Negative Assertions Need a Verified Positive Precondition

## Symptoms

Two forms of the same bug appeared in this codebase within a 30-day window:

1. **Original W9 review finding** ("tenant isolation by absence"): the test
   for `CreativeFatiguePredictorWorker` had account A run the audit and asserted
   *"account B's ads have zero findings."* But account B had no ads at all —
   so the assertion was true whether the scope filter worked or not.

2. **Pass-2 regression of S-1**: rewrote the test fixture for "readability"
   from `clicks = 80 - (6 - d) * 10` to `clicks = 20 + (6 - d) * 10` —
   numerically the same magnitudes but in inverted order. OLS slope flipped
   from negative to positive; `heuristic_frequency_ctr_decay` no longer
   fired for account B. The "account B has zero scores" assertion stayed
   green, but for the wrong reason: the heuristic itself was silent, not
   the scope filter.

In both cases, the test could not detect a tenant-leak regression.

## Investigation

1. **Run the test** — green.
2. **Mentally model what the test asserts and *why* it should be green** —
   "account B has 0 findings because the worker scoped to account A skipped
   account B's ads."
3. **Check whether that precondition holds** — for #1, account B had no
   ads, so there was nothing to skip; for #2, account B's ad fixture data
   produced a positive slope, so no heuristic fired.
4. **Mutate the SUT to verify the test catches it** — comment out the
   `where: ad_account_id == ^ad_account_id` clause, re-run. If the test
   still passes, it is not actually guarding the boundary.

## Root Cause

A negative assertion alone is not a regression guard. It must be paired
with a **verified positive precondition**:

> *"In the absence of the boundary check, this assertion would FAIL."*

For `assert other_tenant.count == 0` to guard the scope filter:
- The other tenant MUST have data that *would* be returned without the
  filter.
- That data MUST be of a shape that triggers whatever the SUT does
  (heuristic firing, query matching, etc.).
- A reviewer or future maintainer should be able to mutate the SUT and
  see the test fail.

Without that, the test is a *dead guard* — passes today, will pass
forever, regardless of whether the code is correct.

## Solution

### Pattern: assert *both* directions

If feasible, structure the test as:

```elixir
test "scope filter prevents account A's run from touching account B's ads" do
  # 1. Seed account A with NON-firing data (clean baseline).
  # 2. Seed account B with FIRING data — the heuristic WOULD emit if audited.
  # 3. (Optional belt-and-braces) sanity-check that the heuristic fires
  #    for account B in isolation, OUTSIDE the scoped run:
  assert {:emit, _} = Worker.heuristic_frequency_ctr_decay(ad_b.id)

  # 4. Run the worker for account A only.
  assert :ok = perform_job(Worker, %{"ad_account_id" => account_a.id})

  # 5. Assert account B remains untouched.
  assert Repo.aggregate(scope_b, :count) == 0
end
```

The optional sanity-check at step 3 makes the precondition explicit and
will fail if a fixture refactor breaks the firing data.

### Pattern: verify with `git diff` arithmetic

When refactoring test fixture data "for readability":

```
Old: clicks = 80 - (6 - d) * 10   # d=0 → 20, d=6 → 80
New: clicks = 20 + (6 - d) * 10   # d=0 → 80, d=6 → 20  ← REVERSED
```

Always enumerate `d=0..N` for both the old and new formulas before
declaring the rewrite "numerically equivalent." Reordered arithmetic is
not commutative when downstream consumes order (here, OLS over a
date-sorted series).

### Files Changed

- `test/ad_butler/workers/creative_fatigue_predictor_worker_test.exs` — restored
  `clicks = 80 - (6 - d) * 10`; comment now describes actual values

## Prevention

- [ ] Whenever you write `assert other_thing.count == 0` or
      `refute Foo.includes?(bar)`, add a comment naming the precondition
      that would, if absent, make this assertion trivially true.
- [ ] Better: add an in-test sanity check that the precondition holds
      (e.g. `assert {:emit, _} = run_heuristic_directly(other_thing.id)`).
- [ ] During code review, mentally mutate the SUT — comment out the
      boundary check the test claims to guard. If the test still passes,
      the test is the bug.
- [ ] When "refactoring for readability" any arithmetic in test
      fixtures, enumerate the values for `d=0..N` (or the relevant
      range) for BOTH the old and new formulas. Same magnitudes ≠ same
      order; downstream consumers of ordered data care about both.
- [ ] Apply this lesson retroactively when a code review flags "test
      passes by absence" — it's almost always a special case of this
      class of bug.

## Related

- Plan triage: `.claude/plans/v0.3-creative-fatigue-chat-mvp/reviews/week7-triage.md` (W9: tenant isolation by absence)
- Pass-2 review: `.claude/plans/week7-fixes/reviews/week7-fixes-pass2-review.md` (B-1: CTR slope inversion)
- ExUnit pattern: any `refute` / `assert == 0` / `assert == nil` is a candidate for this class of bug.
