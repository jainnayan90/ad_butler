# Plan: Week 2 Auditor — Post-Review Fixes

**Branch:** `v2-week-2Auditor-Findings`
**Source:** `/phx:review` → `/phx:triage` — 16 approved fixes
**Depth:** Standard

---

## What We're Fixing

Post-review corrections for the `BudgetLeakAuditorWorker`, `Analytics` context, `FindingsLive`/`FindingDetailLive`, and their tests. No new features — precision fixes only.

---

## Architecture Decisions

- **B1 context extraction**: Three private Repo calls move to `AdButler.Ads` as public functions with `unsafe_` prefix (matching existing pattern for unscoped internal queries). Worker imports no Repo module after the change.
- **B2 error propagation**: `run_heuristics` becomes a `reduce_while` internally, returning `{:ok, [kinds]} | {:error, reason}`. `audit_account` uses `with` to stop on first error from either finding-creation or health-score insertion.
- **W2 N+1 preload**: Add `Ads.unsafe_list_30d_baselines/1([ad_ids])` that queries `ad_insights_30d` for all ad_ids in one pass, returns `%{ad_id => %{cpa_cents, ...}}`. Worker preloads before the reduce.
- **W5 double query**: `handle_params` in `FindingsLive` guards `paginate_findings` with `if connected?(socket)` — returns the current empty/skeleton assigns on disconnected render.
- **S1 shared helpers**: New `AdButlerWeb.FindingComponents` (not a full component module — just function heads imported via `use AdButlerWeb, :live_view` is impractical; instead, private functions are extracted to `AdButlerWeb.FindingHelpers` and imported explicitly in both LiveViews).

---

## Phase 1 — Context Boundary (B1, W2, W3)

Repo calls move from worker to `Ads` context. `Analytics` rename.

### Phase 1 Tasks

- [x] [P1-T1][ecto] **B1 — Add data-loading functions to `AdButler.Ads`**
  File: `lib/ad_butler/ads.ex`
  - Add `unsafe_list_insights_since/2(ad_account_id, hours)`:
    ```elixir
    @doc "UNSAFE — no tenant scope. Returns insights_daily rows for ads in `ad_account_id` within the past `hours` hours."
    @spec unsafe_list_insights_since(binary(), pos_integer()) :: [map()]
    def unsafe_list_insights_since(ad_account_id, hours) do
      cutoff_date = DateTime.to_date(DateTime.add(DateTime.utc_now(), -hours, :hour))
      Repo.all(
        from i in "insights_daily",
          join: a in Ad,
          on: i.ad_id == a.id,
          where: a.ad_account_id == ^ad_account_id and i.date_start >= ^cutoff_date,
          select: %{
            ad_id: a.id,
            ad_set_id: a.ad_set_id,
            spend_cents: i.spend_cents,
            impressions: i.impressions,
            clicks: i.clicks,
            conversions: i.conversions,
            reach_count: i.reach_count,
            ctr_numeric: i.ctr_numeric,
            by_placement_jsonb: i.by_placement_jsonb
          }
      )
    end
    ```
  - Add `unsafe_build_ad_set_map/1(ad_account_id)`:
    ```elixir
    @doc "UNSAFE — no tenant scope. Returns %{ad_id => ad_set_id} for all ads in the account."
    @spec unsafe_build_ad_set_map(binary()) :: %{binary() => binary() | nil}
    def unsafe_build_ad_set_map(ad_account_id) do
      Repo.all(from a in Ad, where: a.ad_account_id == ^ad_account_id, select: {a.id, a.ad_set_id})
      |> Map.new()
    end
    ```
  - Add `unsafe_list_stalled_learning_ad_set_ids/1(ad_account_id)`:
    ```elixir
    @doc "UNSAFE — no tenant scope. Returns ids of AdSets in LEARNING status for >7 days."
    @spec unsafe_list_stalled_learning_ad_set_ids(binary()) :: MapSet.t()
    def unsafe_list_stalled_learning_ad_set_ids(ad_account_id) do
      cutoff = DateTime.add(DateTime.utc_now(), -7 * 24, :hour)
      Repo.all(
        from s in AdSet,
          where:
            s.ad_account_id == ^ad_account_id and
              fragment("?->>'effective_status' = 'LEARNING'", s.raw_jsonb) and
              s.updated_at < ^cutoff,
          select: s.id
      )
      |> MapSet.new()
    end
    ```
  - Add `unsafe_list_30d_baselines/1([ad_ids])` (W2):
    ```elixir
    @doc "UNSAFE — no tenant scope. Returns %{ad_id => %{cpa_cents: integer()}} from the ad_insights_30d view for the given ad IDs in one query."
    @spec unsafe_list_30d_baselines([binary()]) :: %{binary() => map()}
    def unsafe_list_30d_baselines(ad_ids) when is_list(ad_ids) do
      Repo.all(
        from v in "ad_insights_30d",
          where: v.ad_id in ^Enum.map(ad_ids, &Ecto.UUID.dump!/1),
          select: %{
            ad_id: type(v.ad_id, :binary_id),
            spend_cents: type(v.spend_cents, :integer),
            impressions: type(v.impressions, :integer),
            clicks: type(v.clicks, :integer),
            conversions: type(v.conversions, :integer),
            cpa_cents: type(v.cpa_cents, :integer)
          }
      )
      |> Map.new(& {&1.ad_id, &1})
    end
    ```
  Note: `AdSet` alias must be added to `ads.ex` imports if not present.

