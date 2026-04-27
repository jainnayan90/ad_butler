# Plan: v0.2 — Insights Warehouse + Budget Leak Auditor

## Goal
Insights are flowing and the Budget Leak Auditor produces findings a real media buyer would nod at. No chat yet.

**Scope**: `insights_daily` partitioned table · `InsightsPipeline` Broadway · `BudgetLeakAuditor` Oban job · `findings` + `ad_health_scores` Ecto schemas · `FindingsLive` inbox · email digest.

---

## What Exists (v0.1 baseline)

| Already built | NOT built |
|---|---|
| `Ads` context — campaigns/ad_sets/ads/creatives | `insights_daily` table or schema |
| `MetadataPipeline` Broadway (ad objects) | `Analytics` context |
| `FetchAdAccountsWorker` + `SyncAllConnectionsWorker` | `Notifications` context |
| `Meta.Client` — list_campaigns, list_ad_sets, list_ads | Insights API calls |
| `llm_usage` + `llm_pricing` + `user_quotas` tables | `findings` / `ad_health_scores` tables |
| Swoosh in deps (not configured for mailer) | Email templates / mailer adapter |
| Sidebar nav (Connections, Ad Accounts, Campaigns, Ad Sets, Ads) | Findings nav item |

---

## Architecture Decisions (locked)

- **D0002**: Native partitioned Postgres. `insights_daily` partitioned `BY RANGE (date_start)`, weekly partitions. No Timescale.
- **Materialized views** for rolling aggregates: 7d CTR/spend/impressions refreshed every 15 min; 30d CPA baseline refreshed hourly.
- **One InsightsPipeline** with two message types: `:delivery` (30-min cycle, last 2 days) and `:conversions` (2h cycle, last 7 days). Two queues on same exchange, same Broadway processor.
- **BudgetLeakAuditor runs per-ad-account** as an Oban job, scheduled by `SyncAllConnectionsWorker` after each metadata sync completes.
- **No LLM calls** in v0.2.

---

## Breadboard

```
Nav (sidebar)
├── Findings  →  FindingsLive           (NEW — add to sidebar + router)

Data flow:
  InsightsSchedulerWorker (Oban cron, 30 min)
    → publishes {ad_account_id, sync_type: :delivery} to RabbitMQ
  InsightsConversionWorker (Oban cron, 2h)
    → publishes {ad_account_id, sync_type: :conversions} to RabbitMQ
  InsightsPipeline (Broadway)
    → calls Meta API get_insights/3
    → bulk upserts insights_daily
  PartitionManager (Oban Sunday cron)
    → CREATE PARTITION for next week
    → DETACH partitions > 13 months old
  MatViewRefreshWorker (Oban cron, 15 min / 1h)
    → REFRESH MATERIALIZED VIEW CONCURRENTLY
  BudgetLeakAuditorWorker (Oban, triggered after metadata sync)
    → reads insights_daily + mat views + ad_sets raw_jsonb
    → writes ad_health_scores + findings
  FindingsLive
    → lists findings filtered by severity/kind, paginated
    → drill-down: evidence JSONB + ad health score
  DigestMailer (Oban cron, daily/weekly)
    → queries high-severity findings
    → sends Swoosh email
```

---

## Tasks

### Week 1 — Data Foundation + Ingestion Pipeline (Days 1–6)

#### Day 1 — Partitioned Insights Table

- [ ] [P1-T1][ecto] Migration: `CREATE TABLE insights_daily PARTITION BY RANGE (date_start)` — fields: `ad_id`, `date_start`, `spend_cents`, `impressions`, `clicks`, `reach_count`, `frequency`, `conversions`, `conversion_value_cents`, `ctr_numeric`, `cpm_cents`, `cpc_cents`, `cpa_cents`, `by_placement_jsonb`, `by_age_gender_jsonb`, `inserted_at`. Use `execute` blocks. Composite primary key `(ad_id, date_start)` on partitioned table.
- [ ] [P1-T2][ecto] Migration: Create initial partitions — current week + next 3 weeks. Helper SQL function `create_insights_partition(date)` in migration for reuse by `PartitionManager`. Index `(ad_id, date_start DESC)` at partitioned-table level (propagates to children).
- [ ] [P1-T3][ecto] `Insight` Ecto schema (`AdButler.Ads.Insight`) — `@primary_key false`, `belongs_to :ad`, all numeric fields, two JSONB fields. No changeset needed — bulk-only writes.
- [ ] [P1-T4][ecto] Test: verify partition routing — insert a row with `date_start` in current week, assert it lands in the correct child table. Test UNIQUE violation on `(ad_id, date_start)`.

