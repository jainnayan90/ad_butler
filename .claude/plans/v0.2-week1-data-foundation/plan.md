# Plan: v0.2 Week 1 — Data Foundation + Ingestion Pipeline (Days 1–6)

**Goal:** `insights_daily` partitioned table, materialized views, `Meta.Client.get_insights/3`,
`InsightsPipeline` Broadway, scheduler Oban workers — all tested and precommit-clean.

**Branch:** `v0.2-week1-data-foundation`  
**Depth:** Standard

---

## Context

### What Exists (baseline)

- `AdButler.Ads` context — campaigns / ad_sets / ads / creatives, with `scope/2`, `bulk_upsert_*`, `list_ad_accounts/1`
- `AdButler.Sync.MetadataPipeline` — Broadway template to mirror for `InsightsPipeline`
- `AdButler.Messaging.RabbitMQTopology` — one fanout exchange + `ad_butler.sync.metadata` queue + DLQ
- `AdButler.Meta.Client` — `list_*`, `get_rate_limit_usage/1`; no `get_insights/3` yet
- `AdButler.Meta.ClientBehaviour` — behaviour to add `get_insights/3` callback to
- All v0.1 migrations run; latest is `20260426073408_add_bm_id_and_bm_name_to_ad_accounts.exs`
- Oban installed, `SyncAllConnectionsWorker` + `TokenRefreshWorker` already registered

### Architecture Decisions

- `insights_daily` partitioned `BY RANGE (date_start)`, weekly partitions, composite PK `(ad_id, date_start)`
- Two materialized views: `ad_insights_7d` (15-min refresh) and `ad_insights_30d` (1-hour refresh)
- `InsightsPipeline` = two Broadway queues: `insights.delivery` (30-min cycle) + `insights.conversions` (2h cycle)
- Scheduler fans out one RabbitMQ message per active AdAccount with jitter (`rem(:erlang.phash2/1, 1800)` secs)
- `BudgetLeakAuditorWorker` is Week 2 — not in scope here

---

## Tasks

### Day 1 — Partitioned Insights Table

- [x] [P1-T1][ecto] Migration `priv/repo/migrations/20260426100001_create_insights_daily.exs`:
  ```sql
  execute """
  CREATE TABLE insights_daily (
    ad_id UUID NOT NULL REFERENCES ads(id) ON DELETE CASCADE,
    date_start DATE NOT NULL,
    spend_cents BIGINT NOT NULL DEFAULT 0,
    impressions BIGINT NOT NULL DEFAULT 0,
    clicks BIGINT NOT NULL DEFAULT 0,
    reach_count BIGINT NOT NULL DEFAULT 0,
    frequency NUMERIC(10,4),
    conversions BIGINT NOT NULL DEFAULT 0,
    conversion_value_cents BIGINT NOT NULL DEFAULT 0,
    ctr_numeric NUMERIC(10,6),
    cpm_cents BIGINT,
    cpc_cents BIGINT,
    cpa_cents BIGINT,
    by_placement_jsonb JSONB,
    by_age_gender_jsonb JSONB,
    inserted_at TIMESTAMP NOT NULL DEFAULT NOW(),
    PRIMARY KEY (ad_id, date_start)
  ) PARTITION BY RANGE (date_start)
  """
  ```
  Add index: `CREATE INDEX ON insights_daily (ad_id, date_start DESC)`

- [x] [P1-T2][ecto] Migration `20260426100002_create_insights_initial_partitions.exs`:
  - SQL helper function `create_insights_partition(date DATE)` that creates `insights_daily_YYYY_Www` partition. Use `CREATE TABLE IF NOT EXISTS` for idempotency.
  - Call it for current week + next 3 weeks (4 partitions total).
  - Verify `execute` blocks used (no `Repo.query` in migrations).

- [x] [P1-T3][ecto] `AdButler.Ads.Insight` schema at `lib/ad_butler/ads/insight.ex`:
  - `@primary_key false`
  - `belongs_to :ad, AdButler.Ads.Ad, type: :binary_id`
  - All numeric fields, two `:map` JSONB fields, `:date` field `date_start`
  - No changeset — write-only via `bulk_upsert_insights/1`
  - `@moduledoc` + `@doc false` for schema fields as per CLAUDE.md

- [x] [P1-T4][ecto] Tests `test/ad_butler/ads/insight_test.exs`:
  - Insert a row with `date_start` in current week; query `pg_inherits` / child table to assert correct partition routing
  - Assert UNIQUE violation on duplicate `(ad_id, date_start)` raises `Ecto.ConstraintError`
  - Both tests use `async: false` (DDL touches shared schema state)

