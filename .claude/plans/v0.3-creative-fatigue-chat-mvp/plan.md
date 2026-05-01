# Plan: v0.3 — Creative Fatigue Predictor + Chat MVP

**Window**: Weeks 7–11 (5 calendar weeks, ~25 working days)
**Scope source**: `docs/plan/decisions/02-roadmap.md` §v0.3, plus D0001–D0005

## Goal

Both analyzers are live (Budget Leak Auditor from v0.2 + new Creative Fatigue Predictor). Users can chat with their data via a Jido + ReqLLM agent over read tools, and trigger `PauseAd` / `UnpauseAd` writes with explicit confirmation. Per-user token quotas prevent runaway spend. This is the first phase that feels like the product in your head.

---

## What Exists (v0.2 baseline)

| Already built | Path |
|---|---|
| Schemas: users, meta_connections, ad_accounts, campaigns, ad_sets, ads, creatives | [priv/repo/migrations](priv/repo/migrations) |
| `insights_daily` partitioned table + 7d/30d materialized views | [20260426100001_create_insights_daily.exs](priv/repo/migrations/20260426100001_create_insights_daily.exs) |
| `ad_health_scores` with `fatigue_score` + `fatigue_factors` columns (already provisioned) | [20260427000001_create_ad_health_scores.exs](priv/repo/migrations/20260427000001_create_ad_health_scores.exs) |
| `findings` with `(ad_id, kind)` partial unique index when unresolved | [20260427000002_create_findings.exs](priv/repo/migrations/20260427000002_create_findings.exs) |
| `llm_usage`, `llm_pricing`, `user_quotas` tables | [20260420155226–155228](priv/repo/migrations) |
| Sync pipelines (Broadway): MetadataPipeline, InsightsPipeline (delivery + conversions) | [lib/ad_butler/sync](lib/ad_butler/sync) |
| `BudgetLeakAuditorWorker` with 5 heuristics + dedup | [lib/ad_butler/workers/budget_leak_auditor_worker.ex](lib/ad_butler/workers/budget_leak_auditor_worker.ex) |
| `Analytics` context with `scope/2`, dedup helpers | [lib/ad_butler/analytics.ex](lib/ad_butler/analytics.ex) |
| `LLM.UsageHandler` telemetry handler (listens to `[:llm, :request, :stop]`) | [lib/ad_butler/llm/usage_handler.ex](lib/ad_butler/llm/usage_handler.ex) |
| FindingsLive inbox + drill-down with ack/resolve | [lib/ad_butler_web/live/findings_live.ex](lib/ad_butler_web/live/findings_live.ex) |
| Tenant scoping discipline + 42 test files + Mox + factory | [test/](test/) |

| NOT built (v0.3 surface) |
|---|
| `Analytics.CreativeFatiguePredictor` worker + heuristic + regression layer |
| `Chat` context: `chat_sessions`, `chat_messages`, `pending_confirmations` schemas |
| `embeddings` schema (pgvector) + HNSW index |
| `actions_log` schema |
| `Billing` context: quota pre-flight + circuit breaker GenServer |
| Jido / jido_ai / req_llm / pgvector / contex deps |
| Bridge from ReqLLM telemetry (`[:req_llm, :token_usage]`) to existing `LLM.UsageHandler` |
| Read tools: `GetAdHealth`, `GetFindings`, `GetInsightsSeries`, `CompareCreatives`, `SimulateBudgetChange` |
| Write tools: `PauseAd`, `UnpauseAd` (confirmation-gated) |
| `ChatLive.Index` + `ChatLive.Show` + chart component |
| 20-question eval harness |

---

## Architecture Decisions (locked for v0.3)

Inheriting D0001 (no RLS), D0002 (partitioned PG), D0003 (Claude default), D0004 (Contex SVG), D0005 (findings dedup). New decisions for v0.3:

- **D0006**: Pin `jido ~> 2.2`, `jido_ai ~> 2.1`, `req_llm ~> 1.10`, `pgvector ~> 0.3.1`, `contex ~> 0.5.0`. ReqLLM covers OpenAI embeddings — no separate `:openai` package.
- **D0007**: Per-conversation Jido AgentServer under a project-owned `Chat.SessionSupervisor` (DynamicSupervisor) + `Chat.SessionRegistry`. Lazy-start on next user message; replay last 20 turns from Postgres on init. **Agent state is ephemeral** — durability lives in `chat_messages`.
- **D0008**: Confirmation tokens persist to `pending_confirmations` table (not LiveView process state) so reconnects survive. Token = single-use, 5-min TTL, scoped to `user_id` + `chat_message_id`.
- **D0009**: Bridge ReqLLM telemetry (`[:req_llm, :token_usage]`) into existing `LLM.UsageHandler` rather than create a parallel handler. Keeps one ledger, one schema. Wrap the bridge in `AdButler.Chat.Telemetry` so a future ReqLLM rename touches one file.
- **D0010**: Cap agent loops at **6 tool calls per turn** (per `03-token-monitoring.md` §6). Enforced in `Chat.Agent` signal handler — exceeding the cap injects an error message and ends the turn.
- **D0011**: Use HNSW (`vector_cosine_ops`, `m=16, ef_construction=64`) on `embeddings.embedding`. Suitable up to ~1M rows; revisit for IVFFlat at >1M.
- **D0012**: Stream-chunk coalescing happens **in the agent**, not the LiveView (min 50ms / 10 chars per broadcast). LiveView never throttles.

---

## Breadboard