#### Day 2 — PartitionManager Oban Job

- [ ] [P2-T1][oban] `AdButler.Workers.PartitionManagerWorker` — runs Sunday at `0 3 * * 0` (cron). Creates next two weekly partitions (idempotent: `CREATE TABLE IF NOT EXISTS`). Detaches partitions older than 13 months by querying `pg_inherits` + `pg_class`. Logs partition names created/detached.
- [ ] [P2-T2][oban] Register cron in `config/config.exs` alongside existing Oban cron entries.
- [ ] [P2-T3][oban] Safety monitor: after creating partitions, query `pg_inherits` to count future partitions. If fewer than 2 future partitions exist, `Logger.error` with a clear message. Test: mock the query to return 1 future partition, assert the error is logged.
- [ ] [P2-T4][oban] Tests: 3 cases — partitions created for new weeks, idempotent on second run, detach logic for old partition.

#### Day 3 — Materialized Views + Refresh Worker

- [ ] [P3-T1][ecto] Migration: `CREATE MATERIALIZED VIEW ad_insights_7d` — for each `ad_id`, last 7 days sum of spend/impressions/clicks/conversions, computed CTR/CPM/CPC/CPA from sums. Unique index on `ad_id`. `CONCURRENTLY` refresh-safe means `WITH NO DATA` on creation (refreshed by worker).
- [ ] [P3-T2][ecto] Migration: `CREATE MATERIALIZED VIEW ad_insights_30d` — same but 30-day window. Used for CPA baseline in the auditor.
- [ ] [P3-T3][oban] `AdButler.Workers.MatViewRefreshWorker` — two clauses: `perform(%{"view" => "7d"})` runs `REFRESH MATERIALIZED VIEW CONCURRENTLY ad_insights_7d`; `perform(%{"view" => "30d"})` does same for 30d. Both time the refresh and log duration.
- [ ] [P3-T4][oban] Register cron: 7d view every 15 min (`*/15 * * * *`), 30d view every hour (`0 * * * *`).
- [ ] [P3-T5][ecto] `Ads.get_7d_insights(ad_id)` and `Ads.get_30d_baseline(ad_id)` — simple `Repo.one` queries against the views. Tests: insert known `insights_daily` rows, refresh view in test (non-concurrently), assert aggregates.

#### Day 4 — Meta Client Insights API

- [ ] [P4-T1][ecto] `AdButler.Meta.Client.get_insights/3` — `get_insights(ad_account_id, access_token, opts)`. Calls `GET /{ad_account_id}/insights` with `level: "ad"`, `fields: "ad_id,date_start,spend,impressions,clicks,reach,frequency,ctr,cpm,cpc,actions,action_values"`, `time_range`, breakdowns on `publisher_platform` for placement data. Returns `{:ok, [map()]}` or `{:error, term()}`. No pagination needed (date window is at most 7 days → bounded results).
- [ ] [P4-T2][ecto] Add `get_insights/3` to `AdButler.Meta.ClientBehaviour`.
- [ ] [P4-T3][ecto] Tests for `get_insights/3` — happy path (200 with data list), 400 (insufficient permission), 429 rate limit, fields mapping for `actions` → conversions extraction helper `extract_conversions/1`.
- [ ] [P4-T4][ecto] `Ads.bulk_upsert_insights/1` — `Repo.insert_all` with `on_conflict: {:replace, [...]}`, `conflict_target: [:ad_id, :date_start]`. Parses Meta's string-formatted numerics to cents/integers. Tests: upsert idempotency, re-upsert updates values.

#### Day 5 — Insights Pipeline (Broadway)

- [ ] [P5-T1][ecto] RabbitMQ topology: add `insights.delivery` and `insights.conversions` queues to `AdButler.Messaging.RabbitMQTopology`. DLQ entries for both.
- [ ] [P5-T2][ecto] `AdButler.Sync.InsightsPipeline` Broadway module — mirrors `MetadataPipeline` structure. `handle_message/3` decodes `{ad_account_id, sync_type}`, resolves `AdAccount` + `MetaConnection`. `handle_batch/4` groups by `meta_connection_id`, calls `get_insights/3` for each account in batch, calls `Ads.bulk_upsert_insights/1`. Rate-limit-aware: if `Meta.Client.get_rate_limit_usage(account.meta_id) > 0.85`, skip this cycle and `Logger.warning`.
- [ ] [P5-T3][ecto] Register `InsightsPipeline` in `Application.start/2` alongside `MetadataPipeline` (non-test only).
- [ ] [P5-T4][ecto] Tests: Broadway DummyProducer test — happy path upserts insights, rate-limit skip logs warning and does not call Meta API.