---

### Day 2 — PartitionManagerWorker

- [x] [P2-T1][oban] `AdButler.Workers.PartitionManagerWorker` at `lib/ad_butler/workers/partition_manager_worker.ex`:
  - `use Oban.Worker, queue: :default, max_attempts: 3`
  - `perform/1`: creates next 2 weekly partitions using `CREATE TABLE IF NOT EXISTS` (idempotent)
  - Detaches partitions older than 13 months: `SELECT child.relname FROM pg_inherits JOIN pg_class child ON child.oid = pg_inherits.inhrelid JOIN pg_class parent ON parent.oid = pg_inherits.inhparentid WHERE parent.relname = 'insights_daily'`; parse week from relname; `ALTER TABLE insights_daily DETACH PARTITION <name>` for any older than 13m
  - Logs each partition created/detached with structured key-value metadata
  - `@moduledoc` + `@doc` for `perform/1`

- [x] [P2-T2][oban] Safety monitor in `perform/1`: after creating, count future partitions from `pg_inherits`. If < 2 → `Logger.error("insights partitions critical: fewer than 2 future partitions", count: n)`

- [x] [P2-T3][oban] Register cron in `config/config.exs`:
  ```elixir
  %{worker: AdButler.Workers.PartitionManagerWorker, cron: "0 3 * * 0"}  # Sunday 3am
  ```

- [x] [P2-T4][oban] Tests `test/ad_butler/workers/partition_manager_worker_test.exs`:
  - `perform/1` creates partitions for next 2 weeks (assert `pg_inherits` row count increases by 2)
  - Idempotent: second `perform/1` call creates 0 new partitions
  - Detach: manually create a "old" partition with a date >13 months ago in the relname; assert it's detached after `perform/1`

---

### Day 3 — Materialized Views + MatViewRefreshWorker

- [x] [P3-T1][ecto] Migration `20260426100003_create_ad_insights_7d_view.exs`:
  ```sql
  CREATE MATERIALIZED VIEW ad_insights_7d AS
  SELECT
    ad_id,
    SUM(spend_cents) AS spend_cents,
    SUM(impressions) AS impressions,
    SUM(clicks) AS clicks,
    SUM(conversions) AS conversions,
    SUM(conversion_value_cents) AS conversion_value_cents,
    CASE WHEN SUM(impressions) > 0 THEN SUM(clicks)::numeric / SUM(impressions) ELSE 0 END AS ctr,
    CASE WHEN SUM(impressions) > 0 THEN SUM(spend_cents) * 1000 / SUM(impressions) ELSE 0 END AS cpm_cents,
    CASE WHEN SUM(clicks) > 0 THEN SUM(spend_cents) / SUM(clicks) ELSE 0 END AS cpc_cents,
    CASE WHEN SUM(conversions) > 0 THEN SUM(spend_cents) / SUM(conversions) ELSE 0 END AS cpa_cents
  FROM insights_daily
  WHERE date_start >= CURRENT_DATE - INTERVAL '7 days'
  GROUP BY ad_id
  WITH NO DATA;
  CREATE UNIQUE INDEX ON ad_insights_7d (ad_id);
  ```

- [x] [P3-T2][ecto] Migration `20260426100004_create_ad_insights_30d_view.exs`: same structure, `INTERVAL '30 days'`. Unique index on `ad_id`. `WITH NO DATA`.

- [x] [P3-T3][oban] `AdButler.Workers.MatViewRefreshWorker` at `lib/ad_butler/workers/mat_view_refresh_worker.ex`:
  - Pattern-match on `%{"view" => "7d"}` / `%{"view" => "30d"}` in `perform/1`
  - `Repo.query!("REFRESH MATERIALIZED VIEW CONCURRENTLY ad_insights_7d")` (or 30d)
  - Time the refresh with `:timer.tc/1`; log `duration_ms` structured
  - `@moduledoc` + two `@doc` clauses

- [x] [P3-T4][oban] Register both crons:
  ```elixir
  %{worker: AdButler.Workers.MatViewRefreshWorker, cron: "*/15 * * * *", args: %{"view" => "7d"}},
  %{worker: AdButler.Workers.MatViewRefreshWorker, cron: "0 * * * *", args: %{"view" => "30d"}}
  ```

