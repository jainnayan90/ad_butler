# Architecture & Data Model

A planning document for the Meta Ads monitoring SaaS. Target: solo media buyers and SMB owners, designed to scale to ~1,000+ connected ad accounts near-real-time.

## 1. Guiding constraints

Four things drive almost every decision below:

- **Meta Insights API is polling-only for performance data.** Webhooks exist but only fire on account-level status changes (billing, approvals), not on new insights rows. We poll, and the polling strategy is the hot path.
- **Rate limits are per-app-per-ad-account.** Standard Access gives roughly `300 + 40 × active_ads` calls/hour per ad account. Advanced Access (required for us at scale) raises this to ~100,000 + 40 × active_ads, but requires App Review. Plan for Advanced Access from day one; design the pipeline so it stays polite even at Standard limits.
- **Insights data has 24–48h delay on conversions and ~1–4h delay on delivery metrics.** "Near-real-time" for this domain means every 15–30 minutes, not sub-second.
- **LLM tokens are the dominant variable cost.** Every chatbot turn, every auto-generated recommendation, every embedding for RAG costs money. The architecture must make token spend legible per-user from day one (see `03-token-monitoring.md`).

## 2. System overview

```
                        ┌─────────────────────────┐
                        │   Phoenix Web (LiveView)│
                        │   + REST endpoints      │
                        └────────────┬────────────┘
                                     │
         ┌───────────────────────────┼────────────────────────────┐
         │                           │                            │
         ▼                           ▼                            ▼
   ┌───────────┐              ┌─────────────┐            ┌─────────────┐
   │  Oban     │              │ Jido Agents │            │ Broadway    │
   │ (business │              │ (chat,      │            │ (sync)      │
   │  jobs)    │              │  tools)     │            │             │
   └─────┬─────┘              └──────┬──────┘            └──────┬──────┘
         │                           │                          │
         └────────────┬──────────────┴──────────────────────────┘
                      ▼
              ┌───────────────┐    ┌──────────────┐    ┌──────────────┐
              │  PostgreSQL   │    │ RabbitMQ     │    │  Redis /     │
              │  + pgvector   │    │ (queues)     │    │  Cachex      │
              │  (partitioned)│    │              │    │              │
              └───────────────┘    └──────────────┘    └──────────────┘
                      │
                      └── Meta Graph API (outbound, rate-limited)
```

Three independent pipelines compose the system:

1. **Sync pipeline** (Broadway → RabbitMQ → Meta API → Postgres): pulls insights and ad-object metadata on a schedule, writes a normalized warehouse.
2. **Analytics pipeline** (Oban jobs): runs the Budget Leak Auditor and Creative Fatigue Predictor against the warehouse; produces `findings` rows and `ad_health_scores`.
3. **Chat pipeline** (Jido agents invoked from LiveView): answers user questions, calls read tools over the warehouse, and optionally calls write tools (pause ad) via the Meta API.

Keeping these three pipelines independent matters. The chat path must never block on a slow Meta sync; the analytics path must never block on an LLM call.

## 3. Phoenix app layout (contexts)

Phoenix contexts map to the problem domain, not to the pipelines:

- `Accounts` — users, auth, Meta OAuth tokens, ad-account connections.
- `Meta` — thin Meta Graph API client; handles auth, rate-limit awareness, request shaping. Knows nothing about our domain.
- `Ads` — core domain entities: `AdAccount`, `Campaign`, `AdSet`, `Ad`, `Creative`, `Insight`. Read/write against Postgres.
- `Sync` — Broadway producers/consumers, RabbitMQ topology, per-account schedulers. Owns the polling policy.
- `Analytics` — the two analyzers: `BudgetLeakAuditor`, `CreativeFatiguePredictor`, plus the `Finding` and `AdHealthScore` entities.
- `Chat` — Jido agent definitions, tool modules (Actions), session persistence, streaming to LiveView.
- `Billing` — token usage ledger, per-user quotas. No payments in MVP; see `03-token-monitoring.md`.
- `Notifications` — email/in-app alerts when findings fire.

