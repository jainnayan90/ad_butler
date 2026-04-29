# Testing Review: week-2-auditor-post-review

⚠️ EXTRACTED FROM AGENT MESSAGE (agent denied Write access)

## Summary
Generally solid structure. Several coverage gaps and one logically suspect test.

---

## Critical

### CT1 — No cross-tenant `acknowledge` event test
`finding_detail_live_test.exs` — Tenant isolation test only covers the mount path (raises on `live/2` with wrong user). Does NOT test that user B cannot send `"acknowledge"` against user A's finding. The `handle_event("acknowledge")` calls `get_finding!/2` with the authenticated user, which prevents this — but the test should explicitly verify it. Add: `render_click(view, "acknowledge")` with a different user and assert the error.

### CT2 — `acknowledge_finding/2` cross-tenant denial untested in analytics_test
`analytics_test.exs` — `get_finding!` cross-tenant is tested. `acknowledge_finding(user_b, finding_a.id)` is not. It's a security-critical path.

### CT3 — B6 error flash zero test coverage (known gap)
`acknowledge_finding/2` `{:error, changeset}` branch and the LiveView flash display are untested. Requires Analytics behaviour + Mox. Behaviour does not exist.

---

## Warnings

### WT1 — "Growing reach" skip test may pass vacuously
`budget_leak_auditor_worker_test.exs:90` — The `REFRESH MATERIALIZED VIEW` in setup runs before `insert_insight`, so the 30d view is empty. The worker sees no insights data and trivially skips before reaching the reach-uplift guard. The test does not validate the intended guard logic.

### WT2 — Unique opts reimplemented in test instead of using worker's declared config
`audit_scheduler_worker_test.exs` — Test passes `unique: [period: 21_600, keys: [:ad_account_id]]` to `BudgetLeakAuditorWorker.new/2`. Should call `new/1` with no opts to exercise the module-level `unique:` config.

### WT3 — Global `setup` refresh precedes data insertion
`budget_leak_auditor_worker_test.exs:16` — All tests relying on 30d view data must refresh again explicitly (CPA test does; others silently don't need it). Add a clarifying comment.

### WT4 — `_ = mc` unused variable suppression in 3 test bodies
`findings_live_test.exs:56, 83, 174` — Remove `mc` from pattern match or use `%{mc: _mc}`.

### WT5 — Stalled learning boundary (exactly 7 days) untested
Only `days_ago = 8` covered. Test with exactly 7 days to clarify `< 7` vs `<= 7` semantics.

### WT6 — No multi-heuristic cumulative score test
Scoring `describe` block tests only `dead_spend` alone. No test for two simultaneous heuristics + capped score.

---

## Suggestions

- Pagination test only checks count string ("52 findings") — assert a specific page-2 title
- `insert_ad_health_score/1` error path not directly tested (only via integration)
- `get_unresolved_finding/2` "no finding" test uses nonexistent UUID; add a case with resolved finding