#### Day 6 — Insights Scheduler Workers

- [ ] [P6-T1][oban] `AdButler.Workers.InsightsSchedulerWorker` — fans out one `{ad_account_id, sync_type: "delivery"}` RabbitMQ message per active `AdAccount` (via `Ads.list_ad_accounts(mc_ids)` for all active connections). Jitter: `rem(:erlang.phash2(ad_account.meta_id), 1800)` seconds delay per account so no thundering herd at :00.
- [ ] [P6-T2][oban] `AdButler.Workers.InsightsConversionWorker` — same fan-out but `sync_type: "conversions"` (last 7 days window). Runs every 2 hours.
- [ ] [P6-T3][oban] Register crons: delivery every 30 min (`*/30 * * * *`), conversions every 2h (`0 */2 * * *`).
- [ ] [P6-T4][oban] Tests: both workers fan out correct message count for N active ad accounts; jitter produces values in `[0, 1800)`.

---

### Week 2 — Auditor + Findings (Days 7–12)

#### Day 7 — Analytics Context + Schemas

- [ ] [P7-T1][ecto] Migration: `CREATE TABLE ad_health_scores` — `id :binary_id`, `ad_id` FK, `computed_at :utc_datetime_usec`, `leak_score :decimal`, `fatigue_score :decimal`, `leak_factors :map`, `fatigue_factors :map`, `recommended_action :string`. Index `(ad_id, computed_at DESC)`. Append-only; most recent row per ad = current score.
- [ ] [P7-T2][ecto] Migration: `CREATE TABLE findings` — `id :binary_id`, `ad_id` FK, `ad_account_id` FK (for fast inbox queries), `kind :string`, `severity :string` (`low/medium/high`), `title :string`, `body :text`, `evidence :map`, `acknowledged_at :utc_datetime_usec`, `acknowledged_by_user_id` FK nullable, `resolved_at :utc_datetime_usec`, `resolution :text`, `inserted_at`. Indexes: `(ad_account_id, severity, inserted_at DESC)`, `(ad_id, kind)`.
- [ ] [P7-T3][ecto] `AdButler.Analytics.AdHealthScore` schema + changeset.
- [ ] [P7-T4][ecto] `AdButler.Analytics.Finding` schema + changeset. `validate_inclusion(:severity, ~w(low medium high))`.
- [ ] [P7-T5][ecto] `AdButler.Analytics` context — `list_findings_for_user/2` (scoped via mc_ids → ad_account_ids → findings), `paginate_findings/2`, `get_finding!/2`, `acknowledge_finding/2`, `create_finding/1`, `upsert_ad_health_score/1`. Tenant isolation: scope through `ad_account_id IN (SELECT id FROM ad_accounts WHERE meta_connection_id IN ...)`.
- [ ] [P7-T6][ecto] Tests: 3 tests per context function — happy path, tenant isolation (user B sees nothing), pagination.

#### Day 8 — BudgetLeakAuditor: Dead Spend + CPA Explosion

- [ ] [P8-T1][oban] `AdButler.Analytics.BudgetLeakAuditor` — Oban worker `perform(%{"ad_account_id" => id})`. Loads ad account + connection + last 48h of `insights_daily` rows for all ads in account. Emits findings and upserts `ad_health_scores`. Returns `:ok`.
- [ ] [P8-T2][oban] **Heuristic 1 — Dead Spend**: for each ad in account, if `SUM(spend_cents, last 48h) > 500` (configurable, ~$5) AND `SUM(conversions, last 48h) == 0` AND reach uplift < 5%  → emit finding `kind: "dead_spend"`, `severity: "high"`. Evidence: `%{spend_cents: X, period_hours: 48, conversions: 0}`.
- [ ] [P8-T3][oban] **Heuristic 2 — CPA Explosion**: for each ad, if 3-day CPA (`sum spend / sum conversions`) > `2.5 × 30d_baseline_cpa` AND conversions > 0 in both windows → `kind: "cpa_explosion"`, `severity: "high"`. Evidence: `%{cpa_3d: X, cpa_30d_baseline: Y, ratio: Z}`.
- [ ] [P8-T4][oban] Deduplication: before writing a finding, check if an unresolved finding of the same `(ad_id, kind)` already exists — skip insert if so (idempotent). Only create new finding when resolved or first occurrence.
- [ ] [P8-T5][oban] Tests: seed known `insights_daily` + `ad_insights_30d` data, run auditor, assert findings created with correct severity and evidence. Test dedup: run auditor twice, assert only one finding per `(ad_id, kind)`.