Rule of thumb: a context can depend on `Meta` and on lower-level contexts, but contexts at the same level (e.g., `Analytics` and `Chat`) talk through the `Ads` context only. This prevents the chat code from growing direct dependencies on sync internals.

## 4. Sync pipeline (Broadway + RabbitMQ + Meta)

### Why RabbitMQ here (and not Oban alone)

Broadway excels at back-pressured, partitioned consumption of a stream where order-per-partition matters. Meta Insights sync fits: we want one "lane" per ad account so rate-limit usage is isolated, we want tunable concurrency, and we want to pipe in millions of low-value events (per-ad-per-day insights rows) without touching Postgres for every one.

Oban is better for discrete business jobs: "run the Creative Fatigue job for account X at 03:00" or "send this digest email." Use it for Analytics, not for Sync.

### Topology

```
  Sync.Scheduler (GenServer, 1 per node) 
        │
        │  enqueues `{ad_account_id, entity, since, until}` tasks
        ▼
  RabbitMQ exchange: adflux.sync  (topic)
        │
        ├── queue: sync.insights.hourly    ──► Broadway: InsightsSyncPipeline
        ├── queue: sync.objects.metadata   ──► Broadway: MetadataSyncPipeline
        └── queue: sync.insights.backfill  ──► Broadway: BackfillPipeline (lower concurrency)
```

Each Broadway pipeline:

- Partitions messages by `ad_account_id` so one account's work is sequential (avoids self-inflicted rate-limit contention).
- Sets `concurrency` on the processor stage based on tier (Standard vs Advanced).
- Uses `Broadway.Batcher` to group Postgres upserts into batches of 500–2,000 rows per transaction.
- Emits telemetry events the Sync.Observer consumes to record per-account API usage.

### Meta API client design

Three things the client must do that a naive HTTP wrapper wouldn't:

- **Rate-limit ledger.** Every response from Meta returns `X-Business-Use-Case-Usage` with `call_count`, `total_cputime`, `total_time` as a percentage. Parse it on every response and store the latest per-account snapshot in ETS (keyed by `ad_account_id`). A pre-flight check in the producer refuses to dequeue work for an account whose usage is >85%, deferring it by a backoff interval.
- **Batch calls.** `POST /` with a `batch=[...]` parameter lets us pack ~50 Insight requests into one HTTP round trip — huge at 1k accounts. The client should expose `batch/2` as a primitive, and callers should opt in when they know they're reading many objects.
- **Async insights jobs.** For anything older than ~7 days or with heavy breakdowns (placement × age × gender), submit an async job (`POST /{ad_account}/insights` with a flag), poll the job status, then fetch the report. Don't use this for the hot path — only the backfill pipeline.

### Polling schedule (the hot question)

For 1,000 ad accounts with an average of ~50 active ads each:

- **Delivery metrics** (spend, impressions, CTR, frequency): pull every 30 minutes, last-2-day window. Batched call at the ad level, one batch per account, ~20 calls per account per hour. At 1k accounts = 20k calls/hour — well within Advanced Access limits but would blow Standard.
- **Conversion metrics**: pull every 2 hours for the last 7 days (attribution windows cause backfill revisions). One async job per account, run off-peak.
- **Ad object metadata** (name, creative, status, budget): pull every 4 hours; diff against local cache; only upsert changes.

The scheduler should use jittered timestamps (e.g., the `ad_account_id` hash modulo 1800 seconds as an offset into each half-hour window) so 1k accounts aren't all firing at second 0.

## 5. Postgres data model

Three data layers with different shapes:

### 5.1 Operational (normalized, Ecto-managed)

