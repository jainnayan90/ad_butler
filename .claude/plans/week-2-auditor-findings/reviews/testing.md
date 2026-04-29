# Testing Review — week-2-auditor-findings
⚠️ EXTRACTED FROM AGENT MESSAGE (agent had no Write permission)

## Summary
Good overall — tenant isolation end-to-end, Oban patterns correct, factory graph consistent. 2 BLOCKERs, 3 WARNINGs, 3 SUGGESTIONs.

---

## BLOCKERs

### `stalled_learning` heuristic has zero test coverage
`test/ad_butler/workers/budget_leak_auditor_worker_test.exs` — covers dead_spend, cpa_explosion (skip path only), bot_traffic, placement_drag, but `stalled_learning` is entirely absent. Worker implements it with weight 3. Both trigger and skip paths required per CLAUDE.md.

### Acknowledge test only verifies HTML, not DB state
`test/ad_butler_web/live/finding_detail_live_test.exs:56-68` — `render_click(view, "acknowledge")` asserts HTML shows "Acknowledged" but never asserts `Repo.get!(Finding, finding.id).acknowledged_at`. A bug that updates assigns without persisting would pass this test.

---

## WARNINGs

### `filter_changed` handle_event never tested via `render_change`
`test/ad_butler_web/live/findings_live_test.exs` — filters tested via URL params only. `handle_event("filter_changed", ...)` code path is not exercised. Add `render_change(view, "filter_changed", %{"severity" => "high"})`.

### `cpa_explosion` only has a skip-path test
No test for the trigger path. Add a test with elevated 30d baseline CPA and verify a `cpa_explosion` finding is created.

### `audit_scheduler_worker_test.exs` uses `Repo` without aliasing
`Repo` called at lines 68 and 114 with no `alias AdButler.Repo` at module top-level. `import Ecto.Query` inline at line 108. Move both to module top-level.

---

## SUGGESTIONs

### Smoke test assertion is weak
`audit_scheduler_worker_test.exs:116`: `findings_count >= 1` — should be `== 1` to catch accidental duplication.

### `analytics_test.exs` bypasses context API to set resolved_at
Direct `Repo.update_all` to set `resolved_at`. Prefer factory `:resolved_at` override or a context-level function.

### Suppress `mc` warnings at source
`findings_live_test.exs:54, 84` use `_ = mc` to suppress warnings. Remove `mc` from pattern match entirely.
