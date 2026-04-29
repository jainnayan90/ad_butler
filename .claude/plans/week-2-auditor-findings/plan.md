# Plan: Week 2 — Auditor + Findings (Days 7–12)

**Branch:** `v2-week-2Auditor-Findings`
**Depth:** Standard
**Source:** v0.2 plan, Week 2 section — Days 7–12

---

## What Already Exists (Week 1 baseline)

| Built | Location |
|---|---|
| `insights_daily` partitioned table + partitions | migrations 20260426100001–100002 |
| `ad_insights_7d` + `ad_insights_30d` views | migrations 20260426100003–100004 |
| `AdButler.Ads.Insight` schema | `lib/ad_butler/ads/insight.ex` |
| `Ads.bulk_upsert_insights/1` | `lib/ad_butler/ads.ex` |
| `Ads.unsafe_get_7d_insights/1` + `Ads.unsafe_get_30d_baseline/1` | `lib/ad_butler/ads.ex` |
| `Meta.Client.get_insights/3` + `ClientBehaviour` | `lib/ad_butler/meta/` |
| `InsightsPipeline` Broadway + scheduler workers | `lib/ad_butler/sync/`, `lib/ad_butler/workers/` |
| `Analytics` context (partition mgmt + view refresh only) | `lib/ad_butler/analytics.ex` |
| Sidebar nav + `nav_item` component | `lib/ad_butler_web/components/layouts.ex` |
| Router `:authenticated` live_session | `lib/ad_butler_web/router.ex` |

---

## Architecture Decisions

- **`Analytics` context owns findings + health scores** — the existing `analytics.ex`
  expands to include findings domain. Schemas live in `lib/ad_butler/analytics/`.
- **Tenant scope via mc_ids** — follows the audit fix pattern: call
  `Accounts.list_meta_connection_ids_for_user/1` to get mc_ids, join `ad_accounts`
  on `meta_connection_id IN mc_ids`. Never import `MetaConnection` into Analytics.
- **BudgetLeakAuditor queries insights directly** — the worker owns `insights_daily`
  queries for its auditor-specific shapes (48h window, per-account). These live as
  private helpers in the worker, not in `Ads` context (auditor-only, no user scope
  needed — ad_account_id is the trusted boundary).
- **Deduplication by `(ad_id, kind)`** — skip insert if an unresolved finding of
  the same kind already exists for the ad. "Resolved" means `resolved_at IS NOT NULL`.
- **5 heuristics → `leak_score`** — weights: dead_spend 40, cpa_explosion 35,
  bot_traffic 15, placement_drag 7, stalled_learning 3. Capped at 100.
- **Findings scoped via ad_account join, not direct user FK** — `findings` has no
  `user_id`; scope is always `ad_account_id IN (SELECT id FROM ad_accounts WHERE
  meta_connection_id IN ^mc_ids)`.

---

## Breadboard

```
Nav (sidebar)
└── Findings  →  /findings  →  FindingsLive
                  /findings/:id  →  FindingDetailLive

Data flow:
  AuditSchedulerWorker (Oban cron, every 6h)
    → fans out BudgetLeakAuditorWorker per active ad_account
  BudgetLeakAuditorWorker (Oban, per ad_account)
    → queries insights_daily (48h window) for all ads in account
    → queries ad_insights_30d view for CPA baselines
    → applies 5 heuristics
    → writes findings (deduplicated by ad_id+kind)
    → upserts ad_health_scores (one row per ad, append-only)
  FindingsLive
    → paginated list, filters: severity / kind / ad_account_id
  FindingDetailLive
    → evidence JSONB + health score card + acknowledge button
```

---

## Tasks

### Day 7 — Analytics Context: Schemas + Migrations

#### Migrations

- [ ] [D7-T1][ecto] Migration: `CREATE TABLE ad_health_scores`
  - `id :binary_id`, `ad_id` FK → `ads.id` (ON DELETE CASCADE), `computed_at :utc_datetime_usec`,
    `leak_score :decimal(5,2)`, `fatigue_score :decimal(5,2)`, `leak_factors :map`,
    `fatigue_factors :map`, `recommended_action :string`, `inserted_at`
  - Index: `(ad_id, computed_at DESC)` — supports "latest score per ad" query
  - Append-only; most-recent row per `ad_id` = current score (no UPDATE)