```
Sidebar nav
├── Findings (existing)
└── Chat (NEW)  →  /chat (Index)  →  /chat/:conversation_id (Show)

Data flow — Creative Fatigue:
  AuditSchedulerWorker (existing v0.2)
    enqueues both BudgetLeakAuditorWorker + CreativeFatiguePredictorWorker per ad_account
       │
       ▼
  CreativeFatiguePredictorWorker (Oban, NEW)
    reads ad_insights_7d + ad_insights_30d + ads.raw_jsonb (quality_ranking)
    runs heuristic + regression layers
    writes ad_health_scores (fatigue_score, fatigue_factors) + findings of kind :creative_fatigue
       │
       ▼
  EmbeddingsRefreshWorker (Oban cron, hourly NEW)
    diffs ads + findings since last embed; calls ReqLLM.embed (text-embedding-3-small)
    upserts embeddings rows (only if hash changed)

Data flow — Chat:
  ChatLive.Show (LiveView)
    on user message:
      Chat.send_message(scope, conversation_id, body)
        ├─ pre-flight Billing.check_quota(user_id) → maybe :quota_exceeded
        ├─ ensure AgentServer started under SessionSupervisor (lazy)
        └─ cast {:user_message, body, request_id} to AgentServer
             ↓
  Chat.Agent (Jido.Agent in AgentServer, 1 per session)
    ReAct loop (max 6 tool calls):
      ├─ Jido.AI.stream_text via ReqLLM
      ├─ broadcasts {:stream_chunk, %{delta: ...}} on "chat_stream:#{cid}"
      ├─ if tool_call:
      │    ├─ scope-check via session_context.{user_id, ad_account_id}
      │    ├─ read tools: execute, return result
      │    └─ write tools: insert pending_confirmations row + return :confirmation_required
      └─ on completion: persist ChatMessage + broadcast {:turn_complete, msg}

  ReqLLM telemetry [:req_llm, :token_usage]
    → Chat.Telemetry.handle_event/4
    → Billing.record_usage(...)  (writes llm_usage row, broadcasts user usage update)
    → Billing.CircuitBreaker.observe(user_id, cost_cents)  (open if 5min spend > $1)

Confirmation flow:
  User clicks <.confirmation_button token="xyz">
    → handle_event "confirm_tool" in ChatLive
    → Chat.confirm_tool_call(scope, conversation_id, token)
       ├─ load pending_confirmations row by token (single-use, TTL check)
       ├─ delete row + insert actions_log row (pending)
       └─ cast {:confirmed_tool_call, payload} to AgentServer
            → re-runs PauseAd action with confirmation_token in context
            → on success, updates actions_log + broadcasts {:turn_complete}
```

---

## Pre-flight (Week 7 Day 1, before any feature work)

- [x] [P0-T1] Add deps to [mix.exs](mix.exs) — jido 2.2, jido_ai 2.1, req_llm 1.10, pgvector 0.3.1, contex 0.5.0; deps.get clean; req stays at ~> 0.5
- [x] [P0-T2] Wire ReqLLM keys — prod uses `System.fetch_env!` into `:req_llm` app env; dev/test fall back to .env or Mox. Added ANTHROPIC_API_KEY + OPENAI_API_KEY to .env.example
- [x] [P0-T3] Configure `:llm_models` in config/config.exs (chat_default sonnet-4-6, chat_cheap haiku-4-5, embedding text-embedding-3-small)
- [x] [P0-T4] Set `:req_llm, finch: [pools: %{default: [protocols: [:http1], ...]}]` explicitly in config/config.exs (ReqLLM default but pinned for safety per plan Self-Check)
- [x] [P0-T5] Compile passes warnings-as-errors; `mix run` boots all deps clean; live `ReqLLM.embed` request reaches OpenAI and rejects with 401 on dummy key (proves provider dispatch + HTTP/1 wiring). Real-key smoke deferred to W8 once OPENAI_API_KEY lands in .env.local.

---

## Tasks

### Week 7 — Creative Fatigue: Heuristic Layer

#### Day 1 — Pre-flight + Worker Skeleton

- [x] [W7D1-T1] **P0 pre-flight tasks above** — deps, env, config, smoke test.
- [x] [W7D1-T2][oban] Scaffold worker — `:fatigue_audit` queue, unique [period: 21_600, fields: [:args, :queue, :worker], keys: [:ad_account_id]], 10-min timeout. Heuristic stubs filled later. `weights/0` exposed for renderer (W7D5-T2).
- [x] [W7D1-T3][oban] Scheduler enqueues both workers per active ad_account; `fatigue_enabled: true` default with kill-switch `Application.get_env(:ad_butler, :fatigue_enabled)`.
- [x] [W7D1-T4] Tests pass (11/11): scheduler enqueues both, kill-switch path enqueues only leak, fatigue idempotent on missing account, Oban unique per ad_account_id, scaffold writes nothing for foreign account.

#### Day 2 — Heuristic 1: Frequency + CTR Decay

- [x] [W7D2-T1][ecto] `Analytics.compute_ctr_slope/2` — closed-form OLS on daily clicks/impressions; rounds slope to 4 dp pp/day; returns 0.0 with <2 days
- [x] [W7D2-T2][ecto] `Analytics.get_7d_frequency/1` — queries insights_daily directly (matview lacks frequency); skips nil/0 rows; returns float or nil
- [x] [W7D2-T3][oban] `heuristic_frequency_ctr_decay/1` public on worker — thresholds `@frequency_threshold 3.5` / `@ctr_slope_threshold -0.1`; returns `{:emit, %{frequency, ctr_slope}}` | `:skip`
- [x] [W7D2-T4] Tests: 41 pass — slope on declining/stable/insufficient/empty + frequency avg/nil-skip/window-bound + heuristic 4 cases

