# Plan: Week 2 Auditor — Review Fixes

**Branch:** `v2-week-2Auditor-Findings`
**Source:** `week-2-auditor-findings` review triage — 5 BLOCKERs + 6 WARNINGs
**Depth:** Standard

---

## What We're Fixing

Post-review fixes for the BudgetLeakAuditorWorker + AuditSchedulerWorker + FindingsLive implementation.
No new features — surgical corrections only.

---

## Architecture Decisions

- **B3 fix uses `Oban.insert_all/1`** — matches `token_refresh_sweep_worker.ex` and `sync_all_connections_worker.ex` existing pattern.
- **W3 changeset split** — `create_changeset/2` for content fields only; `acknowledge_changeset/2` takes `user_id` directly (no user-supplied map). Both called from `Analytics` context, not from the web layer.
- **B1 error propagation** — `audit_account/1` returns `{:error, reason}` on first health-score DB failure; subsequent ads in the same job are skipped. Oban retries the whole job (idempotent via `get_unresolved_finding` dedup).
- **W1 dead handler** — wire `send(self(), :reload_on_reconnect)` in `connected?` guard; don't delete the handler (it's a reconnect reload pattern worth keeping).

---

## Phase 1 — Oban Worker Fixes (B1, B2, B3, W4, W5)

### Phase 1 Tasks

- [x] [P1-T1][oban] **B1 — Fix silent DB failure in `audit_account/1`** — Enum.reduce_while, halts on first {:error}, propagates to Oban for retry
  File: `lib/ad_butler/workers/budget_leak_auditor_worker.ex:63-72`
  - Replace `Enum.each(fired_by_ad, ...)` with `Enum.reduce_while` that stops on first `{:error, reason}`
  - Return `{:error, reason}` from `audit_account/1` when any `Analytics.upsert_ad_health_score/1` fails
  - `perform/1` propagates the error tuple so Oban reschedules

- [x] [P1-T2][oban] **B2 — Add `unique:` to `AuditSchedulerWorker`** — unique: [period: 21_600]
  File: `lib/ad_butler/workers/audit_scheduler_worker.ex:9`
  - Change: `use Oban.Worker, queue: :audit, max_attempts: 3, unique: [period: 21_600]`

- [x] [P1-T3][oban] **B3 — Replace individual inserts with `Oban.insert_all/1`** — Enum.map then Oban.insert_all/1
  File: `lib/ad_butler/workers/audit_scheduler_worker.ex:23-27`
  - Replace `Enum.each(ad_accounts, fn aa -> ... |> Oban.insert() end)` with:
    ```elixir
    ad_accounts
    |> Enum.map(fn aa ->
      BudgetLeakAuditorWorker.new(
        %{"ad_account_id" => aa.id},
        unique: [period: 21_600, keys: [:ad_account_id]]
      )
    end)
    |> Oban.insert_all()
    ```

- [x] [P1-T4][oban] **W4 — Stagger cron schedule to avoid token-refresh collision** — "3 */6 * * *"
  File: `config/config.exs:145`
  - Change `AuditSchedulerWorker` cron from `"0 */6 * * *"` to `"3 */6 * * *"`

- [x] [P1-T5][oban] **W5 — Add `timeout/1` to `BudgetLeakAuditorWorker`** — :timer.minutes(10)
  File: `lib/ad_butler/workers/budget_leak_auditor_worker.ex` (after `use Oban.Worker`)
  ```elixir
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)
  ```

---

## Phase 2 — Changeset Split (W3)

- [x] [P2-T1][ecto] **W3 — Split `Finding.changeset/2` into role-specific changesets** — create_changeset/2 + acknowledge_changeset/2; analytics.ex updated
  File: `lib/ad_butler/analytics/finding.ex`
  - Rename existing `changeset/2` to `create_changeset/2`, casting only `[:ad_id, :ad_account_id, :kind, :severity, :title, :body, :evidence]` (remove lifecycle fields from cast list)
  - Add `acknowledge_changeset/2`:
    ```elixir
    @doc "Builds a changeset for acknowledging a finding."
    @spec acknowledge_changeset(t(), binary()) :: Ecto.Changeset.t()
    def acknowledge_changeset(finding, user_id) do
      change(finding,
        acknowledged_at: DateTime.utc_now(),
        acknowledged_by_user_id: user_id
      )
    end
    ```
  - Update `analytics.ex`:
    - `create_finding/1`: call `Finding.create_changeset/2`
    - `acknowledge_finding/2`: call `Finding.acknowledge_changeset(finding, user.id)` instead of building an attrs map

---

## Phase 3 — Test Fixes (B4, B5, W2)