```
users
  id, email, hashed_password, inserted_at, updated_at

meta_connections
  id, user_id, meta_user_id, access_token (encrypted), 
  token_expires_at, scopes[], inserted_at

ad_accounts
  id, meta_connection_id, meta_id (e.g., "act_123"), 
  name, currency, timezone, status, last_synced_at

campaigns / ad_sets / ads / creatives
  id, ad_account_id, meta_id, name, status, 
  objective, budget_cents, start_date, end_date, 
  last_synced_at, raw_jsonb (full Meta payload for forensics)
```

Keep the raw Meta payload as JSONB on each row. Cheap storage, saves us on future debugging, and lets new analytics pull fields we didn't normalize up front.

### 5.2 Time-series warehouse (partitioned Postgres)

```
insights_daily  -- partitioned by date_start, weekly partitions
  ad_id, date_start, spend_cents, impressions, clicks,
  reach, frequency, conversions, conversion_value_cents,
  ctr_numeric, cpm_cents, cpc_cents, cpa_cents,
  by_placement JSONB,   -- one-level breakdowns
  by_age_gender JSONB
  -- index: (ad_id, date_start) propagated across partitions

insights_hourly  -- optional, from hourly_stats_aggregated_by_advertiser_time_zone
  ad_id, hour_start, spend_cents, impressions, clicks
  -- partitioned by date_trunc('week', hour_start)
```

Native Postgres declarative partitioning — no TimescaleDB extension. A `PartitionManager` Oban job creates next week's partition on Sunday and detaches partitions older than the 13-month retention cutoff. Rolling-window aggregates (7-day CTR, 30-day CPA baseline) are computed via **materialized views** refreshed every 15 minutes for 7-day windows, hourly for 30-day windows. Queries needing fresher numbers aggregate at query time over the hot partition only. See `decisions/0002-partitioned-postgres.md` for the full rationale and revisit triggers.

### 5.3 Derived (analytics outputs)

```
ad_health_scores
  ad_id, computed_at, 
  leak_score NUMERIC(5,2),        -- 0–100, high = more waste
  fatigue_score NUMERIC(5,2),     -- 0–100, high = more fatigued
  leak_factors JSONB,             -- which heuristics fired, with values
  fatigue_factors JSONB,
  recommended_action TEXT         -- "pause" | "refresh_creative" | "ok" | ...

findings
  id, ad_id, kind, severity (low/med/high),
  title, body, evidence JSONB,
  acknowledged_at, acknowledged_by_user_id,
  resolved_at, resolution TEXT,
  inserted_at
```

`findings` is the inbox the user sees ("3 ads are leaking spend"). Keep them append-only; "resolve" is a column, not a delete. The chatbot cites finding IDs in its responses, which lets the UI render clickable references.

### 5.4 Vector store (pgvector)

```
embeddings
  id, kind ('ad' | 'finding' | 'doc_chunk'), 
  ref_id uuid, embedding vector(1536),
  content_excerpt text, metadata JSONB
```

We embed: ad creative text + name, every finding, and the handful of "help docs" the chatbot can cite. For solo-media-buyer scale, pgvector on the same Postgres is perfect. If we ever outgrow it, swap to Qdrant without touching the rest of the system.

## 6. Analytics: the two signature features

Both run as Oban jobs scheduled by account. Each job reads the time-series warehouse, writes to `ad_health_scores` and `findings`.

### 6.1 Budget Leak Auditor

Starts as a rules engine, not ML. MVP heuristics, each contributing weighted points to a leak score:

- **Dead spend** — spend > $X in last 48h with zero attributed conversions and no uplift in reach. Weight: high.
- **CPA explosion** — rolling-3-day CPA > 2.5× the 30-day baseline for the same ad set. Weight: high.
- **Bot-shaped traffic** — CTR > 5% with conversion_rate < 0.3% on a lower-intent placement (Audience Network, reels). Weight: medium.
- **Placement drag** — same ad set, CPA on placement A > 3× placement B. Weight: medium.
- **Stalled learning** — ad set stuck in learning phase > 7 days with < 50 results. Weight: low.