#### Day 9 — BudgetLeakAuditor: Remaining Heuristics

- [ ] [P9-T1][oban] **Heuristic 3 — Bot-shaped Traffic**: for each ad, if `ctr_numeric > 0.05` (5%) AND `conversion_rate < 0.003` (0.3%) AND `by_placement_jsonb` shows audience_network or reels as dominant placement → `kind: "bot_traffic"`, `severity: "medium"`. Helper: `dominant_placement/1` reads `by_placement_jsonb`.
- [ ] [P9-T2][oban] **Heuristic 4 — Placement Drag**: group ads by `ad_set_id`. For each ad set with ≥2 placements in `by_placement_jsonb`, if `max(placement_cpa) / min(placement_cpa) > 3` → `kind: "placement_drag"`, `severity: "medium"`. Evidence: best and worst placement names + CPAs.
- [ ] [P9-T3][oban] **Heuristic 5 — Stalled Learning**: query `ad_sets` where `raw_jsonb->>'effective_status' = 'LEARNING'` AND `inserted_at < now() - 7 days` AND results (from insights) < 50 in last 7 days → `kind: "stalled_learning"`, `severity: "low"`. Note: this fires on the ad_set, not the ad — `ad_id` is the primary ad in the ad set (or emit per-ad).
- [ ] [P9-T4][oban] Scoring: compute `leak_score` as weighted sum of heuristics that fired (dead_spend: 40, cpa_explosion: 35, bot_traffic: 15, placement_drag: 7, stalled_learning: 3), capped at 100. Upsert `ad_health_scores` for each ad processed.
- [ ] [P9-T5][oban] Tests: all 3 new heuristics with seeded data. Test scoring formula produces expected `leak_score` for known heuristic combinations.

#### Day 10 — Auditor Scheduling + Wire-up

- [ ] [P10-T1][oban] `AdButler.Workers.AuditSchedulerWorker` — Oban cron, runs every 6 hours (`0 */6 * * *`). Fans out one `BudgetLeakAuditorWorker` job per active ad account. `unique: [period: 21_600, keys: [:ad_account_id]]` to prevent double-runs.
- [ ] [P10-T2][oban] Register `AuditSchedulerWorker` in cron config.
- [ ] [P10-T3][oban] Integration smoke test: use `Oban.Testing` helpers — drain the queue, assert expected findings are created for a seeded dataset across all 5 heuristics.
- [ ] [P10-T4] `mix precommit` — clean compile, credo, tests green.

#### Day 11 — FindingsLive (List + Filters)

- [ ] [P11-T1][liveview] Add `Findings` nav item to sidebar in `Layouts.app` (`hero-flag` icon, `:findings` active atom). Add route `live "/findings", FindingsLive` inside `live_session :authenticated`.
- [ ] [P11-T2][liveview] `AdButlerWeb.FindingsLive` — mount initializes empty stream, `handle_params/3` calls `Analytics.paginate_findings(current_user, opts)`. Filters: `severity` (low/medium/high), `kind` (dead_spend/cpa_explosion/bot_traffic/placement_drag/stalled_learning), `ad_account_id`. `push_patch` on filter changes.
- [ ] [P11-T3][liveview] Render: stat card (finding count), filter form (3 selects), stream table — columns: Ad Name (link to finding detail), Kind (human label), Severity (badge: red/yellow/blue), Inserted At. Pagination component.
- [ ] [P11-T4][liveview] Severity badge colors: `high` → red, `medium` → yellow, `low` → blue. Human labels for kind: `"dead_spend"` → "Dead Spend", etc.

#### Day 12 — FindingsLive (Detail + Acknowledge)

- [ ] [P12-T1][liveview] Route: `live "/findings/:id", FindingDetailLive`. `handle_params/3` calls `Analytics.get_finding!(current_user, id)` — scoped (raises if not owned).
- [ ] [P12-T2][liveview] `FindingDetailLive` render — two-column: left: finding title, body, severity badge, inserted_at, ad link; right: evidence card (pretty-print `evidence` JSONB as key-value pairs), ad health score card (leak_score bar, factors list).
- [ ] [P12-T3][liveview] Acknowledge button — `handle_event("acknowledge", ...)` calls `Analytics.acknowledge_finding/2`. Hides button and shows "Acknowledged by you on {date}" afterwards.
- [ ] [P12-T4][liveview] Back link to `/findings` with current filters preserved (pass via query param).

---

### Week 3 — Polish + Ship (Days 13–15)

#### Day 13 — Email Digest

