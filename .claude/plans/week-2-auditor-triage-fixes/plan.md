# Plan: week-2-auditor-triage-fixes

Post-triage fix plan. 12 tasks across 6 phases.
Source: `.claude/plans/week-2-auditor-post-review/reviews/week-2-auditor-post-review-triage.md`
Branch: `v2-week-2Auditor-Findings`

---

## Phase 1 — Analytics context

- [x] [P1-T1] Add `Analytics.get_finding/2` returning `{:ok, Finding.t()} | {:error, :not_found}` — uses Repo.get on scoped query, nil → {:error, :not_found}
  - File: `lib/ad_butler/analytics.ex` — add below `get_finding!/2`
  - Implementation: `scope_findings(user)` + `Repo.one(query)` → nil maps to `{:error, :not_found}`
  - Add `@spec get_finding(User.t(), binary()) :: {:ok, Finding.t()} | {:error, :not_found}` and `@doc`

- [x] [P1-T2] Rename `get_latest_health_score/1` → `unsafe_get_latest_health_score/1` — updated analytics.ex, finding_detail_live.ex, and test
  - File: `lib/ad_butler/analytics.ex:122-136` — rename function + update `@spec`/`@doc`
  - Update call site: `lib/ad_butler_web/live/finding_detail_live.ex:26`
  - Update call site: `test/ad_butler/workers/budget_leak_auditor_worker_test.exs:115`

---

## Phase 2 — AuditSchedulerWorker

- [x] [P2-T1] Fix `insert_all` error handling + remove redundant `unique:` override — split_with valid/invalid, log invalid changesets, use module-level unique config
  - File: `lib/ad_butler/workers/audit_scheduler_worker.ex`
  - Replace the current `results` + `Enum.filter` block:
    ```elixir
    changesets = Enum.map(ad_accounts, fn aa ->
      BudgetLeakAuditorWorker.new(%{"ad_account_id" => aa.id})
    end)
    {valid, invalid} = Enum.split_with(changesets, & &1.valid?)
    Enum.each(invalid, &Logger.error("audit_scheduler: invalid job changeset", errors: &1.errors))
    Oban.insert_all(valid)
    Logger.info("audit_scheduler enqueued jobs", count: length(valid))
    ```
  - The `BudgetLeakAuditorWorker.new(%{...})` call (no opts) exercises module-level `unique:` config

---

## Phase 3 — BudgetLeakAuditorWorker refactors

- [x] [P3-T1] Refactor `check_cpa_explosion` — replace `with true <-` with `cond` — cleaner early returns without guard misuse
  - File: `lib/ad_butler/workers/budget_leak_auditor_worker.ex:169-198`
  - Replace entire `with` block:
    ```elixir
    cond do
      conversions_3d == 0 -> :skip
      baseline == nil -> :skip
      not (is_integer(baseline.cpa_cents) and baseline.cpa_cents > 0) -> :skip
      true ->
        baseline_cpa = baseline.cpa_cents
        cpa_3d = div(spend_3d, conversions_3d)
        ratio = cpa_3d / baseline_cpa
        if ratio > 2.5, do: {:emit, %{ad_id: ad_id, ad_account_id: ad_account_id,
          kind: "cpa_explosion", severity: "high",
          title: "CPA explosion detected",
          body: "3-day CPA is #{Float.round(ratio, 1)}x the 30-day baseline",
          evidence: %{cpa_3d_cents: cpa_3d, cpa_30d_cents: baseline_cpa, ratio: ratio}}},
          else: :skip
    end
    ```

- [x] [P3-T2] Refactor `check_placement_drag` — move plain `=` assigns out of `with` arms; use `[_, _ | _]` — with arms are now pure pattern matches
  - File: `lib/ad_butler/workers/budget_leak_auditor_worker.ex:242-270`
  - Remove `cpas = ...`, `max_cpa = ...`, `min_cpa = ...` from `with` arms → move to `do` body
  - Replace `placements when length(placements) >= 2` with `[_, _ | _] = placements`
  - Replace `true <- min_cpa > 0 and max_cpa / min_cpa > 3` with `if` in `do` body:
    ```elixir
    with ad_set_id when ad_set_id != nil <- Map.get(ad_set_map, ad_id),
         [_, _ | _] = placements <- aggregate_placement_cpas(rows) do
      cpas = Enum.map(placements, &elem(&1, 1))
      max_cpa = Enum.max(cpas)
      min_cpa = Enum.min(cpas)
      if min_cpa > 0 and max_cpa / min_cpa > 3 do
        {best_name, _} = Enum.min_by(placements, &elem(&1, 1))
        {worst_name, _} = Enum.max_by(placements, &elem(&1, 1))
        {:emit, %{ad_id: ad_id, ad_account_id: ad_account_id, kind: "placement_drag",
          severity: "medium", title: "Placement drag detected",
          body: "#{worst_name} placement has #{Float.round(max_cpa / min_cpa, 1)}x higher CPA than #{best_name}",
          evidence: %{best_placement: best_name, best_cpa: min_cpa,
                      worst_placement: worst_name, worst_cpa: max_cpa}}}
      else
        :skip
      end
    else
      _ -> :skip
    end
    ```