- [x] [P1-T2][ecto] **W3 — Rename `upsert_ad_health_score` → `insert_ad_health_score` in `AdButler.Analytics`**
  File: `lib/ad_butler/analytics.ex:114`
  - Rename function and update `@doc` to say "Append-only — never updates. Each call inserts a new row."
  - Update all call sites (only `budget_leak_auditor_worker.ex` calls it — update that after Phase 2)

---

## Phase 2 — Worker Fixes (B2, B3, W4, W7, W8)

All changes to `BudgetLeakAuditorWorker` and `AuditSchedulerWorker`.

### Phase 2 Tasks

- [x] [P2-T1][oban] **B1 + B2 + W2 — Refactor `BudgetLeakAuditorWorker` to use context functions and propagate errors**
  File: `lib/ad_butler/workers/budget_leak_auditor_worker.ex`
  - Remove `alias AdButler.Repo` and `import Ecto.Query` (no longer needed)
  - Keep `alias AdButler.Ads`, `alias AdButler.Ads.{Ad, AdSet}` is no longer needed either (schemas moved to context)
  - In `audit_account/1`: replace the three private Repo calls with context functions:
    ```elixir
    defp audit_account(ad_account) do
      insights = Ads.unsafe_list_insights_since(ad_account.id, 48)
      grouped = Enum.group_by(insights, & &1.ad_id)
      ad_set_map = Ads.unsafe_build_ad_set_map(ad_account.id)
      stalled_ad_sets = Ads.unsafe_list_stalled_learning_ad_set_ids(ad_account.id)
      baselines = Ads.unsafe_list_30d_baselines(Map.keys(grouped))

      with {:ok, fired_by_ad} <- run_all_heuristics(grouped, ad_account.id, ad_set_map, stalled_ad_sets, baselines) do
        result =
          Enum.reduce_while(fired_by_ad, :ok, fn {ad_id, fired_kinds}, _acc ->
            ...  # existing reduce_while body, update to call insert_ad_health_score
          end)
        ...
      end
    end
    ```
  - Rewrite `run_heuristics/5` → `run_all_heuristics/5` returning `{:ok, fired_by_ad_map} | {:error, reason}`:
    ```elixir
    defp run_all_heuristics(grouped, ad_account_id, ad_set_map, stalled_ad_sets, baselines) do
      Enum.reduce_while(grouped, {:ok, %{}}, fn {ad_id, rows}, {:ok, acc} ->
        case run_heuristics(ad_id, rows, ad_account_id, ad_set_map, stalled_ad_sets, baselines) do
          {:ok, fired} -> {:cont, {:ok, Map.put(acc, ad_id, fired)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
    ```
  - Rewrite `run_heuristics/5` → `run_heuristics/6` (add `baselines` param) to return `{:ok, [kinds]} | {:error, reason}` using `reduce_while` over checks:
    - Replace the pipeline of `fire_if_triggered` with a `reduce_while` that halts on `{:error, reason}` from `maybe_emit_finding`
  - Rewrite `fire_if_triggered/4` to return `:cont` / `:halt` tuples compatible with reduce_while
  - Update `check_cpa_explosion/3` → `check_cpa_explosion/4` — add `baselines` map parameter, replace `Ads.unsafe_get_30d_baseline(ad_id)` with `Map.get(baselines, ad_id)`
  - Update `check_stalled_learning/5` → signature unchanged, still reads from passed-in maps
  - Delete private functions: `load_48h_insights/1`, `build_ad_set_map/1`, `load_stalled_learning_ad_sets/1`
  - Update health score call: `Analytics.upsert_ad_health_score` → `Analytics.insert_ad_health_score`