- [ ] [P13-T1][ecto] Configure Swoosh mailer adapter. Add `AdButlerWeb.Mailer` module. Dev: `Swoosh.Adapters.Local` (already in Phoenix boilerplate). Prod: SMTP adapter via env var. Add `MAILER_ADAPTER`, `SMTP_*` to `.env.example` and `config/runtime.exs`.
- [ ] [P13-T2][oban] `AdButler.Notifications.DigestMailer` — Swoosh email template. Subject: "AdButler: N new high-severity findings (daily/weekly)". Body: list of findings with title + severity + ad name. Plain text + HTML.
- [ ] [P13-T3][oban] `AdButler.Workers.DigestWorker` — `perform(%{"user_id" => id, "period" => "daily"|"weekly"})`. Queries findings in last 24h/7d for the user. If 0 high/medium findings → skip (no email). Calls `DigestMailer.deliver/1`.
- [ ] [P13-T4][oban] `AdButler.Workers.DigestSchedulerWorker` — Oban cron: `0 8 * * *` (daily at 8am) fans out `DigestWorker` for each user with active connections. Weekly version: `0 8 * * 1` (Monday).
- [ ] [P13-T5][oban] Tests: `DigestMailer` unit test (assert fields), `DigestWorker` test with 0 findings (no delivery) and N findings (delivery called once).

#### Day 14 — E2E Validation + Precommit

- [ ] [P14-T1] Run `mix test` — target ≥ 95% of tests passing. Fix any regressions.
- [ ] [P14-T2] `mix precommit` — clean compile (warnings as errors), credo strict, all tests.
- [ ] [P14-T3] Manual smoke test with real Meta account: trigger `InsightsSchedulerWorker` manually via `Oban.insert`, watch `insights_daily` populate, trigger `BudgetLeakAuditorWorker`, verify findings appear in `FindingsLive`.
- [ ] [P14-T4] Verify partition exists for current week (query `pg_inherits`). Verify materialized views have data after refresh.

#### Day 15 — Design Partner Prep

- [ ] [P15-T1] Seed `llm_pricing` rows for Claude Sonnet + Haiku + OpenAI embeddings (needed for v0.3; harmless now). Prices: Sonnet input $3/1M tokens → `cents_per_1k_input: 0.3`, output $15/1M → `cents_per_1k_output: 1.5`.
- [ ] [P15-T2] Staging deploy — verify migrations run clean, Broadway pipelines start, Oban crons register.
- [ ] [P15-T3] `docs/plan/decisions/0005-findings-dedup-strategy.md` — document the `(ad_id, kind)` dedup decision and the "resolve before re-emit" policy.
- [ ] [P15-T4] Onboarding checklist for design partner: connect account → wait 30 min for first insights sync → check `/findings` for first findings.

---

## Iron Law Checks

- All `Analytics` queries pass through `paginate_findings/2` which scopes via `ad_account_id IN (SELECT id FROM ad_accounts WHERE meta_connection_id IN ...)` — no cross-tenant data leaks ✓
- No unbounded list loads — all findings queries paginated ✓
- `PartitionManager` never deletes data without detaching (detach is reversible); drop is a separate manual step ✓
- Email not sent when 0 findings — prevents noise to design partner ✓
- `BudgetLeakAuditor` is idempotent — re-running produces no duplicate findings ✓

---

## Risks

1. **Meta Insights API requires Advanced Access** for production-scale. Dev/test accounts work in Development mode. Confirm App Review is in progress before expecting real delivery data.
2. **Partition routing bug**: if `date_start` lands outside all existing partitions, Postgres raises. `PartitionManager` must keep 2 future partitions ahead; the Day 2 safety monitor catches this.
3. **Materialized view refresh blocks**: `CONCURRENTLY` requires a unique index — added in T1. Non-concurrent fallback in test environment (no concurrent refresh in transactions).
4. **Heuristic false positives**: Bot-traffic and placement drag heuristics may fire heavily on new accounts with little data. Mitigation: minimum spend threshold (e.g., > $10 total before evaluating) in each heuristic before emitting a finding.
5. **Bot-traffic heuristic needs placement data**: `by_placement_jsonb` only populated if the Meta API call includes `breakdowns: "publisher_platform"` — must be in the `get_insights/3` fields.

---

## Acceptance Criteria (from roadmap)

- For a real ad account with at least one underperforming ad, the auditor correctly identifies it within 24 hours.
- Insights sync completes within its 30-min window for the test cohort.
- One design partner actively logs in and reviews findings at least weekly.
- False-positive rate is manually reviewed for every finding in the first 2 weeks.