- [ ] [D7-T2][ecto] Migration: `CREATE TABLE findings`
  - `id :binary_id`, `ad_id` FK → `ads.id` (ON DELETE CASCADE),
    `ad_account_id` FK → `ad_accounts.id` (for fast inbox queries),
    `kind :string` (not null), `severity :string` (not null),
    `title :string`, `body :text`, `evidence :map`,
    `acknowledged_at :utc_datetime_usec`, `acknowledged_by_user_id` FK → `users.id` nullable,
    `resolved_at :utc_datetime_usec`, `resolution :text`, `inserted_at`
  - Indexes: `(ad_account_id, severity, inserted_at DESC)`, `(ad_id, kind)`
  - Unique index: `(ad_id, kind)` WHERE `resolved_at IS NULL` — enforces dedup constraint at DB level

#### Schemas

- [ ] [D7-T3][ecto] `AdButler.Analytics.AdHealthScore` schema
  - `@primary_key {:id, :binary_id, autogenerate: true}`, `@foreign_key_type :binary_id`
  - `belongs_to :ad, AdButler.Ads.Ad`
  - All fields as above; changeset validates required `[:ad_id, :computed_at, :leak_score]`
  - `@moduledoc` + `@doc` on changeset

- [ ] [D7-T4][ecto] `AdButler.Analytics.Finding` schema
  - `belongs_to :ad, AdButler.Ads.Ad`; `belongs_to :ad_account, AdButler.Ads.AdAccount`
  - `belongs_to :acknowledged_by, AdButler.Accounts.User, foreign_key: :acknowledged_by_user_id`
  - `validate_inclusion(:severity, ~w(low medium high))` in changeset
  - `validate_inclusion(:kind, ~w(dead_spend cpa_explosion bot_traffic placement_drag stalled_learning))`
  - `@moduledoc` + `@doc`

#### Analytics Context Expansion

- [ ] [D7-T5][ecto] Expand `AdButler.Analytics` with findings functions
  - Add aliases: `Analytics.Finding`, `Analytics.AdHealthScore`, `Ads.AdAccount`, `Accounts`, `Repo`
  - `scope_findings/2` private helper:
    ```elixir
    defp scope_findings(queryable, %User{} = user) do
      mc_ids = Accounts.list_meta_connection_ids_for_user(user)
      from f in queryable,
        join: aa in AdAccount, on: f.ad_account_id == aa.id,
        where: aa.meta_connection_id in ^mc_ids
    end
    ```
  - `paginate_findings/2` — `(user, opts)` where opts: `page:`, `per_page:`, `severity:`,
    `kind:`, `ad_account_id:`. Returns `{[Finding.t()], non_neg_integer()}`.
    Uses `scope_findings/2`, apply filter helpers, `order_by: [desc: :inserted_at]`,
    `limit/offset` for pagination, `Repo.all` + `Repo.aggregate(:count)`.
  - `get_finding!/2` — `(user, id)` scoped; raises `Ecto.NoResultsError` if not owned
  - `acknowledge_finding/2` — `(user, finding_id)`. Sets `acknowledged_at` and
    `acknowledged_by_user_id`. Returns `{:ok, Finding.t()} | {:error, Ecto.Changeset.t()}`.
  - `create_finding/1` — `(attrs)` — internal, no scope check (called by auditor worker)
  - `upsert_ad_health_score/1` — `(attrs)` — `Repo.insert/2` with no on_conflict
    (append-only; new row each audit run)
  - `get_unresolved_finding/2` — `(ad_id, kind)` — internal; returns `Finding.t() | nil`
    Used by dedup check in auditor
  - All functions get `@spec` + `@doc`

- [ ] [D7-T6][ecto][test] Tests for Analytics context functions
  - `paginate_findings/2`: tenant isolation (user_b sees nothing), pagination page 2,
    severity filter, kind filter, ad_account_id filter
  - `get_finding!/2`: raises for cross-tenant access
  - `acknowledge_finding/2`: sets fields, idempotent on second call
  - `get_unresolved_finding/2`: returns nil after resolved, returns existing if open
  - Add `finding_factory` + `ad_health_score_factory` to `test/support/factory.ex`

---

### Day 8 — BudgetLeakAuditor: Dead Spend + CPA Explosion