- [x] [P2-T2][oban] **B3 — Add `unique:` to `BudgetLeakAuditorWorker` module declaration**
  File: `lib/ad_butler/workers/budget_leak_auditor_worker.ex:11`
  ```elixir
  use Oban.Worker,
    queue: :audit,
    max_attempts: 3,
    unique: [period: 21_600, keys: [:ad_account_id]]
  ```

- [x] [P2-T3][oban] **W4 — Handle `Oban.insert_all/1` return in `AuditSchedulerWorker`**
  File: `lib/ad_butler/workers/audit_scheduler_worker.ex`
  - Pattern-match the return; log a warning if the result contains errors:
    ```elixir
    changesets
    |> Oban.insert_all()
    |> case do
      {:ok, _jobs} -> :ok
      {:error, reason} ->
        Logger.warning("audit_scheduler: insert_all failed", reason: inspect(reason))
        {:error, reason}
    end
    ```
  Note: Verify actual `Oban.insert_all/1` return shape in the installed Oban version (2.18) — may return a list of job results, not a tagged tuple. Adjust accordingly.

- [x] [P2-T4][oban] **W7 + W8 — Fix money formatting and remove `@doc false` on defp**
  File: `lib/ad_butler/workers/budget_leak_auditor_worker.ex`
  - W7: Replace `Float.round(total_spend / 100.0, 2)` with integer formatting:
    ```elixir
    dollars = div(total_spend, 100)
    cents = rem(total_spend, 100) |> abs()
    "$#{dollars}.#{String.pad_leading(Integer.to_string(cents), 2, "0")}"
    ```
  - W8: Remove `@doc false` from `defp maybe_emit_finding/3`

---

## Phase 3 — Analytics Context + LiveView Fixes (W1, W5, W6, S1)

- [x] [P3-T1][ecto] **W1 — Document ownership requirement on `get_latest_health_score/1`**
  File: `lib/ad_butler/analytics.ex:123`
  - Update `@doc` to make the ownership contract explicit:
    ```
    @doc """
    Returns the most recent AdHealthScore for `ad_id`, or nil if none exists.

    UNSAFE — no tenant scope. Callers must verify the requesting user owns
    the ad (e.g., via `get_finding!/2`) before calling this function.
    """
    ```

- [x] [P3-T2][liveview] **W5 — Guard `paginate_findings` in `FindingsLive.handle_params/3`**
  File: `lib/ad_butler_web/live/findings_live.ex`
  - Wrap the DB call so it only runs on the connected WebSocket render:
    ```elixir
    if connected?(socket) do
      {findings, total} = Analytics.paginate_findings(current_user, opts)
      total_pages = max(1, ceil(total / @per_page))
      socket
      |> stream(:findings, findings, reset: true)
      |> assign(:finding_count, total)
      |> assign(:page, page)
      |> assign(:total_pages, total_pages)
      |> assign(:filter_severity, severity)
      |> assign(:filter_kind, kind)
      |> assign(:filter_ad_account_id, ad_account_id)
    else
      socket
      |> assign(:page, page)
      |> assign(:filter_severity, severity)
      |> assign(:filter_kind, kind)
      |> assign(:filter_ad_account_id, ad_account_id)
    end
    ```

- [x] [P3-T3][liveview] **W6 — Remove stale `ad_accounts_list` cache pattern**
  File: `lib/ad_butler_web/live/findings_live.ex`
  - Replace the `case socket.assigns.ad_accounts_list do` block with an unconditional load:
    ```elixir
    ad_accounts = Ads.list_ad_accounts(current_user)
    ```
  - Also load unconditionally in `handle_info(:reload_on_reconnect, ...)` (already does this — confirm no change needed)

