# Triage: week-2-auditor-post-review

**Fix Queue: 11 items · Skipped: 0 · Deferred: 0**

---

## Fix Queue

### Auto-approved (Iron Law violations)

- [ ] B2 — `FindingDetailLive.handle_params/3` runs DB queries on disconnected mount
  - `lib/ad_butler_web/live/finding_detail_live.ex:23-34`
  - Wrap body with `if connected?(socket), do: ..., else: {:noreply, socket}`

- [ ] B3 — `get_finding!/2` raises uncaught from `handle_params/3` — no graceful redirect
  - `lib/ad_butler_web/live/finding_detail_live.ex:25`
  - Add `Analytics.get_finding/2 → {:ok, f} | {:error, :not_found}`; handle error with `push_navigate + flash`

- [ ] W2 — `get_latest_health_score/1` not prefixed `unsafe_`
  - `lib/ad_butler/analytics.ex:122-136`
  - Rename to `unsafe_get_latest_health_score/1`; update all call sites

### User-approved (Blockers)

- [ ] B1 — `Oban.insert_all/1` return type misunderstood — failure detection broken
  - `lib/ad_butler/workers/audit_scheduler_worker.ex:23-33`
  - Split_with on changeset validity; log invalids; pass only valid to insert_all

### User-approved (Warnings)

- [ ] W1 — `with true <-` misuse in `check_cpa_explosion` and `check_placement_drag`
  - `lib/ad_butler/workers/budget_leak_auditor_worker.ex:174, 242`
  - Refactor `with true <- cond` to explicit `if`; move plain `=` assigns to `do` body; use `[_, _ | _] = placements` guard

- [ ] W3 — `insert_health_scores` not idempotent — retries produce duplicate rows
  - `lib/ad_butler/workers/budget_leak_auditor_worker.ex:71`
  - Upsert with `on_conflict: {:replace, [:leak_score, :leak_factors]}, conflict_target: [:ad_id, :computed_at]`; round `computed_at` to 6h window

- [ ] W4 — `handle_info(:reload_on_reconnect)` duplicates `handle_params` logic
  - `lib/ad_butler_web/live/findings_live.ex:111`
  - Extract private `load_findings(socket)` helper used by both callbacks

- [ ] W5 — `_ = Ads` unused alias in `FindingDetailLive`
  - `lib/ad_butler_web/live/finding_detail_live.ex`
  - Remove the alias

- [ ] W6 — "Growing reach" skip test passes vacuously
  - `test/ad_butler/workers/budget_leak_auditor_worker_test.exs:90`
  - Fix test so the materialized view actually has data; validate guard logic directly

### User-approved (Suggestions)

- [ ] CT1+CT2 — Cross-tenant `acknowledge` event tests missing
  - `test/ad_butler_web/live/finding_detail_live_test.exs`
  - `test/ad_butler/analytics_test.exs`
  - CT1: test user B cannot send `"acknowledge"` against user A's finding via `render_click`
  - CT2: test `acknowledge_finding(user_b, finding_a.id)` raises/errors

- [ ] O4+WT2 — Redundant `unique:` override in worker and test
  - `lib/ad_butler/workers/audit_scheduler_worker.ex:27-29`
  - `test/ad_butler/workers/audit_scheduler_worker_test.exs`
  - Remove `unique:` from `BudgetLeakAuditorWorker.new/2` call in scheduler; update test to call `new(%{"ad_account_id" => aa.id})` without opts

---

## Skipped
None.

## Deferred
None.