#### Day 3 — Heuristic 2: Quality Ranking Drop

- [x] [W7D3-T1][ecto] Migration `20260430000001_add_quality_ranking_history_to_ads` adds JSONB column with default `%{"snapshots" => []}`. Schema cast accepts it as optional. `Ads.unsafe_get_quality_ranking_history/1` reads back the snapshots list.
- [x] [W7D3-T2][ecto] MetadataPipeline now requests ranking fields; after `bulk_upsert_ads` calls `Ads.append_quality_ranking_snapshots/2` which read-modify-writes (cap 14, drops snapshots whose 3 ranking fields are all nil). Append happens outside the upsert because Postgres ON CONFLICT can't atomically tail an array — this trade documented in the helper's doc.
- [x] [W7D3-T3][oban] `heuristic_quality_drop/1` public; ordered ranking enum (above_average=3, average=2, below_average_*=1, unknown=nil); 7-day cutoff; emits `{:emit, %{from, to, from_date}}` when latest tier is worse than any earlier in-window snapshot.
- [x] [W7D3-T4] Tests: 3 pass (drop, stable, no history). Metadata pipeline tests still green (18/18).

#### Day 4 — Heuristic 3: CPM Saturation

- [x] [W7D4-T1][ecto] `Analytics.get_cpm_change_pct/2` reads insights_daily for prior 7d (8-14d ago) and recent 7d (0-6d), CPM = sum_spend*1000/sum_imps; nil when either window has zero spend or zero impressions
- [x] [W7D4-T2][oban] `heuristic_cpm_saturation/1` public; threshold `@cpm_change_threshold_pct 20.0`; returns `{:emit, %{cpm_change_pct: float}}` | `:skip`
- [x] [W7D4-T3][oban] `audit_account/1` enumerates ad_ids → runs 3 heuristics → sums weights → writes via `Analytics.bulk_insert_fatigue_scores/1`. Migration 20260430000002 makes leak_score nullable so workers don't clobber each other; AdHealthScore changeset accepts both as optional
- [x] [W7D4-T4][oban] `:creative_fatigue` added to Finding `@valid_kinds`; severity buckets 50-69 medium / 70+ high; body lists triggered heuristics; evidence is full factors map; `(ad_id, kind)` dedup via `Analytics.unsafe_list_open_finding_keys/1` matches BudgetLeakAuditor

#### Day 5 — Wire to FindingsLive + Verify

- [x] [W7D5-T1][liveview] FindingsLive: `creative_fatigue` added to `@valid_kinds` and the kind dropdown; `kind_label/1` extended in FindingHelpers.
- [x] [W7D5-T2][liveview] FindingDetailLive renders fatigue_score bar + per-signal value lines; helpers `format_fatigue_values/2` for frequency+CTR decay, quality drop, CPM saturation; works alongside leak score (both columns now nullable).
- [x] [W7D5-T3] End-to-end tests in worker_test: 3-signal ad hits score 90 with `severity: "high"` finding; second run dedups via `(ad_id, kind)`. LiveView tests confirm filter + detail page render.
- [x] [W7D5-T4] precommit pieces pass — compile warnings-as-errors, format, deps.unlock, full test suite (392/392), credo --strict clean for new code (`mix precommit` itself fails on missing `hex.audit` task — pre-existing per scratchpad note). Iron-law `check.unsafe_callers` passes.

---

### Week 8 — Predictive Fatigue + Embeddings Plumbing

#### Day 1 — Predictive Regression Skeleton

- [x] [W8D1-T1][ecto] `Analytics.get_ad_honeymoon_baseline/1` — added migration `20260501000001_add_metadata_to_ad_health_scores.exs` (ad_health_scores.metadata JSONB column was not yet provisioned); function is read-only (cache→compute), worker is responsible for persisting via existing `bulk_insert_fatigue_scores/1` (now also replaces `:metadata` on conflict). 6 tests.
- [x] [W8D1-T2][ecto] `Analytics.fit_ctr_regression/1` — model is CTR ~ β₀ + β_day·d + β_freq·f + β_reach·cumreach (cumulative_reach computed as running sum of reach_count within the 14-day window since insights_daily has no native column). 4×5 augmented matrix solved via Gauss-Jordan with partial pivoting. Singular features → `:insufficient_data` (collinearity twin of "no signal"). projected_ctr_3d extrapolates frequency + cumulative_reach via per-feature OLS slopes — keeps the prediction internally consistent.
- [x] [W8D1-T3] 5 tests: declining (r²>0.99, projected within 0.005 of true), stable (r²==0.0, slope≈0), noisy (r²<0.5), insufficient (<10 days), zero-impression rows skipped from row count.

#### Day 2 — Predictive Findings + Nightly Fit