- [x] [P3-T1][test] **B4 — Add `stalled_learning` tests** — 3 tests: trigger, skip-sufficient-conversions, skip-not-learning; Repo.update_all to backdate updated_at
  File: `test/ad_butler/workers/budget_leak_auditor_worker_test.exs`
  - Add `describe "stalled_learning heuristic"` block:
    - **Trigger**: insert ad_set with `raw_jsonb["effective_status"] = "LEARNING"`, `updated_at` 8 days ago; sum conversions for its ads < 50 → assert `stalled_learning` finding created
    - **Skip (sufficient conversions)**: same LEARNING ad_set but seed ≥ 50 conversions in 7d → assert no finding
    - **Skip (not LEARNING)**: ad_set with `effective_status = "ACTIVE"` → no finding
  - Note: `updated_at` must be explicitly set in the factory/insert — check AdSet schema for `updated_at` writability

- [x] [P3-T2][test] **B5 — Fix acknowledge test to assert DB persistence** — Repo.get! after render_click, asserts acknowledged_at and acknowledged_by_user_id
  File: `test/ad_butler_web/live/finding_detail_live_test.exs:56-68`
  - After `render_click(view, "acknowledge")`, add:
    ```elixir
    persisted = Repo.get!(AdButler.Analytics.Finding, finding.id)
    assert persisted.acknowledged_at != nil
    assert persisted.acknowledged_by_user_id == user.id
    ```
  - Add `alias AdButler.Repo` if not present

- [x] [P3-T3][test] **W2 — Add `cpa_explosion` trigger-path test** — creates prev-week partition, seeds baseline (CPA=1000), refreshes view, seeds recent (CPA=5000), asserts finding
  File: `test/ad_butler/workers/budget_leak_auditor_worker_test.exs`
  - Add to `describe "cpa_explosion heuristic"`:
    - Seed ad insights with `spend_cents: 10_000, conversions: 2` (CPA = 5000 cents)
    - Seed `ad_insights_30d` baseline CPA at 1000 cents (requires mat view refresh or direct `Repo.insert_all` on the view's underlying data)
    - Assert `cpa_explosion` finding created
  - Note: `Ads.unsafe_get_30d_baseline/1` reads from `ad_insights_30d` mat view; REFRESH inside setup as already done for dead_spend tests

---

## Phase 4 — LiveView + Code Quality (W1, W6)

- [x] [P4-T1][liveview] **W1 — Wire `reload_on_reconnect` in `FindingsLive` mount** — if connected?(socket), do: send(self(), :reload_on_reconnect)
  File: `lib/ad_butler_web/live/findings_live.ex:20-33`
  - Add after the stream/assign chain in `mount/3`:
    ```elixir
    if connected?(socket), do: send(self(), :reload_on_reconnect)
    ```

- [x] [P4-T2][test] **W6 — Fix missing aliases in `audit_scheduler_worker_test.exs`** — added alias Repo + import Ecto.Query at top; removed inline import
  File: `test/ad_butler/workers/audit_scheduler_worker_test.exs`
  - Add `alias AdButler.Repo` and `import Ecto.Query` to module top-level (after `use`/`import` blocks)
  - Remove inline `import Ecto.Query` at line 108

---

## Phase 5 — Verification

- [x] [P5-T1] `mix format` — all changed files
- [x] [P5-T2] `mix compile --warnings-as-errors`
- [x] [P5-T3] `mix credo --strict` — 1 pre-existing [F] in insights_pipeline.ex (exit 8, same as before this plan)
- [x] [P5-T4] `mix test test/ad_butler/workers/ test/ad_butler_web/live/ test/ad_butler/analytics_test.exs` — 103 tests, 0 failures
- [x] [P5-T5] `mix test` — 306 tests, 0 failures, 8 excluded

---

## Risks

1. **`stalled_learning` test difficulty** — `load_stalled_learning_ad_sets/1` queries `AdSet.raw_jsonb->>'effective_status'` and `updated_at < now() - 7 days`. Must set `updated_at` explicitly on insert; ExMachina factories set `updated_at` via `NaiveDateTime.utc_now()`, so override will be needed via `Repo.update_all` or explicit `Repo.insert`.

2. **`cpa_explosion` trigger test** — The 30d baseline comes from the `ad_insights_30d` materialized view. There is no direct insert path — data must be in `insights_daily` and the mat view refreshed. The `setup` block already does `REFRESH MATERIALIZED VIEW ad_insights_30d`, so seeding 30d-ago data in `insights_daily` (with `date_start` in the past 30 days) should surface in the view after refresh.

3. **`Oban.insert_all/1` return** — Returns `{:ok, [%Oban.Job{}]}` not a list. The existing scheduler `perform/1` returns `:ok` after the loop — confirm `Oban.insert_all/1` doesn't raise on uniqueness conflict (it shouldn't; unique jobs return `conflict? true`).