Expose each contributing signal as a named heuristic so the UI can say "this ad triggered 2 of 5 leak signals." The chatbot reads `leak_factors` JSON and explains them.

### 6.2 Creative Fatigue Predictor

Start heuristic, evolve to predictive once there's data.

**Heuristic (v0.1):**

- Frequency > 3.5 + 7-day CTR slope < −0.1 percentage points/day → fatigue signal.
- Meta `quality_ranking` drop from "above_average" → "average" or worse → fatigue signal.
- 7-day CPM up > 20% on the same audience → saturation signal.

**Predictive (v0.3+):**

Per-ad, fit a simple regression on the last 14 days of daily CTR/CPM with frequency and cumulative reach as features. Project CTR forward 3 days. If the projected CTR drops below 60% of the ad's honeymoon-window baseline, emit a fatigue finding tagged "predicted" with the forecast window.

Keep the model boring and re-fit per ad nightly. ML glamour is a trap here; solo buyers want a number they can defend to their clients.

## 7. Chat pipeline with Jido

This is the interesting part stack-wise. Jido's model is a strong fit because its Actions double as LLM tools without a separate adapter layer.

### 7.1 Agent design

One long-running `Jido.AgentServer` process per active chat session, supervised under a `DynamicSupervisor`. Agent state is `{user_id, ad_account_id, conversation_id, turn_history}`. On LiveView mount, either attach to the existing agent for `conversation_id` or start a new one.

Conversations persist to Postgres. Jido doesn't auto-persist — we own the durability. On app restart, we don't restore agent processes eagerly; we lazy-start them on the next user message and replay the last N turns into the agent's state.

### 7.2 Tools (Jido Actions)

**Read tools** (safe, no confirmation required):

- `GetAdHealth(ad_id)` — returns the leak + fatigue scores with factors.
- `GetFindings(severity_filter, limit)` — returns recent findings.
- `CompareCreatives(ad_ids | creative_format, window)` — aggregates insights for the "Compare mode."
- `GetInsightsSeries(ad_id, metric, window, breakdown?)` — returns a time series suitable for chart rendering.
- `SimulateBudgetChange(ad_set_id, new_budget_cents)` — the "what-if" tool. Returns projected reach/frequency impact plus saturation warnings. Read-only — no writes to Meta.

**Write tools** (require user confirmation):

- `PauseAd(ad_id, reason)` — calls `POST /{ad_id}` with `status=PAUSED`. Returns success + new ad state.
- `UnpauseAd(ad_id)` — symmetric.
- `RenameAd(ad_id, new_name)` — cheap and useful in some flows.

Write tools should never execute silently. The pattern:

1. LLM decides to call `PauseAd(ad_123)`.
2. Jido Action's `run/2` checks `context[:confirmation_token]`; if absent, returns `{:error, :confirmation_required}` with a structured confirmation payload.
3. LiveView catches the error, renders a `[Pause ad_123 now]` button in the chat.
4. User clicks → LiveView re-invokes the agent with a confirmation token bound to that specific tool call.
5. Agent retries the tool, which now executes.

This keeps the "direct action" killer feature safe. No matter how clever the prompt injection, no write happens without a click.

### 7.3 Retrieval (RAG)

Two retrieval modes stacked:

- **Structured retrieval first.** Before calling the LLM, the agent detects entities in the user's question (ad names, date ranges, metrics) using a small cheap model or regex, then calls read tools to fetch relevant rows into the prompt. This is more reliable than pure semantic search for a "which ad?" question.
- **Vector retrieval second.** For open-ended questions ("what should I focus on this week?"), semantic-search the `embeddings` table for top-K recent findings and ad-health records. Include the matches in the system prompt.

Keep `top_k` small (5–10). A padded prompt doesn't help the LLM and burns tokens.

### 7.4 Streaming and charts