- [ ] [D8-T1][oban] Create `lib/ad_butler/workers/budget_leak_auditor_worker.ex`
  - `use Oban.Worker, queue: :audit, max_attempts: 3`
  - `perform(%{"ad_account_id" => ad_account_id})`
  - Load ad_account: `Ads.get_ad_account(ad_account_id)` (returns nil if not found → `:ok`)
  - Query insights for all ads in account (last 48h):
    ```elixir
    defp load_48h_insights(ad_account_id) do
      cutoff = DateTime.add(DateTime.utc_now(), -48 * 3600, :second)
      from i in "insights_daily",
        where: i.ad_account_id == ^ad_account_id and i.date_start >= ^cutoff,
        select: %{
          ad_id: i.ad_id,
          spend_cents: i.spend_cents,
          impressions: i.impressions,
          conversions: i.conversions,
          reach_count: i.reach_count,
          ctr_numeric: i.ctr_numeric,
          by_placement_jsonb: i.by_placement_jsonb
        }
      |> Repo.all()
    end
    ```
  - Group insights by `ad_id` for per-ad aggregation
  - Call each heuristic function, collect `[{ad_id, kind, severity, evidence}]`
  - Dedup + persist: for each finding, call `Analytics.get_unresolved_finding(ad_id, kind)`;
    skip if found; otherwise `Analytics.create_finding(attrs)`
  - Upsert health scores after all heuristics run

- [ ] [D8-T2][oban] **Heuristic 1 — Dead Spend**
  - Trigger: `sum(spend_cents, 48h) > 500` AND `sum(conversions, 48h) == 0`
    AND reach uplift (`max_reach - min_reach`) < 5% of `max_reach`
  - Kind: `"dead_spend"`, severity: `"high"`
  - Evidence: `%{spend_cents: total_spend, period_hours: 48, conversions: 0}`
  - Title: `"Dead spend detected"`, body: `"Ad has spent $X with zero conversions in 48 hours"`

- [ ] [D8-T3][oban] **Heuristic 2 — CPA Explosion**
  - Load 30d baseline: `Ads.unsafe_get_30d_baseline(ad_id)` — safe here, ad_id verified via ad_account scope
  - Trigger: 3-day CPA (`sum_spend_3d / sum_conversions_3d`) > `2.5 × baseline_cpa_30d`
    AND `sum(conversions, 3d) > 0` AND `baseline_cpa_30d > 0`
  - Kind: `"cpa_explosion"`, severity: `"high"`
  - Evidence: `%{cpa_3d_cents: X, cpa_30d_cents: Y, ratio: Z}`

- [ ] [D8-T4][oban] Deduplication logic (shared across all heuristics)
  - `maybe_emit_finding/3` private: checks `Analytics.get_unresolved_finding(ad_id, kind)`;
    only calls `Analytics.create_finding/1` if nil returned
  - Returns `:skipped | {:ok, Finding.t()} | {:error, term()}`

- [ ] [D8-T5][oban][test] Tests for Day 8 (`test/ad_butler/workers/budget_leak_auditor_worker_test.exs`)
  - Seed `insights_daily` rows for 1 ad with high spend + zero conversions → assert `dead_spend` finding created
  - Seed insights + 30d view data with CPA > 2.5x baseline → assert `cpa_explosion` finding
  - Dedup test: run worker twice → assert exactly 1 finding per `(ad_id, kind)`
  - No finding if spend < threshold (< $5)
  - No CPA explosion if 30d baseline is nil (new ad)

---

### Day 9 — BudgetLeakAuditor: Remaining Heuristics + Scoring

- [ ] [D9-T1][oban] **Heuristic 3 — Bot-shaped Traffic**
  - Trigger: `ctr_numeric > 0.05` AND `conversion_rate < 0.003` (conversions/clicks)
    AND `dominant_placement/1` returns `"audience_network"` or `"reels"`
  - `dominant_placement/1` private: reads `by_placement_jsonb`, finds placement with highest spend/impressions
  - Kind: `"bot_traffic"`, severity: `"medium"`
  - Evidence: `%{ctr: X, conversion_rate: Y, dominant_placement: Z}`
  - Guard: skip if `sum(impressions, 48h) < 1000` (not enough data)