- [x] [W8D2-T1][oban] `heuristic_predicted_fatigue/1` added; weight 25 in @weights; gates `r² >= 0.5` AND `projected_ctr_3d < 0.6 × baseline_ctr`. Below the 50 finding threshold standalone — designed to amplify a present-tense heuristic rather than fire alone.
- [x] [W8D2-T2][oban] `build_evidence/1` lifts `predicted: true` and `forecast_window_end` to top-level evidence when the predictive signal contributed; `render_finding_title/1` prefixes "Predicted fatigue:". Body renderer adds a forecast clause.
- [x] [W8D2-T3] `FatigueNightlyRefitWorker` at `0 3 * * *` cron, queue `:audit`, respects `:fatigue_enabled` kill-switch, dedups via Oban unique within 1h window, only enqueues `CreativeFatiguePredictorWorker` (heuristics' 6h cycle is independent).
- [x] [W8D2-T4] 7 tests (5 heuristic + 2 integration): fires/silent on r², drop threshold, baseline insufficiency, regression insufficiency. Integration test asserts `evidence.predicted == true` + forecast date + "Predicted fatigue" title prefix; second test confirms predictive alone (score 25) does not create finding.

#### Day 3 — Add Deps + ReqLLM Smoke + Embeddings Schema

- [x] [W8D3-T1][ecto] Migration `20260501000002_create_embeddings.exs` provisions extension + table together (vector(1536) requires the extension to exist before column creation). Kind CHECK constraint added separately via raw SQL since Ecto migrations don't have a built-in helper. Required `brew install pgvector` on local Postgres@17 — recorded the install step in scratchpad. Postgrex types module `AdButler.PostgrexTypes` registered in `lib/ad_butler/postgrex_types.ex` with `Pgvector.extensions()` and wired via `config :ad_butler, AdButler.Repo, types: ...`.
- [x] [W8D3-T2][ecto] Migration `20260501000003_add_embeddings_hnsw_index.exs` — `CREATE INDEX CONCURRENTLY` with `@disable_ddl_transaction true`. m=16, ef_construction=64 per D0011.
- [x] [W8D3-T3][ecto] `AdButler.Embeddings.Embedding` schema with `Pgvector.Ecto.Vector` field type, kind validation, content_hash 64-char check, unique_constraint. `AdButler.Embeddings` context: `hash_content/1` (SHA-256 hex), `upsert/1` (replaces embedding + hash + excerpt + metadata + updated_at on (kind, ref_id) conflict, `returning: true` so the existing row's id roundtrips on UPDATE), `nearest/3` (cosine distance via `<=>` fragment), `list_ref_id_hashes/1` (for refresh worker diffing). 12 tests.
- [x] [W8D3-T4][ecto] `Embeddings.ServiceBehaviour` with single batched `embed/1` callback. Real impl `Embeddings.Service` reads `:embeddings_model` config (default `"openai:text-embedding-3-small"`) and delegates to `ReqLLM.embed/2`. Mox: `Embeddings.ServiceMock` defined in `test/support/mocks.ex`, wired in `config/test.exs`.

#### Day 4 — Embeddings Backfill Worker

- [x] [W8D4-T1][oban] `EmbeddingsRefreshWorker` cron `*/30 * * * *`, queue `:embeddings` (concurrency 3 added to Oban queues). Processes `"ad"` and `"finding"` kinds in sequence per tick; batch_size 100. Renamed callback from `embed_text/1` to `embed/1` (single batched callback — splitting would duplicate provider call).
- [x] [W8D4-T2][oban] `Embeddings.hash_content/1` is the SHA-256 → 64-char lowercase hex helper. Worker computes hash on `"#{ad.name} | #{creative.name}"` (creative.name not body — body lives in jsonb and isn't readily projected). For findings: `"#{title}\\n\\n#{body}"`. Worker compares against `Embeddings.list_ref_id_hashes/1` and skips unchanged rows. Service.embed/1 isn't called when no candidates remain.
- [x] [W8D4-T3] 13 help docs in [priv/embeddings/help/](priv/embeddings/help/) covering CTR, findings, fatigue, budget leak, CPA, frequency, quality ranking, learning phase, conversions, severity, acknowledge/resolve, CPM, honeymoon. Mix task `mix ad_butler.seed_help_docs` reads each .md, computes hash, calls `Embeddings.Service.embed/1` with the list, and upserts under `kind: "doc_chunk"`. `ref_id` is deterministic (`SHA-256("doc_chunk:" <> filename) → first 16 bytes → UUID`) so reruns upsert the same row.
- [x] [W8D4-T4] 6 worker tests: clean-DB backfill (1 ad + 1 finding, 2 service.embed calls), idempotent second run (zero service calls when hashes match), only-changed re-embed (ad1 mutated, ad2 unchanged → exactly one text in the embed batch), rate_limit error preserves stale hash for retry, vector-count mismatch returns `:vector_count_mismatch`, Oban unique within 25 min.

#### Day 5 — Verify Fatigue + Embeddings, Pre-Chat Catch-up

- [x] [W8D5-T1] [test/ad_butler/integration/week8_e2e_smoke_test.exs](test/ad_butler/integration/week8_e2e_smoke_test.exs) — declining 14-day ad → CreativeFatiguePredictorWorker.perform → predicted_fatigue + frequency_ctr_decay both fire (score 60) → finding with `evidence.predicted == true` + iso8601 `forecast_window_end`. Then EmbeddingsRefreshWorker.perform → ad embedding + finding embedding rows confirmed.
- [x] [W8D5-T2] All precommit pieces green: compile (warnings-as-errors), deps.unlock --unused (no unused), format, check.unsafe_callers, full mix test (438/438 passing), mix credo --strict (clean across 141 source files). `mix precommit` itself fails at `hex.audit` (pre-existing missing task). PR creation deferred — see HANDOFF.
- [ ] [W8D5-T3] **Spike day deferred** — exploratory iex session, see [scratchpad.md](.claude/plans/v0.3-creative-fatigue-chat-mvp/scratchpad.md) HANDOFF for next steps. Throwaway code with no persistence is best done by the developer interactively.

---

### Week 9 — Chat Foundation + Read Tools

#### Day 1 — Chat Schemas + Context

- [ ] [W9D1-T1][ecto] Migration: `chat_sessions` (id uuid pk, user_id fk, ad_account_id fk nullable, title text, status text default 'active', last_activity_at timestamptz, inserted_at, updated_at). Index `(user_id, last_activity_at desc)`.
- [ ] [W9D1-T2][ecto] Migration: `chat_messages` (id uuid pk, chat_session_id fk on delete cascade, role text check `'user'|'assistant'|'tool'|'system_error'`, content text, tool_calls jsonb default '[]', tool_results jsonb default '[]', request_id text, status text default 'complete' check `'streaming'|'complete'|'error'`, inserted_at). Index `(chat_session_id, inserted_at)`.
- [ ] [W9D1-T3][ecto] Migration: `pending_confirmations` (id uuid pk, chat_message_id fk, user_id fk, token text unique, action text, args jsonb, expires_at timestamptz, consumed_at timestamptz nullable, inserted_at). Index `(token)`, `(expires_at)` for sweep, partial unique `(chat_message_id) WHERE consumed_at IS NULL`.
- [ ] [W9D1-T4][ecto] Migration: `actions_log` (id bigserial, user_id fk, chat_session_id fk nullable, chat_message_id fk nullable, tool text, args jsonb, outcome text check `'pending'|'success'|'failure'`, error_detail text nullable, meta_response jsonb, inserted_at). Index `(user_id, inserted_at desc)`.
- [ ] [W9D1-T5][ecto] `AdButler.Chat` context with `scope/2` (joins chat_sessions to user_id), `list_sessions/2 (paginated)`, `get_session!/2`, `create_session/2`, `list_messages/3 (paginated)`, `append_message/2`, `record_action_log/1`. Schemas live in `lib/ad_butler/chat/{session,message,pending_confirmation,action_log}.ex`. Per CLAUDE.md, schemas live inside the context that owns them.

#### Day 2 — Jido Agent Plumbing

- [ ] [W9D2-T1] `AdButler.Chat.SessionRegistry` (Registry, started in Application) — `{:via, Registry, {SessionRegistry, session_id}}` for AgentServer naming.
- [ ] [W9D2-T2] `AdButler.Chat.SessionSupervisor` (DynamicSupervisor, started in Application). Owns AgentServer children.
- [ ] [W9D2-T3] `AdButler.Chat.Agent` (`use Jido.Agent`) — agent module that owns the ReAct loop. Initial state: `%{session_id, user_id, ad_account_id, history: [...last 20 turns]}`. Load history from `Chat.list_messages/3` on init.
- [ ] [W9D2-T4] `AdButler.Chat.Server` — thin GenServer wrapping `Jido.AgentServer.start_link` so we control lifecycle, telemetry, and `max_steps` enforcement (D0010). Public API: `send_user_message/2`, `confirm_tool_call/2`. Lazy-start in `Chat.send_message/3` if no process is registered.
- [ ] [W9D2-T5] Tests: spawn a session, send a no-op message (mock LLM via Mox), assert message persists + history loads on restart.

#### Day 3 — Read Tools: Ad Health + Findings

- [ ] [W9D3-T1] `AdButler.Chat.Tools.GetAdHealth` (`use Jido.Action`, name: `"get_ad_health"`). Schema: `ad_id` (string, required). Run: re-scope via `context[:session_context]` → `Ads.scope/2`; if the ad is not in the user's account, return `{:error, :not_found}` (LLM hallucinates an ad_id from another tenant, we deny silently).
- [ ] [W9D3-T2] `AdButler.Chat.Tools.GetFindings` — schema: `severity_filter` (enum nullable), `kind_filter` (nullable), `limit` (default 10). Re-scopes through `Analytics.scope/2`. Returns finding IDs + titles + severities — keep payload small per `03-token-monitoring.md` §6 (cap at ~1k tokens).
- [ ] [W9D3-T3] Tool registry: `AdButler.Chat.Tools` module with `read_tools/0` and `write_tools/0` returning the lists of action modules. Centralized so the agent's request includes a single source of truth.
- [ ] [W9D3-T4] Tests: cross-tenant ad_id returns `:not_found` (security test); valid call returns expected shape; missing required arg returns NimbleOptions validation error.

#### Day 4 — Read Tools: Insights Series + Compare Creatives

- [ ] [W9D4-T1] `AdButler.Chat.Tools.GetInsightsSeries` — schema: `ad_id`, `metric` (enum: `:spend|:impressions|:ctr|:cpm|:cpc|:cpa`), `window` (enum: `:last_7d|:last_30d`), `breakdown` (nullable). Returns time series suitable for chart rendering. Re-scopes.
- [ ] [W9D4-T2] `AdButler.Chat.Tools.CompareCreatives` — schema: `ad_ids` (list, max 5) OR `creative_format` (string). Aggregates 7d insights per ad and returns a comparison matrix. Re-scopes; rejects > 5 ad_ids in NimbleOptions.
- [ ] [W9D4-T3] Tests: per-tool tenant isolation; tool result payload size assertion (< 8KB serialized).

#### Day 5 — SimulateBudgetChange + Loop Cap

- [ ] [W9D5-T1] `AdButler.Chat.Tools.SimulateBudgetChange` — schema: `ad_set_id`, `new_budget_cents`. Pure read-only — pulls last 30d delivery from matview, applies a frequency-saturation curve, returns projected `reach`, `frequency`, plus a `saturation_warning` boolean. No Meta API call.
- [ ] [W9D5-T2] Loop cap enforcement (D0010): in `Chat.Server`, count tool calls per turn. If `>6`, broadcast `{:turn_error, :loop_cap_exceeded}` and abort. Per `03-token-monitoring.md` §6.
- [ ] [W9D5-T3] System prompt module `AdButler.Chat.SystemPrompt` — under 2k tokens. "You are a media buyer's copilot. Be terse. Always cite finding IDs. Never invent metrics." Loads from a `priv/prompts/system.md` template so non-engineers can edit. Send via Anthropic `cache_control` (per ReqLLM v1.7+ caching note: only the last tool gets caching, so list system prompt last via the cache_control field, not the tool list).
- [ ] [W9D5-T4] End-to-end test (mocked LLM): send `"What's wrong with ad ABC?"`, assert agent calls `GetAdHealth` then `GetFindings` and produces a final assistant message citing the finding id.

---

### Week 10 — Chat UI + Streaming + Charts

#### Day 1 — ChatLive.Index + Routing + Sidebar

- [ ] [W10D1-T1][liveview] Routes in [router.ex](lib/ad_butler_web/router.ex) inside `:authenticated` live_session: `live "/chat", ChatLive.Index`, `live "/chat/:conversation_id", ChatLive.Show`. Wire under existing auth + scope plug.
- [ ] [W10D1-T2][liveview] Sidebar nav: add "Chat" entry next to "Findings" with chat-bubble heroicon. Active highlight on current path.
- [ ] [W10D1-T3][liveview] `ChatLive.Index` — paginated list of user's conversations (use `Chat.list_sessions/2`, default per-page 50 per CLAUDE.md). Stream conversations, "+ New chat" button → POSTs (or `handle_event` triggers `Chat.create_session` then `push_navigate` to new session). Paginated, no DaisyUI.
- [ ] [W10D1-T4] Tests: list shows only the user's sessions (tenant isolation); new chat creates a row + redirects.

#### Day 2 — ChatLive.Show Mount + History Pagination

- [ ] [W10D2-T1][liveview] `ChatLive.Show` skeleton — `mount/3` with `connected?/1` guard; `send(self(), {:load_conversation, cid})` pattern; subscribe to `"chat_stream:#{cid}"` and `"chat_agent:#{cid}"`. Initial assigns: `streams.messages` empty, `streaming_chunk: nil`, `pending_tool_calls: []`, `agent_status: :idle`, `page: 1`, `total_pages: 1`.
- [ ] [W10D2-T2][liveview] `handle_info({:load_conversation, cid}, socket)` — loads last 50 messages via `Chat.list_messages/3`, computes total_pages, populates stream.
- [ ] [W10D2-T3][liveview] Older-pages pagination — `handle_params(%{"page" => p}, _, socket)` loads page p, prepends via `stream_insert(at: 0)`. URL stays in sync.
- [ ] [W10D2-T4][liveview] `ChatLive.Components.message/1` — renders one message bubble. Role-aware styling (user: right-aligned blue, assistant: left-aligned gray, system_error: amber). Plain Tailwind only, no DaisyUI (CLAUDE.md mandate).

#### Day 3 — Streaming Chunks + Send Form

- [ ] [W10D3-T1][liveview] Compose form at bottom — textarea + send button. `phx-submit="send_message"` clears input, optimistically appends user message to stream, calls `Chat.send_message/3`. Set `agent_status: :thinking`.
- [ ] [W10D3-T2][liveview] `handle_info({:stream_chunk, %{delta: text}}, socket)` — appends text to `streaming_chunk` assign, sets `agent_status: :streaming`. Renders via `<.stream_chunk>` component (a "live" assistant bubble at the end of the stream that's NOT yet a stream item).
- [ ] [W10D3-T3][liveview] `handle_info({:turn_complete, %{message: msg}}, socket)` — clears `streaming_chunk`, `stream_insert(socket, :messages, msg)`, sets `agent_status: :idle`.
- [ ] [W10D3-T4][liveview] JS hook `ChatScroll` — calls `el.scrollIntoView({behavior: "smooth"})` after each LV patch. Respects user scroll-up (only auto-scroll if user is within 100px of bottom).
- [ ] [W10D3-T5] Test: simulate a stream, assert `streaming_chunk` accumulates and final message lands in stream.

#### Day 4 — Inline Charts + Tool Call Rendering

- [ ] [W10D4-T1] `AdButlerWeb.Charts` module — pure functions wrapping Contex. `line_plot(series, opts)` returns `{:safe, svg_iolist}`. Disable Contex default styles (`default_style: false`); rely on `app.css` rules targeting `.exc-*` classes.
- [ ] [W10D4-T2] `ChatLive.Components.chart_block/1` — renders a Contex SVG inside a styled card. Receives pre-rendered SVG.
- [ ] [W10D4-T3] `render_chart` directive: when assistant message has `tool_results` with a `{type: "chart", series, kind}` entry, the LiveView renders `<.chart_block>` inline within the message bubble. Agent emits this only after `GetInsightsSeries` returns.
- [ ] [W10D4-T4] `ChatLive.Components.tool_call/1` — collapsible block showing tool name + args + result (truncated). Default collapsed; click to expand. Used for both read and write tool calls in the message thread.
- [ ] [W10D4-T5] Test: chart_block renders SVG containing series points; tool_call collapses/expands via `phx-click toggle`.

#### Day 5 — Conversation Persistence + Replay + Polish

- [ ] [W10D5-T1] On `{:turn_complete, msg}`, persist via `Chat.append_message/2` (assistant role). Tool calls/results stored as JSONB on the message row.
- [ ] [W10D5-T2] Lazy agent start: `Chat.send_message/3` checks `Registry.lookup(SessionRegistry, session_id)`. If empty, `DynamicSupervisor.start_child(SessionSupervisor, {Chat.Server, session_id})`. Server replays last 20 messages from DB into agent state on init.
- [ ] [W10D5-T3] Hibernate idle agents: configure agent server to `hibernate_after: :timer.minutes(15)`. After 1h of inactivity, `terminate` cleanly. Memory hygiene for long-tail conversations.
- [ ] [W10D5-T4] Demo run: actually use chat for 10 turns on a real ad account; capture screenshots. Note any UI papercuts in [scratchpad.md](.claude/plans/v0.3-creative-fatigue-chat-mvp/scratchpad.md).

---

### Week 11 — Write Tools + Quotas + Eval + Ship

#### Day 1 — Write Tools + Confirmation Mechanic

- [ ] [W11D1-T1] `AdButler.Chat.Tools.PauseAd` (`use Jido.Action`, name: `"pause_ad"`). Schema: `ad_id`, `reason` (string, required — used for actions_log). Run: re-scope; if `context[:confirmation_token]` is missing OR not valid via `Chat.consume_confirmation/3`, insert `pending_confirmations` row (token = strong_rand_bytes 16, base64url, 5-min TTL) + return `{:error, {:confirmation_required, %{token, action: "pause_ad", args: %{ad_id, reason}}}}`. Otherwise call `Meta.Client.update_ad_status(ad_id, :paused)` + insert `actions_log` row.
- [ ] [W11D1-T2] `AdButler.Chat.Tools.UnpauseAd` — symmetric to PauseAd.
- [ ] [W11D1-T3] `Chat.consume_confirmation/3` — atomically loads `pending_confirmations` by token, checks `expires_at > now`, sets `consumed_at`, returns `{:ok, payload}` or `{:error, :expired}|{:error, :not_found}|{:error, :already_used}`. Single-row transaction.
- [ ] [W11D1-T4] `pending_confirmations` sweeper Oban cron (`0 * * * *`) — deletes rows where `expires_at < now() - interval '1 day'`. Houseekeeping.
- [ ] [W11D1-T5] Tests: confirmation required on first call; second call with valid token executes; expired token rejected; cross-user token rejected (security test); `actions_log` row written on success and on failure.

#### Day 2 — Confirmation UI + LiveView Wiring

- [ ] [W11D2-T1][liveview] `ChatLive.Components.confirmation_button/1` — receives `payload` (token, action, args, expires_at). Renders `[Pause ad_<id>]` button with `phx-click="confirm_tool" phx-value-token={@token}`. Shows expiry countdown.
- [ ] [W11D2-T2][liveview] `handle_event("confirm_tool", %{"token" => token}, socket)` — calls `Chat.confirm_tool_call(scope, conversation_id, token)`. Optimistically disables the button (sets a `consumed_token_set` assign).
- [ ] [W11D2-T3] Confirmation persistence (D0008): when a tool returns `{:error, {:confirmation_required, payload}}`, the agent persists a `chat_message` of role `tool` with the payload AND inserts the `pending_confirmations` row so a refresh re-renders the button correctly. The button's `token` matches the persisted row.
- [ ] [W11D2-T4] Test the LiveView reconnect scenario: persist a chat_message + pending_confirmation, mount fresh ChatLive.Show, assert button renders, click works, ad pauses.
- [ ] [W11D2-T5] Acceptance test: end-to-end PauseAd flow — user message → agent proposes → button renders → click → Meta API call (mocked) → ad shown as paused → actions_log row exists.

#### Day 3 — Billing Quotas + Circuit Breaker

- [ ] [W11D3-T1] `AdButler.Billing` context (formalize the boundary; existing `LLM` module folds in or stays as `LLM` sub-module of `Billing`). `check_quota/1` reads today's spend from `llm_usage` (cached in ETS, 30-second TTL per user) vs `user_quotas.daily_cost_cents_limit`. Returns `:ok | {:soft_warning, current, limit} | {:error, :quota_exceeded}`. Per `03-token-monitoring.md` §5 layer 1.
- [ ] [W11D3-T2] `Chat.send_message/3` calls `Billing.check_quota/1` first. If `:quota_exceeded`, returns `{:error, :quota_exceeded}` without calling the agent. ChatLive injects a system_error message into the thread.
- [ ] [W11D3-T3] `AdButler.Billing.CircuitBreaker` GenServer — `observe(user_id, cost_cents)` updates rolling 5-minute window per user. If `> $1.00` in 5 min, sets `user_quotas.cutoff_until = now + 15min`, logs at warn, broadcasts on `"billing:cutoff:#{user_id}"`. Per `03-token-monitoring.md` §5 layer 2.
- [ ] [W11D3-T4] `AdButler.Chat.Telemetry` — attaches to `[:req_llm, :token_usage]` and `[:req_llm, :request, :exception]`. On token_usage, looks up request_id in ETS table `:llm_request_context` (populated before each LLM call), maps to `{user_id, conversation_id, purpose}`, calls `Billing.record_usage/1`. Per D0009.
- [ ] [W11D3-T5] Bridge test: stub a `[:req_llm, :token_usage]` event; assert `llm_usage` row inserted with correct user_id and cost_cents; assert circuit breaker observed.

#### Day 4 — Eval Harness + Cost Visibility

- [ ] [W11D4-T1] `AdButler.Chat.Eval` module — runs a fixture conversation against the real agent (with a dedicated test ad account fixture). Loads questions from `priv/eval/questions.exs` — 20 questions with `expected_tool_sequence: [...]`, `expected_finding_ids: [...]`, `expected_citation: regex`.
- [ ] [W11D4-T2] Mix task `mix chat.eval` — runs the suite, prints pass/fail per question + summary. Acceptance ≥16/20 passing per roadmap.
- [ ] [W11D4-T3][liveview] Per-turn cost footer in `ChatLive.Components.message/1` — shows "this turn cost ~X tokens (~Y¢)" for assistant messages. Reads from `llm_usage` joined to `chat_messages.request_id`. Toggle via `Settings.show_token_costs` per-user flag (default on for partners).
- [ ] [W11D4-T4][liveview] Admin LiveView at `/admin/llm_usage` — gated on `current_user.role == :admin`. Shows: today's total spend, top-10 users today, top-10 MTD, breakdown by `purpose` and `model`, users currently cutoff. Per `03-token-monitoring.md` §7.
- [ ] [W11D4-T5] Quota-exceeded test (per `03-token-monitoring.md` §9): set `daily_cost_cents_limit = 10`; run 20 small calls; assert ~11th is blocked with `:quota_exceeded`.

#### Day 5 — Final Verify + Acceptance + Ship

- [ ] [W11D5-T1] Run `mix chat.eval` against the real test account; iterate on system prompt until ≥16/20.
- [ ] [W11D5-T2] Security test (acceptance criterion): assert no chat session can trigger a Meta write without an explicit `phx-click "confirm_tool"`. Specifically: a property test that fuzzes `tool_calls` payloads through the agent and asserts `actions_log.outcome != :success` unless preceded by a `pending_confirmations.consumed_at` row.
- [ ] [W11D5-T3] Latency check: simple-question turn < 10s, multi-tool turn < 30s on the test account. Profile with `:fprof` if over.
- [ ] [W11D5-T4] Run `mix precommit` (CLAUDE.md mandate) — fix all credo, format, hex.audit issues. Manually run `mix credo --strict` (precommit's hex.audit task may be missing — see `scratchpad.md`).
- [ ] [W11D5-T5] Docs update: add `docs/plan/decisions/0006-jido-libs.md` through `0012-stream-coalescing.md`; update `docs/plan/02-roadmap.md` v0.3 acceptance with checkboxes ticked.
- [ ] [W11D5-T6] Deploy to staging; smoke test PauseAd on a known-safe paused ad (and unpause); confirm telemetry → llm_usage flowing in production for ≥1 hour.
- [ ] [W11D5-T7] Tag `v0.3.0`, write release notes, hand off to design partner for week-12 onboarding.

---

## Risks (and mitigations)

1. **LLM hallucinates metrics in chat responses.** A user trusts a wrong number → reputation hit.
   *Mitigation*: structured output (`Jido.AI generate_object`) for any numeric claim; system prompt forbids freestyle math; eval suite catches regressions before deploy.

2. **Token cost runaway on power users.** Bug in tool-call loop burns $50 in one afternoon.
   *Mitigation*: D0010 (6-tool-call cap), Billing.CircuitBreaker (5-min $1 trigger), `daily_cost_cents_limit` hard cap default $5/day.

3. **Confirmation token loss on LiveView reconnect.** User sees a stale "Pause" button that does nothing.
   *Mitigation*: D0008 — persist `pending_confirmations` to DB. The button re-renders correctly across reconnects because the token is in the message JSONB + the DB row.

4. **Jido + jido_ai are pre-1.0.** API renames between minor versions can break us.
   *Mitigation*: pin to minor versions in mix.exs; wrap telemetry attachment in `Chat.Telemetry`; W8D5 spike day to learn before committing.

5. **Contex is stale (last release May 2023).** May not get critical fixes.
   *Mitigation*: keep chart code in `AdButlerWeb.Charts` module so swap to a Chart.js-via-LiveView-hook stack is one file. Decision is reversible per D0004.

6. **Meta App Review rejection blocks v1.0.** Not a v0.3 blocker but the critical path lengthens.
   *Mitigation*: keep using test ad account through v0.3; respond to reviewer feedback within 24h.

---

## Self-Check

- **Have you been here before?** v0.2's `BudgetLeakAuditorWorker` is the model for `CreativeFatiguePredictorWorker` — same Oban + scope + dedup pattern. The chat side is novel (Jido is new to the codebase).
- **What's the failure mode you're not pricing in?** ReqLLM streaming on HTTP/2 silently fails on bodies > 64KB — flagged in P0-T4 but worth a runtime assertion. Add a startup check that confirms HTTP/1 pool is configured.
- **Where's the Iron Law violation risk?** Tool modules calling `Repo` directly (must go through `Ads`/`Analytics`/`Chat` contexts). Add a `mix check.tools_no_repo` alias that greps `lib/ad_butler/chat/tools/` for `Repo.` calls.

---

## Verification After Each Week

```
mix compile --warnings-as-errors
mix format --check-formatted
mix check.unsafe_callers
mix credo --strict
mix test
```

End of week 11: also run `mix chat.eval`.

---

## Acceptance Criteria (from roadmap)

- [ ] On a 20-question eval set, agent produces correct cited answers for ≥16.
- [ ] Pause flow: LLM proposes, user confirms, ad paused in Meta within 30s.
- [ ] Avg chat turn under 10s simple, under 30s multi-tool.
- [ ] Per-user token usage visible per-conversation in admin dashboard.
- [ ] No chat session triggers a Meta write without an explicit user click — enforced by W11D5-T2 property test.
- [ ] CreativeFatiguePredictor emits findings on a representative ad with declining CTR + frequency saturation within one audit cycle.

---

## Out of Scope (deferred to v0.4 per roadmap)

- Compare Mode UI (chat-only in v0.3).
- What-If Simulator UI with sliders (only the read tool exists).
- Notification preferences / per-severity throttles.
- Per-ad-account heuristic weight customization.
- Status page, data export.
- Multi-turn tool chaining beyond 4 steps user-facing (we cap at 6 internally).
- Voice / mobile / shareable transcripts.
