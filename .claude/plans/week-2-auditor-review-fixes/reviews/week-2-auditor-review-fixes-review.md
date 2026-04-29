# Review: week-2-auditor-review-fixes

**Branch:** v2-week-2Auditor-Findings
**Verdict:** REQUIRES CHANGES
**Issues:** 6 BLOCKERs · 8 WARNINGs · 5 SUGGESTIONs

---

## BLOCKERs

### B1 — `Repo` called directly inside Oban worker
**Files:** `lib/ad_butler/workers/budget_leak_auditor_worker.ex:132,152,163`
`load_48h_insights/1`, `build_ad_set_map/1`, and `load_stalled_learning_ad_sets/1` all call `Repo` directly from the worker. CLAUDE.md: "Repo is only ever called from inside a context module." These three reads must move into `AdButler.Ads` or `AdButler.Analytics` as properly named context functions.
**Flagged by:** elixir-reviewer (BLOCKER) + iron-law-judge (CRITICAL — confirmed)

### B2 — `maybe_emit_finding/3` errors silently swallowed
**File:** `lib/ad_butler/workers/budget_leak_auditor_worker.ex:~117`
`fire_if_triggered/4` calls `maybe_emit_finding/3` for side-effect only. If `Analytics.create_finding/1` fails, the worker logs the error but continues and returns `:ok` — Oban marks the job completed even though findings were not persisted. The `{:error, reason}` must propagate through `run_heuristics`/`fire_if_triggered` into the `reduce_while` accumulator.
**Flagged by:** oban-specialist (BLOCKER)

### B3 — `unique:` not baked into `BudgetLeakAuditorWorker`
**File:** `lib/ad_butler/workers/budget_leak_auditor_worker.ex:11`
Uniqueness is only applied at the `Oban.Worker.new/2` call site in `AuditSchedulerWorker`. Any future caller (backfill, manual enqueue) that omits the option will create duplicate jobs. Move to the module declaration:
```elixir
use Oban.Worker,
  queue: :audit,
  max_attempts: 3,
  unique: [period: 21_600, keys: [:ad_account_id]]
```
**Flagged by:** oban-specialist (BLOCKER) + iron-law-judge (SUGGESTION — upgraded)

### B4 — `analytics_test.exs` compile error: missing `import Ecto.Query`
**File:** `test/ad_butler/analytics_test.exs:174`
`from/2` is used in the "returns nil after finding is resolved" test but `import Ecto.Query` is absent. This will fail to compile. Add the import after the alias block.
**Flagged by:** testing-reviewer (BLOCKER)

### B5 — `FindingsLive` filter/paginate events untested
**File:** `test/ad_butler_web/live/findings_live_test.exs`
`handle_event("filter_changed", ...)` and `handle_event("paginate", ...)` have zero coverage. Only URL-param navigation via `handle_params` is tested. Both event callbacks must have at least one test using `render_change` / `render_click`.
**Flagged by:** testing-reviewer (BLOCKER)

### B6 — `FindingDetailLive` acknowledge error branch untested
**File:** `test/ad_butler_web/live/finding_detail_live_test.exs`
The flash-error path when `Analytics.acknowledge_finding` returns `{:error, _}` has no test. Success path is covered; error path is not.
**Flagged by:** testing-reviewer (BLOCKER)

---

## WARNINGs

### W1 — `get_latest_health_score/1` unscoped — latent tenant leak
**File:** `lib/ad_butler/analytics.ex:123`
The function takes only `ad_id` with no user/MetaConnection scope. Safe today because `FindingDetailLive` always calls `get_finding!(current_user, id)` first, but a future call site could leak health scores across tenants. Either add a `User` parameter with scope join, or document in `@doc` that callers must verify ownership first.
**Flagged by:** elixir-reviewer (BLOCKER) + iron-law-judge (WARNING/LIKELY — call site safe today)

### W2 — N+1 query in `check_cpa_explosion`
**File:** `lib/ad_butler/workers/budget_leak_auditor_worker.ex:~220`
`Ads.unsafe_get_30d_baseline/1` is called per-ad inside the heuristic loop — one DB round-trip per ad. Preload all baselines for the account before `Enum.reduce` (same pattern as `build_ad_set_map/1` and `load_stalled_learning_ad_sets/1`).
**Flagged by:** oban-specialist (WARNING)