- [ ] [D9-T2][oban] **Heuristic 4 — Placement Drag**
  - Group ads by `ad_set_id` (need to load ad_set_id per ad — add `ad_set_id` to
    `load_48h_insights/1` select)
  - For each ad_set group with ≥ 2 ads, compute per-placement CPA from `by_placement_jsonb`
  - Trigger: `max(placement_cpa) / min(placement_cpa) > 3`
  - Kind: `"placement_drag"`, severity: `"medium"`; emit on ad_set's "first" ad (or per-ad)
  - Evidence: `%{best_placement: name, best_cpa: X, worst_placement: name, worst_cpa: Y}`

- [ ] [D9-T3][oban] **Heuristic 5 — Stalled Learning**
  - Query ad_sets directly: `AdSet` WHERE `ad_account_id = ^ad_account_id`
    AND `raw_jsonb->>'effective_status' = 'LEARNING'`
    AND `updated_at < now() - 7 days`
  - Cross-check: sum of conversions for ads in that ad_set (from loaded insights) < 50 in 7d
  - Kind: `"stalled_learning"`, severity: `"low"`; emit once per ad_set (using the first ad_id)
  - Evidence: `%{ad_set_id: X, days_in_learning: N, conversions_7d: M}`

- [ ] [D9-T4][oban] Scoring: compute `leak_score` per ad
  ```elixir
  @weights %{"dead_spend" => 40, "cpa_explosion" => 35, "bot_traffic" => 15,
              "placement_drag" => 7, "stalled_learning" => 3}

  defp compute_leak_score(fired_kinds) do
    fired_kinds
    |> Enum.map(&Map.get(@weights, &1, 0))
    |> Enum.sum()
    |> min(100)
  end
  ```
  Call `Analytics.upsert_ad_health_score/1` for each ad processed (even if no findings fired,
  to record a clean score).

- [ ] [D9-T5][oban][test] Tests for heuristics 3–5 and scoring
  - Bot-traffic: seed CTR > 5%, low conversion rate, audience_network dominant → assert finding
  - Bot-traffic guard: < 1000 impressions → no finding
  - Placement drag: seed `by_placement_jsonb` with 4x CPA spread → assert finding
  - Stalled learning: seed ad_set with LEARNING status + old timestamp → assert finding
  - Scoring: seed data that fires dead_spend + cpa_explosion → assert `leak_score == 75`
  - Health score upserted even when 0 heuristics fire (score = 0)

---

### Day 10 — Auditor Scheduling + Wire-up

- [x] [D10-T1][oban] Create `lib/ad_butler/workers/audit_scheduler_worker.ex`
  - `use Oban.Worker, queue: :audit, max_attempts: 3`
  - `perform/1` — loads all active ad_accounts across all active connections:
    ```elixir
    def perform(_job) do
      mc_ids = Accounts.list_all_active_meta_connection_ids()
      ad_accounts = Ads.list_ad_accounts_by_mc_ids(mc_ids)
      Enum.each(ad_accounts, fn aa ->
        %{"ad_account_id" => aa.id}
        |> BudgetLeakAuditorWorker.new(unique: [period: 21_600, keys: [:ad_account_id]])
        |> Oban.insert()
      end)
      :ok
    end
    ```
  - Requires new helper: `Accounts.list_all_active_meta_connection_ids/0` — returns `[binary()]`
    (not full structs; follows the IDs pattern from the audit fix)
  - Requires new helper: `Ads.list_ad_accounts_by_mc_ids/1` — internal, no user scope

- [x] [D10-T2][oban] Register `AuditSchedulerWorker` in Oban cron
  - Add to `config/config.exs` crontab: `{"0 */6 * * *", AdButler.Workers.AuditSchedulerWorker}`
  - Add `:audit` queue to Oban queues config: `audit: [limit: 5]`

- [x] [D10-T3][oban][test] Tests
  - `AuditSchedulerWorker.perform/1`: seed 2 active ad_accounts across 2 connections;
    assert 2 `BudgetLeakAuditorWorker` jobs enqueued with correct `ad_account_id`
  - Uniqueness: insert 2 jobs for same `ad_account_id` within 6h window — assert only 1 in queue
  - Full smoke test (drain queue): seed insights data that triggers ≥ 1 heuristic;
    drain `:audit` queue; assert findings created for seeded ad_account

- [x] [D10-T4] `mix precommit` — clean compile, credo, all tests green

---

### Day 11 — FindingsLive (List + Filters)