- [x] [P3-T3] Idempotent health score inserts — migration + 6h bucket + upsert — migration 20260428000001, six_hour_bucket/0 helper, on_conflict replace in Analytics
  - New migration: `priv/repo/migrations/20260428000001_add_unique_index_ad_health_scores.exs`
    ```elixir
    def change do
      create unique_index(:ad_health_scores, [:ad_id, :computed_at],
               name: :ad_health_scores_ad_id_computed_at_unique)
    end
    ```
  - Add private helper in `budget_leak_auditor_worker.ex`:
    ```elixir
    defp six_hour_bucket do
      now = DateTime.utc_now()
      bucket_hour = div(now.hour, 6) * 6
      DateTime.new!(Date.utc_today(), Time.new!(bucket_hour, 0, 0, 0))
    end
    ```
  - In `insert_health_scores/2`, set `computed_at: six_hour_bucket()` in attrs map
  - In `Analytics.insert_ad_health_score/1`, change `Repo.insert/1` to:
    ```elixir
    Repo.insert(changeset,
      on_conflict: {:replace, [:leak_score, :leak_factors, :inserted_at]},
      conflict_target: [:ad_id, :computed_at]
    )
    ```
  - Run `mix ecto.migrate` to apply

---

## Phase 4 — FindingDetailLive (depends on P1)

- [x] [P4-T1] Add `connected?` guard, graceful redirect, remove dead alias — nil assigns in mount, get_finding/2 + push_navigate on :not_found, :if={@finding} on template root
  - File: `lib/ad_butler_web/live/finding_detail_live.ex`
  - In `mount/3`: add `|> assign(:finding, nil) |> assign(:health_score, nil)` to the socket chain
  - Rewrite `handle_params/3` to use `get_finding/2` with `connected?` guard:
    ```elixir
    def handle_params(%{"id" => id}, _uri, socket) do
      if connected?(socket) do
        current_user = socket.assigns.current_user
        case Analytics.get_finding(current_user, id) do
          {:ok, finding} ->
            health_score = Analytics.unsafe_get_latest_health_score(finding.ad_id)
            {:noreply, socket |> assign(:finding, finding) |> assign(:health_score, health_score)}
          {:error, :not_found} ->
            {:noreply,
             socket
             |> put_flash(:error, "Finding not found.")
             |> push_navigate(to: ~p"/findings")}
        end
      else
        {:noreply, socket}
      end
    end
    ```
  - Wrap template root `<div class="max-w-4xl mx-auto">` with `:if={@finding}` so disconnected render is safe (the div and all children only render when finding is loaded)
  - Remove `alias AdButler.Ads` (line 14) and `_ = Ads` (line 165)

---

## Phase 5 — FindingsLive (no deps)

- [x] [P5-T1] Extract `load_findings/1` to remove `handle_info` duplication — handle_params and handle_info both delegate to load_findings/1
  - File: `lib/ad_butler_web/live/findings_live.ex`
  - Add private:
    ```elixir
    defp load_findings(socket) do
      current_user = socket.assigns.current_user
      opts =
        [page: socket.assigns.page, per_page: @per_page]
        |> maybe_put(:severity, socket.assigns.filter_severity)
        |> maybe_put(:kind, socket.assigns.filter_kind)
        |> maybe_put(:ad_account_id, socket.assigns.filter_ad_account_id)
      {findings, total} = Analytics.paginate_findings(current_user, opts)
      total_pages = max(1, ceil(total / @per_page))
      ad_accounts = Ads.list_ad_accounts(current_user)
      socket
      |> stream(:findings, findings, reset: true)
      |> assign(:finding_count, total)
      |> assign(:total_pages, total_pages)
      |> assign(:ad_accounts_list, ad_accounts)
    end
    ```
  - In `handle_params/3` connected branch: call `{:noreply, load_findings(socket)}` after setting filter assigns
  - In `handle_info(:reload_on_reconnect, socket)`: replace body with `{:noreply, load_findings(socket)}`

---

## Phase 6 — Tests (depends on P1, P4)