ReqLLM (under jido_ai) streams chunks as structured `StreamChunk`s. LiveView pushes them to the client via a dedicated `chat_stream` topic. When the LLM's response contains a structured `render_chart` directive (we define the schema), the chat component fetches the series via `GetInsightsSeries` and renders a server-generated SVG via Contex. See `decisions/0004-server-rendered-charts.md` — interactive (JS-side) charts are a deferred swap, not a v0.3 commitment.

Default chat model: Claude Sonnet (complex multi-tool turns) with Claude Haiku for cheaper paths; model choice is a config flag via jido_ai/ReqLLM. See `decisions/0003-claude-via-reqllm.md`.

## 8. Deployment shape

- Single umbrella app or a flat Phoenix app; umbrella only if the team grows past ~3 devs.
- Two node types early on: `web` (LiveView + API) and `worker` (Broadway + Oban). They share the same codebase and use Phoenix.PubSub over distributed Erlang or Redis for cross-node coordination.
- RabbitMQ: CloudAMQP managed cluster, or a self-hosted RabbitMQ container alongside Postgres on the VPS for MVP. Start on the smallest tier; the queues are narrow and bursty.
- Postgres: **self-hosted Postgres in a Docker container on a VPS** for MVP. Must have pgvector (vanilla `pgvector/pgvector` image works). Persistent named volume, *not* the container's writable layer. Automated `pg_dump` to object storage on a daily cron, plus a recovery runbook that's actually been rehearsed once.
- Secrets: Meta access tokens must be encrypted at rest (Cloak.Ecto `:binary` column with app-level key from env / Vault / 1Password). Never log tokens.
- Observability: Telemetry → OpenTelemetry exporter → Honeycomb or Grafana Cloud. Every Broadway stage, every Oban job, every Jido tool call gets a span.

## 9. Security posture for MVP

- **Meta OAuth only for login.** Don't build a password system. Scopes: `ads_management`, `ads_read`, `email`, `public_profile`.
- **Token rotation**: Meta's user access tokens are ~60-day lived. Refresh proactively at 50 days. Store `token_expires_at` and background-job any that are expiring.
- **Per-request scoping**: every Ecto query in `Ads` goes through a helper that scopes to `current_user.id → meta_connection → ad_account`. Tenant isolation is enforced at the query layer, not checked ad-hoc. Postgres RLS is intentionally **not** used in MVP — see `decisions/0001-skip-rls-for-mvp.md` for the rationale and the five triggers that would cause us to revisit.
- **LLM prompt injection**: treat ad names, creative text, and any user-generated content embedded in the prompt as untrusted. Never let the LLM auto-confirm write tools (see 7.2 above). Don't give read-only tools access to cross-tenant data — scope them to the session's `ad_account_id`.
- **Audit log**: every write tool call (pause/unpause) gets a row in `actions_log` with the user, tool, arguments, outcome, and the LLM turn that suggested it. This is both a compliance hedge and a debugging godsend.

## 10. Decisions locked + remaining questions

Locked decisions (see `decisions/` folder for full rationale):

- **D0001** — Skip Postgres RLS; enforce isolation at the Ecto query layer.
- **D0002** — Use partitioned Postgres (no Timescale) for the insights warehouse.
- **D0003** — Claude (via jido_ai / ReqLLM) as the default chat LLM; OpenAI embeddings.
- **D0004** — Server-rendered charts via Contex for MVP.

Still open:

- **How much structured output to lean on.** jido_ai + Instructor makes the LLM return typed Ecto-like structs. Great for rendering charts and tool arguments, but constrains the model. Default: structured output for anything that hits the UI (numbers, chart series); free-form for the prose portion of chat responses.
- **"Solo media buyer" onboarding shape** — we're running a multi-tenant Meta app with our own App Review (already in motion — Track 1). Confirm that no tenant will need to bring their own app credentials.
- **Interview a second media buyer before v0.2 ships.** Founder has 150+ live campaigns (strong primary source), but heuristic weights tuned only on one person's campaigns will ossify around that person's habits. One 30-min interview is cheap insurance.