- [x] [P3-T5][ecto] `Ads.get_7d_insights(ad_id)` and `Ads.get_30d_baseline(ad_id)` in `ads.ex`:
  - `Repo.one(from v in "ad_insights_7d", where: v.ad_id == ^ad_id, select: map(v, [...]))`
  - Return `{:ok, map}` or `{:ok, nil}`
  - Tests: insert known `insights_daily` rows; call `Repo.query!("REFRESH MATERIALIZED VIEW ad_insights_7d")` (non-concurrent in test); assert aggregates match expected values

---

### Day 4 — Meta Client Insights API

- [x] [P4-T1][ecto] Add `get_insights/3` to `AdButler.Meta.ClientBehaviour` (`lib/ad_butler/meta/client_behaviour.ex`):
  ```elixir
  @callback get_insights(ad_account_id :: String.t(), access_token :: String.t(), opts :: keyword()) ::
    {:ok, [map()]} | {:error, term()}
  ```

- [x] [P4-T2][ecto] Implement `get_insights/3` in `AdButler.Meta.Client` (`lib/ad_butler/meta/client.ex`):
  - `GET /{ad_account_id}/insights`
  - params: `level: "ad"`, fields: `"ad_id,date_start,spend,impressions,clicks,reach,frequency,ctr,cpm,cpc,actions,action_values"`, `time_range: %{since: ..., until: ...}`, `breakdowns: "publisher_platform"`
  - Extract `time_range` from opts; default = last 2 days
  - Returns `{:ok, [map()]} | {:error, term()}`
  - Private helper `extract_conversions(actions_list)` — sums `value` where `action_type == "offsite_conversion.fb_pixel_purchase"` or `"purchase"`
  - All numeric fields parsed from strings to integers/floats

