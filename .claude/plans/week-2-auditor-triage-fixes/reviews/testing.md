# Test Review: week-2-auditor-triage-fixes

⚠️ EXTRACTED FROM AGENT MESSAGE (write was denied)

## Summary

Overall quality high. Tenant isolation present across all surfaces. `async: true/false` choices correct. No `Process.sleep`. Two notable gaps.

## Critical

- **`Analytics.get_finding/2` has no direct tests** (`analytics_test.exs`). The new public context function returning `{:ok, _} | {:error, :not_found}` has zero test cases. Need: (1) ok for owning user, (2) `:not_found` for cross-tenant, (3) `:not_found` for nonexistent ID.

## Warnings

- **Health score idempotency not tested** — `on_conflict` upsert not validated. Running worker twice within same bucket should produce exactly one row.
- **`async: false` undocumented** in both worker tests — one-line comment explaining materialized view constraint would prevent future regressions.
- **Unused `_ = mc` bindings** in `findings_live_test.exs` — cleanup noise.
- **Uniqueness test comment missing** — `BudgetLeakAuditorWorker.new/1` without opts implicitly depends on module-level `unique:` config; add a comment linking intent to the worker declaration.

## Suggestions

- Direct `Repo` call in `analytics_test.exs:191` — acceptable for test-setup but worth a comment noting it's intentional.
- `"user B cannot acknowledge user A's finding via context"` test in `finding_detail_live_test.exs` is a pure context test — more appropriate in `analytics_test.exs`.
