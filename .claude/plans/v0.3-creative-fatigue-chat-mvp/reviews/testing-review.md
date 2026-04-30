# Test Review — Week 7 Creative Fatigue

⚠️ EXTRACTED FROM AGENT MESSAGE (write tool unavailable in agent env)

## Summary

Five files reviewed. Oban patterns, tenant isolation, and LiveView testing are largely sound. Two blockers, six warnings, four suggestions.

---

## BLOCKER

### BLOCKER-1 — `Application.put_env` in kill-switch test is not fully serialized
`test/ad_butler/workers/audit_scheduler_worker_test.exs:40-41`

The kill-switch test writes `Application.put_env(:ad_butler, :fatigue_enabled, false)` with `on_exit` cleanup. `AuditSchedulerWorkerTest` is `async: false`, so it won't race itself — but if any other module running concurrently reads `:fatigue_enabled` during that window, it sees a corrupted value. The assumption that no other `async: true` module reads this key is silent and fragile.

**Fix:** Gate the kill-switch through a behaviour + mock (project-standard pattern), or at minimum add a comment that states this test requires global env ownership and must remain `async: false` across the whole suite.

### BLOCKER-2 — `analytics_test.exs` is `async: true` and calls `create_insights_partition` for the same calendar-week boundaries as the `async: false` worker tests
`test/ad_butler/analytics_test.exs:337-340, 396, 455-456` and `test/ad_butler/workers/creative_fatigue_predictor_worker_test.exs:69, 213-214, 279-280`

`create_insights_partition` is presumably `CREATE TABLE IF NOT EXISTS` (DDL, non-transactional in Postgres). If it is not idempotent against concurrent callers, two async test processes hitting it simultaneously will race. Confirm the SQL function body uses `IF NOT EXISTS` and add a comment in both setup blocks asserting that assumption.

---

## Warnings

### WARNING-1 — `insert_daily/3` duplicated across two files with schema divergence
`test/ad_butler/analytics_test.exs:11` vs `test/ad_butler/workers/creative_fatigue_predictor_worker_test.exs:74`

The analytics version includes `cpm_cents` and full `reach_count` from attrs; the worker version hard-codes `reach_count: 0` and omits `cpm_cents`. Extract into `test/support/insights_helpers.ex` with a single canonical implementation.

### WARNING-2 — `heuristic_cpm_saturation` test uses two-step insert+update_all
`test/ad_butler/workers/creative_fatigue_predictor_worker_test.exs:228-254`

Two-step seed/update pattern is harder to read than passing `spend_cents` directly to `insert_daily`. The helper already accepts `spend_cents`; use it directly.

### WARNING-3 — `audit_scheduler_worker_test.exs` smoke test uses inline `Repo.insert_all`
`test/ad_butler/workers/audit_scheduler_worker_test.exs:110-125`

A third copy of the partition insert pattern, omits `frequency`. Consolidate on the helper.

### WARNING-4 — Tenant isolation only tested at integration layer, not heuristic-function layer
`test/ad_butler/workers/creative_fatigue_predictor_worker_test.exs:463-498`

The scaffold contract test passes because account A has no ads — so account B's data is never queried. Passes by absence, not by genuine scoping. Add a test where account A *does* have ads, account B has separate ads with triggering signals, and running for account A never emits findings for account B's ads.

### WARNING-5 — Filter test asserts on UI copy
`test/ad_butler_web/live/findings_live_test.exs:122`

Asserts `html =~ "Creative Fatigue"`. Prefer asserting on a data attribute or the `kind` field value.

### WARNING-6 — Detail render test asserts exact template strings
`test/ad_butler_web/live/finding_detail_live_test.exs:131-133`

Asserts on `"frequency 4.5"` and `"above_average → average"`. Loosen for resilience to copy changes.

---

## Suggestions

### SUGGESTION-1 — Partition setup blocks repeated per describe block
`creative_fatigue_predictor_worker_test.exs:68-70, 212-215, 278-281`

A single `setup_all` block at module level would create the partitions once; DDL is not rolled back by the sandbox transaction anyway.

### SUGGESTION-2 — Factory chain repeated 10+ times
Extract into a named private helper `defp create_scoped_ad/1` called from a shared `setup` block in each describe.

### SUGGESTION-3 — `heuristic_frequency_ctr_decay` "fires" test seeds, deletes, then re-seeds
`creative_fatigue_predictor_worker_test.exs:102-114`

The first seed pass is unused. Remove it; seed the declining CTR data once.

### SUGGESTION-4 — Misleading describe heading
`analytics_test.exs:334`

Reads `"compute_ctr_slope/2 / get_7d_frequency/1"` but only contains `compute_ctr_slope` tests. Rename to `"compute_ctr_slope/2"`.