### W3 — `upsert_ad_health_score` is a plain insert, not an upsert
**File:** `lib/ad_butler/analytics.ex:114-119`
Name says upsert; implementation calls `Repo.insert/1`. Rename to `insert_ad_health_score/1`. Each retry of `BudgetLeakAuditorWorker` appends duplicate rows — document whether append-only history is intentional.
**Flagged by:** elixir-reviewer (WARNING) + oban-specialist (WARNING — merged)

### W4 — `Oban.insert_all/1` return discarded in `AuditSchedulerWorker`
**File:** `lib/ad_butler/workers/audit_scheduler_worker.ex:30`
If the DB insert fails during fan-out, the scheduler returns `:ok` and zero auditor jobs are enqueued with no signal to Oban to retry. Handle or log the return value.
**Flagged by:** oban-specialist (WARNING)

### W5 — DB query fires on disconnected render in `FindingsLive.handle_params`
**File:** `lib/ad_butler_web/live/findings_live.ex:53`
`handle_params` fires during both the disconnected HTTP render and the connected WebSocket phase, causing `paginate_findings` to run twice on initial page load. Guard with `if connected?(socket)` or return the empty-stream skeleton on disconnected render.
**Flagged by:** iron-law-judge (SUGGESTION — upgraded; double-query on every page load is a real perf concern)

### W6 — Stale `ad_accounts_list` never refreshes
**File:** `lib/ad_butler_web/live/findings_live.ex:56-60`
```elixir
case socket.assigns.ad_accounts_list do
  [] -> load ...
  existing -> existing
end
```
The account list never refreshes after the first `handle_params`. If the user connects a new ad account in another tab, the filter dropdown stays stale. Load unconditionally or subscribe to a PubSub topic.
**Flagged by:** elixir-reviewer (WARNING)

### W7 — `Float.round` used for money formatting in finding body
**File:** `lib/ad_butler/workers/budget_leak_auditor_worker.ex:199,228`
`total_spend` is integer cents — use integer arithmetic for formatting, not `Float.round/2`. CLAUDE.md prohibits floats for money values.
**Flagged by:** oban-specialist (WARNING)

### W8 — `@doc false` on a private function
**File:** `lib/ad_butler/workers/budget_leak_auditor_worker.ex:~361`
`@doc false` is meaningless on `defp` — it only applies to `def`. Remove it.
**Flagged by:** elixir-reviewer (WARNING)

---

## SUGGESTIONs

### S1 — Extract `severity_badge_class/1` and `kind_label/1` to shared helper
Both `FindingsLive` and `FindingDetailLive` duplicate these two private helpers. Extract to `AdButlerWeb.FindingHelpers` or a component module to avoid drift.
**Flagged by:** elixir-reviewer

### S2 — Add `timeout/1` to `AuditSchedulerWorker`
Lightweight but adds an explicit bound. Protects against slow `list_ad_accounts_by_mc_ids/1` under large tenant load.
**Flagged by:** oban-specialist (SUGGESTION)

### S3 — Missing heuristic skip-path tests
`placement_drag` has no skip test (single placement, ratio < 3x). `dead_spend` has no test for the reach-uplift guard (growing reach should skip even with zero conversions).
**Flagged by:** testing-reviewer (WARNING — kept as SUGGESTION since heuristics are otherwise covered)

### S4 — Uniqueness test exercises override, not worker config
`audit_scheduler_worker_test.exs` passes `unique:` opts explicitly to `BudgetLeakAuditorWorker.new/2`, overriding the worker's built-in config. Remove the explicit opts so the test validates the worker's own declaration.
**Flagged by:** testing-reviewer (WARNING)

### S5 — Tag `with` clauses in `check_cpa_explosion`
`with true <- boolean` works but the `else _ -> :skip` catch-all hides which clause failed. Tag each clause (e.g. `{:conversions, true} <- {:conversions, conversions_3d > 0}`) for debuggability.
**Flagged by:** elixir-reviewer (SUGGESTION)

---

## Pre-existing (not introduced by this branch)

- `insights_pipeline.ex:118` — Credo [F] function nesting depth — pre-existing, unrelated to this feature

---

## Clean

- `AuditSchedulerWorker` cron stagger, string args keys, and structured logging are all correct.
- `Finding` and `AdHealthScore` schemas: correct types, `@moduledoc`/`@doc` present.
- `FindingDetailLive.handle_event("acknowledge")`: scoped auth via `current_user` → context delegation is correct.
- `FindingsLive`: streams, `@per_page 50`, `push_patch` for filters/pagination — correct.
- No DaisyUI component classes detected.
- `check.unsafe_callers` passes: no `Ads.unsafe_*` called from web layer.
- 306 tests, 0 failures.