- [x] [P4-T3][ecto] Tests `test/ad_butler/meta/client_test.exs` (new section — use Req.Test / bypass for existing tests' style):
  - Happy path: mock 200 with 2 rows; assert both parsed, `conversions` extracted
  - 400 insufficient permissions: returns `{:error, %{code: 200, ...}}`
  - 429 rate limit: returns `{:error, :rate_limited}`
  - `extract_conversions/1` unit test for mixed action types

- [x] [P4-T4][ecto] `Ads.bulk_upsert_insights/1` in `ads.ex`:
  ```elixir
  Repo.insert_all("insights_daily", rows,
    on_conflict: {:replace, [:spend_cents, :impressions, :clicks, :reach_count,
                              :frequency, :conversions, :conversion_value_cents,
                              :ctr_numeric, :cpm_cents, :cpc_cents, :cpa_cents,
                              :by_placement_jsonb, :by_age_gender_jsonb]},
    conflict_target: [:ad_id, :date_start]
  )
  ```
  - Input: list of maps with string-valued Meta fields; function normalises to cents/integers
  - Returns `{:ok, count}` or `{:error, term()}`
  - Tests: insert 3 rows, re-upsert 2 of them with changed values; assert updated values + total row count = 3

---

### Day 5 — Insights Pipeline (Broadway)

- [x] [P5-T1][ecto] Add insights queues to `AdButler.Messaging.RabbitMQTopology` (`lib/ad_butler/messaging/rabbitmq_topology.ex`):
  - New exchange: `ad_butler.insights.fanout`
  - Two queues: `ad_butler.insights.delivery` and `ad_butler.insights.conversions`
  - Each bound to its own DLQ (`ad_butler.insights.delivery.dlq`, `ad_butler.insights.conversions.dlq`)
  - DLQ exchange: `ad_butler.insights.dlq.fanout`
  - Add to `declare_topology/1` via `with` chain

- [x] [P5-T2][ecto] `AdButler.Sync.InsightsPipeline` at `lib/ad_butler/sync/insights_pipeline.ex`:
  - Mirror `MetadataPipeline` structure — `start_link/1`, `handle_message/3`, `handle_batch/4`
  - `handle_message/3`: decode `{ad_account_id, sync_type}` from JSON data; resolve `AdAccount` (internal scope `list_ad_accounts_internal/1`); tag message `meta_connection_id` for batching
  - `handle_batch/4`: for each unique `meta_connection_id` in batch, decrypt access token, call `Meta.Client.get_insights/3` with 2-day window for `:delivery` or 7-day for `:conversions`, then `Ads.bulk_upsert_insights/1`
  - Rate-limit guard: `if Meta.Client.get_rate_limit_usage(account.meta_id) > 0.85`, `Logger.warning("insights skipped: rate limit", ...)` and skip that account
  - Uses `Application.get_env(:ad_butler, :meta_client, Meta.Client)` for testability
  - Producer: `Broadway.DummyProducer` in test env (same pattern as `MetadataPipeline`)

- [x] [P5-T3][ecto] Register `InsightsPipeline` in `AdButler.Application` (`lib/ad_butler/application.ex`):
  - Add `{AdButler.Sync.InsightsPipeline, []}` alongside `MetadataPipeline`, guarded by `Mix.env() != :test` (same pattern)

- [x] [P5-T4][ecto] Tests `test/ad_butler/sync/insights_pipeline_test.exs`:
  - Setup: `Mox.set_mox_global` + stub `Meta.ClientMock`
  - Happy path: push 1 delivery message via `Broadway.test_message/2`, drain, assert `Ads.bulk_upsert_insights/1` called and row in DB
  - Rate-limit skip: stub `get_rate_limit_usage` to return `0.90`, push message, assert NO insights upserted, assert warning logged (capture log)

---

### Day 6 — Insights Scheduler Workers

- [x] [P6-T1][oban] `AdButler.Workers.InsightsSchedulerWorker` at `lib/ad_butler/workers/insights_scheduler_worker.ex`:
  - `perform/1`: call `Ads.list_ad_accounts_internal()` (all active ad accounts, no tenant scope — internal only)
  - For each account: compute jitter = `rem(:erlang.phash2(account.meta_id), 1800)`, publish `%{ad_account_id: account.id, sync_type: "delivery"}` to `ad_butler.insights.delivery` queue after `scheduled_at: DateTime.add(DateTime.utc_now(), jitter, :second)`
  - Uses `AdButler.Messaging.Publisher` (existing behaviour)
  - `@moduledoc` + `@doc` for `perform/1`

- [x] [P6-T2][oban] `AdButler.Workers.InsightsConversionWorker` at `lib/ad_butler/workers/insights_conversion_worker.ex`:
  - Same structure as `InsightsSchedulerWorker` but `sync_type: "conversions"` and `ad_butler.insights.conversions` queue

- [x] [P6-T3][oban] Register crons in `config/config.exs`:
  ```elixir
  %{worker: AdButler.Workers.InsightsSchedulerWorker, cron: "*/30 * * * *"},
  %{worker: AdButler.Workers.InsightsConversionWorker, cron: "0 */2 * * *"}
  ```

- [x] [P6-T4][oban] Tests `test/ad_butler/workers/insights_scheduler_worker_test.exs` and `insights_conversion_worker_test.exs`:
  - Seed 3 active ad accounts; call `perform(%{})` via `Oban.Testing.perform_job/2`
  - Assert 3 messages published (mock `AdButler.Messaging.PublisherMock`)
  - Assert jitter for each account is in `[0, 1800)` range
  - Both delivery and conversions workers tested

---

### Day 6 (end) — Verification

- [x] [V1] `mix precommit` — clean compile (warnings as errors), Credo strict, all tests green
- [x] [V2] Manual check: inspect `pg_inherits` for `insights_daily` shows 4+ partitions
- [x] [V3] Manual check: `\dm` in psql shows `ad_insights_7d` and `ad_insights_30d` views

---

## Iron Law Checks

- All `insights_daily` writes go through `Ads.bulk_upsert_insights/1` — no direct `Repo` in pipeline ✓
- No user-facing reads on `insights_daily` in this week (auditor is Week 2) — no tenant scope needed yet ✓
- `PartitionManager` uses `CREATE TABLE IF NOT EXISTS` and detaches (not drops) — reversible ✓
- `InsightsPipeline` calls behaviour via `Application.get_env`, never the real client directly ✓
- No unbounded queries — `get_insights/3` max window is 7 days, bounded results ✓

---

## Risks

1. **Partitioned table migration**: `CREATE TABLE ... PARTITION BY RANGE` requires no existing data. Safe on fresh table.
2. **Materialized view `CONCURRENTLY`**: requires unique index on `ad_id` — migration P3-T1/T2 add these. In tests use non-concurrent refresh (can't run concurrent inside a transaction).
3. **RabbitMQ topology change**: adding new exchanges/queues to `declare_topology/1` is additive and safe; existing metadata queue unaffected.
4. **`get_insights/3` field shape**: Meta returns `actions` as a list of `%{"action_type" => ..., "value" => ...}` — `extract_conversions/1` must handle nil actions list gracefully.
5. **`list_ad_accounts_internal/1`**: scheduler needs ALL active ad accounts (no user scope). Confirm `Ads.ex` has an internal variant or add one clearly marked `@doc "UNSAFE — internal use only"`.