- [x] [D11-T1][liveview] Add `Findings` to router and sidebar
  - Router: inside `live_session :authenticated` —
    `live "/findings", FindingsLive` and `live "/findings/:id", FindingDetailLive`
  - Sidebar (`layouts.ex`): add `<.nav_item label="Findings" icon="hero-flag" path="/findings"
    active={@active_nav == :findings} />`
  - Add `:findings` to active nav assigns in router `on_mount` hook (if using per-route assignment)

- [x] [D11-T2][liveview] Create `lib/ad_butler_web/live/findings_live.ex`
  - `mount/3`: assign `current_user` guard; initialize empty stream `:findings`;
    assign `per_page: 50`, `page: 1`, `total_pages: 1`, `finding_count: 0`,
    `filter_severity: nil`, `filter_kind: nil`, `filter_ad_account_id: nil`
  - `handle_params/3`: read `:page`, `:severity`, `:kind`, `:ad_account_id` from params;
    call `Analytics.paginate_findings(current_user, opts)`;
    `stream(:findings, items, reset: true)`;
    `assign(:page, page)`, `assign(:total_pages, ...)`, `assign(:finding_count, total)`
  - `handle_event("filter_changed", params, socket)`: extract filter values;
    `push_patch(socket, to: ~p"/findings?#{params}")`

- [x] [D11-T3][liveview] FindingsLive template
  - Stat card: "N Findings"
  - Filter row: 3 `<select>` elements — severity (`All / Low / Medium / High`),
    kind (`All / Dead Spend / CPA Explosion / Bot Traffic / Placement Drag / Stalled Learning`),
    ad_account_id (populated from socket assigns). `phx-change="filter_changed"`.
  - Stream table — `id={dom_id}`, columns: Ad Name (link → `/findings/:id`),
    Kind (human label), Severity (badge), Inserted At (relative time)
  - `<.pagination page={@page} total_pages={@total_pages} />` below table

- [x] [D11-T4][liveview] Severity badge helper
  - Plain Tailwind only (no DaisyUI classes)
  - `high` → `bg-red-100 text-red-700`, `medium` → `bg-yellow-100 text-yellow-700`,
    `low` → `bg-blue-100 text-blue-700`
  - Human kind labels: `"dead_spend" → "Dead Spend"`, `"cpa_explosion" → "CPA Explosion"`,
    `"bot_traffic" → "Bot Traffic"`, `"placement_drag" → "Placement Drag"`,
    `"stalled_learning" → "Stalled Learning"`

- [x] [D11-T5][liveview][test] `test/ad_butler_web/live/findings_live_test.exs`
  - Mount: shows finding count
  - Filter by severity: only high findings shown
  - Filter by kind: only `dead_spend` findings shown
  - Tenant isolation: user_b cannot see user_a's findings (no rows rendered)
  - Pagination: page 2 shows correct offset

---

### Day 12 — FindingDetailLive (Detail + Acknowledge)

- [x] [D12-T1][liveview] Create `lib/ad_butler_web/live/finding_detail_live.ex`
  - `handle_params/3`: `Analytics.get_finding!(current_user, id)` (raises if not owned → 404);
    assign `:finding`
  - Preload or separately fetch: `Ads.unsafe_get_7d_insights(finding.ad_id)` →
    assign `:health_score` via `Analytics.get_latest_health_score(finding.ad_id)`
  - Add `Analytics.get_latest_health_score/1` — queries `ad_health_scores` for most recent
    row by `ad_id` ordered `computed_at DESC LIMIT 1`

- [x] [D12-T2][liveview] FindingDetailLive template — two-column layout
  - Left column: finding title (h2), body text, severity badge, inserted_at,
    link to ad (`/ads?ad_id=...` or label if no detail page yet)
  - Right column: "Evidence" card — `Enum.map(evidence, fn {k,v} -> key/value row end)`;
    "Health Score" card — `leak_score` as numeric (e.g. "75/100") + factors list
  - Acknowledge section: if `finding.acknowledged_at` is nil, show `<button phx-click="acknowledge">Mark as Reviewed</button>`; else show `"Reviewed on {date}"`

- [x] [D12-T3][liveview] Acknowledge event handler
  - `handle_event("acknowledge", _, socket)`:
    ```elixir
    case Analytics.acknowledge_finding(current_user, socket.assigns.finding.id) do
      {:ok, updated} -> {:noreply, assign(socket, :finding, updated)}
      {:error, _cs}  -> {:noreply, put_flash(socket, :error, "Could not acknowledge finding")}
    end
    ```