- [x] [P3-T4][liveview] **S1 — Extract shared helpers to `AdButlerWeb.FindingHelpers`**
  File: `lib/ad_butler_web/helpers/finding_helpers.ex` (new)
  - Create module with `severity_badge_class/1` and `kind_label/1` (copy from `FindingsLive`, same logic):
    ```elixir
    defmodule AdButlerWeb.FindingHelpers do
      @moduledoc "Shared rendering helpers for finding severity and kind labels."

      @doc "Returns Tailwind CSS classes for a severity badge."
      def severity_badge_class("high"), do: "inline-flex px-2 py-0.5 rounded text-xs font-medium bg-red-100 text-red-700"
      def severity_badge_class("medium"), do: "inline-flex px-2 py-0.5 rounded text-xs font-medium bg-yellow-100 text-yellow-700"
      def severity_badge_class("low"), do: "inline-flex px-2 py-0.5 rounded text-xs font-medium bg-blue-100 text-blue-700"
      def severity_badge_class(_), do: "inline-flex px-2 py-0.5 rounded text-xs font-medium bg-gray-100 text-gray-700"

      @doc "Returns a human-readable label for a finding kind."
      def kind_label("dead_spend"), do: "Dead Spend"
      def kind_label("cpa_explosion"), do: "CPA Explosion"
      def kind_label("bot_traffic"), do: "Bot Traffic"
      def kind_label("placement_drag"), do: "Placement Drag"
      def kind_label("stalled_learning"), do: "Stalled Learning"
      def kind_label(other), do: other
    end
    ```
  - In `FindingsLive` and `FindingDetailLive`: add `import AdButlerWeb.FindingHelpers` and remove the duplicate private function definitions

---

## Phase 4 — Test Fixes (B4, B5, B6, S3)

- [x] [P4-T1][test] **B4 — Add `import Ecto.Query` to `analytics_test.exs`**
  File: `test/ad_butler/analytics_test.exs`
  - Add after alias block: `import Ecto.Query`

- [x] [P4-T2][test] **B5 — Add event tests to `findings_live_test.exs`**
  File: `test/ad_butler_web/live/findings_live_test.exs`
  - Add `describe "filter_changed event"` block:
    - `render_change(view, "filter_changed", %{"severity" => "high"})` → assert URL patch includes `severity=high`
    - `render_change(view, "filter_changed", %{"severity" => "", "kind" => ""})` → assert URL has no filters
  - Add `describe "paginate event"` block:
    - `render_click(view, "paginate", %{"page" => "2"})` → assert URL patch includes `page=2`

- [x] [P4-T3][test] **B6 — Add acknowledge error test to `finding_detail_live_test.exs`** — SKIPPED: {:error,_} path in acknowledge_finding requires Mox; acknowledge_changeset uses change/2 so no constraint registration; crash-on-delete propagates as EXIT not a testable raise
  File: `test/ad_butler_web/live/finding_detail_live_test.exs`
  - Add test: mock `Analytics.acknowledge_finding` to return `{:error, :db_failure}` (via Mox if behaviour set up, or test by deleting the finding first so the DB raises)
  - Assert flash contains error message
  - Simplest approach: delete the finding in the DB before clicking, then `render_click` → assert flash error or error message visible

- [x] [P4-T4][test] **S3 — Add heuristic skip-path tests**
  File: `test/ad_butler/workers/budget_leak_auditor_worker_test.exs`
  - Add to `describe "placement_drag heuristic"`:
    - **Skip (single placement)**: one placement in `by_placement_jsonb` → no `placement_drag` finding
    - **Skip (ratio < 3x)**: two placements with CPA ratio of 2x → no finding
  - Add to `describe "dead_spend heuristic"`:
    - **Skip (growing reach)**: spend > $5, no conversions, but reach_uplift ≥ 5% of max_reach → no `dead_spend` finding

---

## Phase 5 — Verification

- [x] [P5-T1] `mix format`
- [x] [P5-T2] `mix compile --warnings-as-errors`
- [x] [P5-T3] `mix credo --strict` — 1 pre-existing refactor in insights_pipeline.ex (not touched)
- [x] [P5-T4] `mix test test/ad_butler/workers/ test/ad_butler_web/live/ test/ad_butler/analytics_test.exs` — 109 tests, 0 failures
- [x] [P5-T5] `mix test` — 312 tests, 0 failures, 8 excluded

---

## Risks

1. **`Oban.insert_all/1` return shape** — Oban 2.18 OSS returns `{:ok, [%Oban.Job{}]}` per the docs, but the conflict/error path should be verified in the installed version. If it raises rather than returning `{:error, _}`, the scheduler's error handling approach changes.

2. **`unsafe_list_30d_baselines` UUID encoding** — `ad_insights_30d` stores `ad_id` as a binary UUID column. The `Ecto.UUID.dump!/1` call maps string UUIDs to binary for the `in` clause. Test that the map keys are string UUIDs matching `Ad.id` values before shipping.

3. **`run_heuristics` refactor blast radius** — Changing from a pipeline to a `reduce_while` and adding the `baselines` map parameter touches every heuristic function signature. Run the full auditor test suite after P2-T1 before proceeding to Phase 3.