- [x] [P6-T1] Fix growing reach test — add stagnant-reach counterpart to prove guard is load-bearing — two rows same reach_count fires dead_spend
  - File: `test/ad_butler/workers/budget_leak_auditor_worker_test.exs`
  - Add after the existing "skips when reach uplift >= 5%" test:
    ```elixir
    test "fires when reach is stagnant (uplift < 5% of max_reach)" do
      {ad_account, ad} = insert_ad_with_account()
      # Two rows: same reach_count → uplift = 0 → 0 < max_reach * 0.05 → fires
      insert_insight(ad, date_start: Date.add(Date.utc_today(), -1),
        spend_cents: 1000, conversions: 0, reach_count: 100)
      insert_insight(ad, spend_cents: 1000, conversions: 0, reach_count: 100)
      assert :ok = perform_job(BudgetLeakAuditorWorker, %{"ad_account_id" => ad_account.id})
      assert count_findings(ad, "dead_spend") == 1
    end
    ```

- [x] [P6-T2] Add cross-tenant `acknowledge` event test (CT1) — tests context layer directly, asserts NoResultsError for user_b on user_a's finding
  - File: `test/ad_butler_web/live/finding_detail_live_test.exs`
  - The `acknowledge` event reads `socket.assigns.finding.id` — not a user-supplied param — so user B cannot inject user A's finding ID via a normal LiveView event. The security guarantee is in the context layer. Add a test documenting this surface:
    ```elixir
    test "user B cannot acknowledge user A's finding via context", %{finding: finding} do
      user_b = insert(:user)
      _mc_b = insert(:meta_connection, user: user_b)
      assert_raise Ecto.NoResultsError, fn ->
        Analytics.acknowledge_finding(user_b, finding.id)
      end
    end
    ```
  - This tests the actual attack path (direct context call with wrong user) rather than testing LiveView socket state which is server-controlled

- [x] [P6-T3] Add `acknowledge_finding` cross-tenant analytics test (CT2) — in analytics_test.exs describe block
  - File: `test/ad_butler/analytics_test.exs`
  - In the `describe "acknowledge_finding/2"` block (or add one), add:
    ```elixir
    test "raises for finding belonging to another user" do
      user_a = insert(:user)
      user_b = insert(:user)
      mc_a = insert(:meta_connection, user: user_a)
      ad_account_a = insert(:ad_account, meta_connection: mc_a)
      ad_a = insert(:ad, ad_account: ad_account_a)
      finding_a = insert(:finding, ad: ad_a, ad_account: ad_account_a)
      assert_raise Ecto.NoResultsError, fn ->
        Analytics.acknowledge_finding(user_b, finding_a.id)
      end
    end
    ```

- [x] [P6-T4] Fix scheduler uniqueness test — call `BudgetLeakAuditorWorker.new/1` without opts (WT2) — exercises module-level unique config
  - File: `test/ad_butler/workers/audit_scheduler_worker_test.exs`
  - Find: `BudgetLeakAuditorWorker.new(%{"ad_account_id" => aa.id}, unique: [period: 21_600, keys: [:ad_account_id]])`
  - Replace with: `BudgetLeakAuditorWorker.new(%{"ad_account_id" => aa.id})`
  - This exercises the declared module-level `unique:` config

- [x] [P6-T5] Update FindingDetailLive tenant isolation test for redirect (P4 dep) — {:error, {:live_redirect, %{to: "/findings"}}}, plus nonexistent ID test
  - File: `test/ad_butler_web/live/finding_detail_live_test.exs`
  - Update existing "tenant isolation" test (line 98):
    ```elixir
    test "tenant isolation — user B is redirected away from user A's finding", %{
      conn: conn,
      finding: finding
    } do
      user_b = insert(:user)
      conn = log_in_user(conn, user_b)
      assert {:error, {:live_redirect, %{to: "/findings"}}} =
               live(conn, ~p"/findings/#{finding.id}")
    end
    ```
  - Add new test for nonexistent finding ID:
    ```elixir
    test "nonexistent finding ID redirects to /findings", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)
      bogus_id = Ecto.UUID.generate()
      assert {:error, {:live_redirect, %{to: "/findings"}}} =
               live(conn, ~p"/findings/#{bogus_id}")
    end
    ```

---

## Verification

Per-phase: `mix compile --warnings-as-errors && mix credo --strict`
After P3-T3: `mix ecto.migrate`
Final gate: `mix precommit`

---

## Key Decisions

- **B3 graceful redirect**: `push_navigate` from `handle_params` causes LiveViewTest to return `{:error, {:live_redirect, ...}}` — test assertion matches this form.
- **W3 upsert**: Round `computed_at` to 6h bucket in worker (not DB). Old rows with microsecond-precision timestamps won't conflict with new bucketed rows. New retries within same 6h window produce identical `computed_at` and upsert cleanly.
- **CT1 test scope**: `acknowledge` event reads `socket.assigns.finding.id` (server state) not a user-supplied param. Cross-tenant risk lives in the context layer (`acknowledge_finding/2`). Testing at the context level (CT2) is sufficient and simpler.
- **P6-T5 assertion**: Uses `{:live_redirect, ...}` (from `push_navigate`) not `{:redirect, ...}` (from `redirect/2`). If this fails, swap to `{:redirect, ...}`.