- [x] [D12-T4][liveview] Back navigation
  - Store `return_params` in socket (from query string, e.g. `?severity=high&page=2`)
  - "← Back to Findings" link: `~p"/findings?#{@return_params}"`

- [x] [D12-T5][liveview][test] `test/ad_butler_web/live/finding_detail_live_test.exs`
  - Renders finding title, severity badge, evidence keys
  - Acknowledge button: click → acknowledged_at set, button replaced by confirmation text
  - Cross-tenant access: navigating to another user's finding ID redirects (404 or redirect)
  - Back link preserves query params

---

### Verification

- [ ] [V-T1] `mix compile --warnings-as-errors` — zero warnings
- [ ] [V-T2] `mix format --check-formatted`
- [ ] [V-T3] `mix credo --strict lib/ad_butler/analytics/ lib/ad_butler/workers/budget_leak_auditor_worker.ex lib/ad_butler/workers/audit_scheduler_worker.ex lib/ad_butler_web/live/findings_live.ex lib/ad_butler_web/live/finding_detail_live.ex`
- [ ] [V-T4] `mix test` — all pass
- [ ] [V-T5] `mix precommit` — final gate

---

## Iron Law Checks

- All `Analytics` queries scope via `Accounts.list_meta_connection_ids_for_user/1` + `ad_accounts` join — no cross-tenant data leaks ✓
- `BudgetLeakAuditorWorker` queries by `ad_account_id` (trusted internal system arg, not user input) — no tenant leak ✓
- `paginate_findings/2` is always paginated — no unbounded list ✓
- `FindingsLive` uses `stream/3` for the findings collection ✓
- No DaisyUI component classes — severity badges use plain Tailwind utilities ✓
- `BudgetLeakAuditor` is idempotent — dedup by `(ad_id, kind)` WHERE `resolved_at IS NULL` ✓
- Unique partial index on `(ad_id, kind) WHERE resolved_at IS NULL` enforces dedup at DB level ✓

---

## Risks

1. **`insights_daily` schema doesn't have `ad_account_id`** — The Insight schema may only have `ad_id`. The auditor loads insights by `ad_account_id` via a join to `ads.ad_account_id`. Verify by checking migration and Insight schema; adjust `load_48h_insights/1` query to join through `ads` if needed.

2. **Materialized view refresh race** — `Ads.unsafe_get_30d_baseline/1` reads the `ad_insights_30d` materialized view, which may be stale. Auditor runs every 6h; view refreshes every 1h. Max staleness is 1h — acceptable. Document the staleness expectation.

3. **`REFRESH MATERIALIZED VIEW CONCURRENTLY` in tests** — `DataCase` wraps each test in a transaction; `CONCURRENTLY` cannot run inside a transaction. Tests that rely on mat view data should refresh non-concurrently or seed the view table directly. Pattern: `Repo.query!("REFRESH MATERIALIZED VIEW ad_insights_30d")` in test setup (no `CONCURRENTLY`).

4. **Placement drag heuristic needs ad_set_id in insights** — `insights_daily` rows don't have `ad_set_id` directly. The auditor must join `ads` to resolve `ad_set_id` for grouping. Either add `ad_set_id` to the `load_48h_insights/1` query (join through `ads`) or do a separate `Ads.list_ads_by_ad_account/1` to build the `ad_id → ad_set_id` map.

5. **Partial unique index on findings** — `CREATE UNIQUE INDEX CONCURRENTLY` on a partial condition (`WHERE resolved_at IS NULL`) cannot be done inside a migration transaction. Use `disable_ddl_transaction()` + `disable_migration_lock()` in the migration, or use a regular unique index with application-level dedup as the primary guard and DB as the safety net.

---

## Acceptance Criteria

- For a real ad account with ≥1 underperforming ad, auditor identifies it within 6 hours of first insights sync
- `FindingsLive` renders paginated findings with severity/kind filters working
- Acknowledge flow sets `acknowledged_at` + `acknowledged_by_user_id` and hides the button
- User B cannot see User A's findings (tenant isolation test passing)
- `mix precommit` passes with no warnings, no credo violations, all tests green
