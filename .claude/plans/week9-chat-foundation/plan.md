# Plan: Week 9 — Chat Foundation + Read Tools

**Window**: 1 week (~5 working days), with a spike day (W9D0) inserted ahead
of feature work.
**Source**: deepening of the Week 9 section of
[.claude/plans/v0.3-creative-fatigue-chat-mvp/plan.md](.claude/plans/v0.3-creative-fatigue-chat-mvp/plan.md#L204-L241).
**Decisions inherited**: D0006–D0012 (see v0.3 plan §"Architecture
Decisions"). No new architectural decisions in Week 9 — we're committing to
the existing ones. Any new decisions will be captured in
[scratchpad.md](.claude/plans/week9-chat-foundation/scratchpad.md).

---

## Goal

By end of Week 9, a chat session can be created, persisted, restored across
restarts, and driven by a Jido-based agent that:

- runs a ReAct loop bounded to 6 tool calls per turn
- has access to 5 read tools (GetAdHealth, GetFindings, GetInsightsSeries,
  CompareCreatives, SimulateBudgetChange) — all tenant-scoped, all returning
  payloads ≤ ~1k tokens
- emits ReqLLM telemetry that bridges into the existing `LLM.UsageHandler`
  so `llm_usage` rows appear (Week 11 will wire quotas + circuit breaker)
- has a system prompt under 2k tokens, sent with Anthropic prompt caching

LiveView (Week 10) and write tools + billing + eval (Week 11) remain out of
scope. Week 9 produces an **agent that works in `iex` against a real test
account**; Week 10 puts a UI on it.

---

## What Exists (entering Week 9)

| Already built | Path |
|---|---|
| ReqLLM keys + Finch HTTP/1 pool config | [config/runtime.exs](config/runtime.exs), [config/config.exs](config/config.exs) (W7 P0-T2/T4) |
| `LLM.UsageHandler` telemetry handler attached to `[:llm, :request, :stop]` | [lib/ad_butler/llm/usage_handler.ex](lib/ad_butler/llm/usage_handler.ex) |
| `llm_usage`, `llm_pricing`, `user_quotas` tables | priv/repo/migrations/20260420155226–155228 |
| `Embeddings.Service` wrapping `ReqLLM.embed/2` | [lib/ad_butler/embeddings/service.ex](lib/ad_butler/embeddings/service.ex) |
| `Embeddings.nearest/3` (semantic search) | [lib/ad_butler/embeddings.ex](lib/ad_butler/embeddings.ex) |
| Help docs seeded under `kind: "doc_chunk"` (13 docs) | [priv/embeddings/help/](priv/embeddings/help/) |
| Existing `scope/2` pattern in Analytics + Ads | [lib/ad_butler/analytics.ex](lib/ad_butler/analytics.ex), [lib/ad_butler/ads.ex](lib/ad_butler/ads.ex) |
| `paginate_findings/2` returning `{items, total}` | [lib/ad_butler/analytics.ex](lib/ad_butler/analytics.ex) |
| Mox setup + factory; 438/438 tests passing | [test/support/mocks.ex](test/support/mocks.ex), [test/support/factory.ex](test/support/factory.ex) |
| Jido + jido_ai + ReqLLM dep entries | [mix.exs](mix.exs) (W7 P0-T1) |

| NOT built (Week 9 scope) |
|---|
| `chat_sessions`, `chat_messages`, `pending_confirmations`, `actions_log` migrations + schemas |
| `AdButler.Chat` context with `scope/2`, `send_message/3`, `confirm_tool_call/3`, `record_action_log/1` |
| `Chat.SessionRegistry` + `Chat.SessionSupervisor` (DynamicSupervisor) |
| `Chat.Agent` (`use Jido.Agent`) + `Chat.Server` (wrapping `Jido.AgentServer`) |
| `Chat.Telemetry` bridging `[:req_llm, :token_usage]` → `LLM.UsageHandler` |
| 5 read tools under `lib/ad_butler/chat/tools/` |
| `Chat.SystemPrompt` module reading `priv/prompts/system.md` |
| `Chat.LLMClientBehaviour` + `Chat.LLMClient` (real) + `Chat.LLMClientMock` |
| Tool registry (`Chat.Tools.read_tools/0` / `write_tools/0`) |

---

## Forward References (NOT this week)

- **Week 10**: `ChatLive.Index`, `ChatLive.Show`, streaming UI, charts, sidebar
  nav entry, `/chat` routes. Week 9 builds the headless layer that Week 10
  renders.
- **Week 11**: write tools (`PauseAd` / `UnpauseAd`), confirmation UI,
  Billing context (quotas + circuit breaker), eval harness, admin dashboard.
- **D0008** (`pending_confirmations`) ships in Week 9 (table + context
  helpers) but is exercised first in Week 11. We build it now so Week 11 can
  focus on the Meta API call + UI.

---

## Pre-flight (W8 cleanup that gates W9 tools)

These three came out of the Week 8 review (W10/W11/W12) and are forward-flagged
as Week 9 prerequisites — chat tools will call `Embeddings.nearest/3` so the
hardening must land before the tools do.

- [x] [W9P-T1][ecto] Clamp `Embeddings.nearest/3` `kind` against allowlist — already shipped (`@valid_kinds = Embedding.kinds()` + guard at [embeddings.ex:128](lib/ad_butler/embeddings.ex#L128)).
- [x] [W9P-T2][ecto] Add a `limit` ceiling to `Embeddings.nearest/3` — already shipped (`@max_nearest_limit 50` + `min(limit, @max_nearest_limit)` at [embeddings.ex:124](lib/ad_butler/embeddings.ex#L124)).
- [x] [W9P-T3] Add `@doc` contract to `Embeddings.Embedding` — PII rule was already in [embedding.ex:19-33](lib/ad_butler/embeddings/embedding.ex#L19-L33); added the load-bearing-error-reasons block to `Embeddings` context @moduledoc.

---

## Day 0 — Spike (Jido API validation + telemetry shape)

**Why**: Jido + jido_ai are pre-1.0 and unused in this codebase to date.
The W8D5-T3 spike was deferred. Committing W9D2's architecture without this
walk-through guarantees rework.

**Format**: developer runs `iex -S mix` and works through the checklist
below; capture findings in `scratchpad.md` under "Decisions (Week 9)" and
update [research/jido-reqllm-patterns.md](research/jido-reqllm-patterns.md)
to remove its "PARTIAL" header.

- [x] [W9D0-T1] **`Jido.Agent` shape** — confirmed via [priv/spike/run.exs](priv/spike/run.exs). Domain state at `agent.state.<field>`; `:sys.get_state(pid).agent.state` from the AgentServer. `initial_state:` keyword on `start_link/1` works. See [scratchpad D-W9-02](.claude/plans/week9-chat-foundation/scratchpad.md).
- [x] [W9D0-T2] **`[:req_llm, :token_usage]` event shape** — confirmed. Measurements carry `:tokens` (input/output/cached/cache_creation/total) + `:cost/total_cost/input_cost/output_cost`. Metadata's `:request_id` is generic — use ETS context table with our own UUID. **Decision: collapse `LLM.UsageHandler` into `Chat.Telemetry`** (D-W9-03b) rather than the plan's option (a) or (b).
- [x] [W9D0-T3] **Streaming chunk delivery** — confirmed. Returns `%ReqLLM.StreamResponse{stream, cancel, context, model, metadata_handle}`; stream yields `%ReqLLM.StreamChunk{type: :content | :meta}`. **Single-pass** — re-iterating crashes the lazy GenServer (footgun captured). See [research/jido-reqllm-patterns.md §5](.claude/plans/week9-chat-foundation/research/jido-reqllm-patterns.md).
- [x] [W9D0-T4] **HTTP/1 boot assertion** — `assert_req_llm_http1_pool!/0` runs first thing in `Application.start/2` ([application.ex:22](lib/ad_butler/application.ex#L22)). Raises with config guidance if `:req_llm` `:default` pool isn't `[:http1]`.
- [x] [W9D0-T5] **Pre-flight cleanup tasks** — done; see W9P-T1/T2/T3 above.
- [x] [W9D0-T6] **Verify clean baseline** — compile/format/credo --strict/unsafe_callers all clean; `mix test`: **473/473, 0 failures**. Spike code lives under [priv/spike/](priv/spike/) as a re-runnable seed.

---

## Day 1 — Schemas + Context

Goal: durable persistence layer for chat. Schemas live inside the context
that owns them per CLAUDE.md.

- [x] [W9D1-T1][ecto] Migration `chat_sessions` — [20260501110603_create_chat_sessions.exs](priv/repo/migrations/20260501110603_create_chat_sessions.exs). Fields:
  `id uuid pk`, `user_id uuid fk references users(id) on delete cascade`,
  `ad_account_id uuid fk references ad_accounts(id) on delete set null`
  (nullable: a session may not be account-pinned),
  `title text` (nullable until first turn writes one),
  `status text default 'active' check status in ('active','archived')`,
  `last_activity_at timestamptz default now()`, `inserted_at`, `updated_at`.
  Index `(user_id, last_activity_at desc)` for paginated listing.
- [x] [W9D1-T2][ecto] Migration `chat_messages` — [20260501110604_create_chat_messages.exs](priv/repo/migrations/20260501110604_create_chat_messages.exs). Fields:
  `id uuid pk`, `chat_session_id uuid fk on delete cascade`,
  `role text check role in ('user','assistant','tool','system_error')`,
  `content text`, `tool_calls jsonb default '[]'::jsonb`,
  `tool_results jsonb default '[]'::jsonb`,
  `request_id text` (correlates to `llm_usage.request_id`),
  `status text default 'complete' check status in ('streaming','complete','error')`,
  `inserted_at timestamptz default now()`.
  Index `(chat_session_id, inserted_at)`.
- [x] [W9D1-T3][ecto] Migration `pending_confirmations` — [20260501110605_create_pending_confirmations.exs](priv/repo/migrations/20260501110605_create_pending_confirmations.exs). Fields:
  `id uuid pk`, `chat_message_id uuid fk on delete cascade`,
  `user_id uuid fk on delete cascade`,
  `token text not null`,
  `action text not null`, `args jsonb not null`,
  `expires_at timestamptz not null`, `consumed_at timestamptz`,
  `inserted_at timestamptz default now()`.
  Indexes: `unique(token)`, `(expires_at)` for the sweeper job (W11),
  partial unique `(chat_message_id) where consumed_at is null`.
- [x] [W9D1-T4][ecto] Migration `actions_log` — [20260501110606_create_actions_log.exs](priv/repo/migrations/20260501110606_create_actions_log.exs). CHECK constraint via `create constraint(...)` DSL per W8 review W7. Fields:
  `id bigserial pk`, `user_id uuid fk on delete restrict`,
  `chat_session_id uuid fk on delete set null`,
  `chat_message_id uuid fk on delete set null`,
  `tool text`, `args jsonb`,
  `outcome text check outcome in ('pending','success','failure')`,
  `error_detail text`, `meta_response jsonb`,
  `inserted_at timestamptz default now()`.
  Index `(user_id, inserted_at desc)`. CHECK constraints via
  `create constraint(...)` DSL not raw `execute` (W8 review W7).
- [x] [W9D1-T5][ecto] Schemas under `lib/ad_butler/chat/` — [session.ex](lib/ad_butler/chat/session.ex), [message.ex](lib/ad_butler/chat/message.ex), [pending_confirmation.ex](lib/ad_butler/chat/pending_confirmation.ex), [action_log.ex](lib/ad_butler/chat/action_log.ex). All have `@moduledoc` + per-public-def `@doc`. Schemas:
  `Session`, `Message`, `PendingConfirmation`, `ActionLog`. Each gets
  `@moduledoc` + every public def gets `@doc` (CLAUDE.md). Validations:
  Session — required `[:user_id]`, status enum; Message — required
  `[:chat_session_id, :role, :content]`, role enum, status enum, jsonb
  defaults to `[]` not `nil`; PendingConfirmation — required
  `[:chat_message_id, :user_id, :token, :action, :args, :expires_at]`,
  unique constraint on `:token`; ActionLog — required
  `[:user_id, :tool, :outcome]`, outcome enum.
- [x] [W9D1-T6] `AdButler.Chat` context module — [chat.ex](lib/ad_butler/chat.ex). `append_message/1` uses `Ecto.Multi` to bump `last_activity_at`. API:
  - `scope(queryable, user_id)` — `where(q, [s], s.user_id == ^user_id)`
    (sessions belong to users; tools re-scope through their own contexts).
    `:moduledoc` calls out that the simpler scope is *correct* here and the
    join-via-meta_connection_ids form is unnecessary — the schemas live
    behind a user FK.
  - `list_sessions/2`, `paginate_sessions/2 → {items, total}` (mirror
    `paginate_findings/2`; default `per_page: 50`),
  - `get_session!/2` (raises on cross-tenant access),
  - `create_session/2` — accepts `%{user_id, ad_account_id?}`, sets
    `last_activity_at: now()`,
  - `list_messages/3`, `paginate_messages/3 → {items, total}`,
  - `append_message/2` — returns `{:ok, %Message{}}` so callers can pattern
    match; `last_activity_at` on the parent session is bumped in the same
    transaction (`Ecto.Multi`),
  - `record_action_log/1` — single-row insert, called from tools.
  Schemas + context follow CLAUDE.md (Repo only here, scope on every read,
  `@doc` everywhere).
- [x] [W9D1-T7] Tests — [chat_test.exs](test/ad_butler/chat_test.exs), 19 tests covering tenant isolation for every read fn + content/role/outcome validation + `last_activity_at` bump:
  - migration round-trip (`mix ecto.migrate && mix ecto.rollback &&
    mix ecto.migrate`),
  - **tenant isolation** test for every list/paginate/get function
    (CLAUDE.md non-negotiable): user A creates a session; user B's
    `list_sessions/2` returns `[]`; `get_session!(scope_b, a_session.id)`
    raises,
  - `append_message/2` bumps `last_activity_at`,
  - `record_action_log/1` rejects bad outcome.

**Verify**: `mix compile --warnings-as-errors && mix format --check-formatted
&& mix check.unsafe_callers && mix credo --strict && mix test` clean.

---

## Day 2 — Agent Plumbing (Registry + Supervisor + Server)

Goal: per-session agent process, lazy-started, replays last 20 messages from
DB on init, terminates cleanly after idle.

- [x] [W9D2-T1] `AdButler.Chat.SessionRegistry` — added to [application.ex](lib/ad_butler/application.ex#L46-L52) along with `{Jido, name: Jido}` (per D-W9-01) and `Chat.SessionSupervisor`.
- [x] [W9D2-T2] `AdButler.Chat.SessionSupervisor` — `DynamicSupervisor` in same children block. `max_restarts: 50`.
- [x] [W9D2-T3] `AdButler.Chat.Agent` — [agent.ex](lib/ad_butler/chat/agent.ex), `use Jido.Agent` with Zoi schema (session_id/user_id/ad_account_id/history/step_count). Stubbed ReAct — W9D5 wires it.
- [x] [W9D2-T4] `AdButler.Chat.Server` — [server.ex](lib/ad_butler/chat/server.ex). Registers via SessionRegistry, init replays 20 msgs, `send_user_message/2` streams + counts tool calls (cap 6 + telemetry `[:chat, :loop, :cap_hit]`), terminate flips `streaming` rows to `error`. `hibernate_after` configurable via `:chat_server_hibernate_after_ms` env.
- [x] [W9D2-T5] `Chat.ensure_server!/1` — [chat.ex](lib/ad_butler/chat.ex). Registry.lookup → DynamicSupervisor.start_child fallback; idempotent on `:already_started`.
- [x] [W9D2-T6] `Chat.LLMClientBehaviour` + `Chat.LLMClient` — [llm_client_behaviour.ex](lib/ad_butler/chat/llm_client_behaviour.ex), [llm_client.ex](lib/ad_butler/chat/llm_client.ex). Real impl wraps `Jido.AI.stream_text/2`; `stop/1` invokes the StreamResponse `:cancel` fn.
- [x] [W9D2-T7] `Chat.LLMClientMock` — added to [mocks.ex](test/support/mocks.ex); bound in [test.exs](config/test.exs#L59).
- [x] [W9D2-T8] `Chat.Telemetry` — [telemetry.ex](lib/ad_butler/chat/telemetry.ex). Per **D-W9-03b**: collapsed `LLM.UsageHandler` into this module (deleted the legacy file + test). Attaches to `[:req_llm, :token_usage]` and `[:req_llm, :request, :exception]`. Correlation via process-dictionary `:chat_llm_context` (workers without context skip the insert). Application.start now calls `Chat.Telemetry.attach()` instead of `UsageHandler.attach()`.
- [x] [W9D2-T9] Tests — [chat/server_test.exs](test/ad_butler/chat/server_test.exs) (8 tests: registry/idempotent/replay/hibernate-heap/happy path/loop cap/terminate cleanup) + [chat/telemetry_test.exs](test/ad_butler/chat/telemetry_test.exs) (5 tests: context-driven persistence, no-context skip, idempotency, error event, dollars→cents). All use `start_supervised!` for clean lifecycle.
  - spawn a session via `Chat.send_message/3` (stubbed LLMClient via
    Mox); assert a `Chat.Server` is registered + Registry lookup works,
  - **history replay**: pre-seed 25 messages, restart the Server, assert
    only the last 20 land in agent state,
  - **lazy start**: assert no Server is running for a session that's never
    been messaged,
  - **idle hibernate**: simulate inactivity, assert the process hibernates
    (use `Process.info(pid, :status)`),
  - **loop cap**: stub the LLMClient to return tool-call deltas in a loop;
    assert the 7th tool call triggers `{:turn_error, :loop_cap_exceeded}`
    and the message is persisted with status `error`,
  - **telemetry bridge**: emit a synthetic `[:req_llm, :token_usage]`
    event; assert it is forwarded to `[:llm, :request, :stop]` (or to
    `Billing.record_usage` when wired) with the right metadata. Use a
    test-attached `:telemetry.attach_many` to observe.

**Verify**: full check loop. `mix test` should be at >= 450/450 by end of
Day 2 (~10 new tests).

---

## Day 3 — Read Tools: GetAdHealth + GetFindings

Goal: agent can answer "what's wrong with this ad?" by chaining two tools.
Both tools re-scope through the user_id-bearing context (`Ads`/`Analytics`)
— never trust LLM-supplied IDs. Cap payloads ≤ ~1k tokens (token-monitoring
§6).

- [x] [W9D3-T1] `AdButler.Chat.Tools.GetAdHealth` — [get_ad_health.ex](lib/ad_butler/chat/tools/get_ad_health.ex). Schema-validated `ad_id`; re-scopes via `Ads.fetch_ad/2`; payload < 4 KB asserted in tests.
  - Schema (NimbleOptions via Jido.Action): `ad_id: [type: :string,
    required: true]`.
  - `run(%{ad_id: ad_id}, %{session_context: %{user_id: uid}})`:
    - `with {:ok, ad} <- Ads.fetch_ad(uid, ad_id),` (new context fn —
      returns `{:error, :not_found}` on cross-tenant; **never raises**),
    - `health <- Analytics.latest_ad_health_score(ad.id),`
    - `findings <- Analytics.list_open_findings_for_ad(ad.id, limit: 3)`,
    - return `{:ok, %{ad_id, name, status, fatigue_score, leak_score,
      latest_finding_summary, fatigue_factors_excerpt}}`.
  - On cross-tenant `ad_id` returns `{:error, :not_found}` (silent — don't
    leak existence).
  - Payload size assertion in tests: serialized JSON < 4 KB.
- [x] [W9D3-T2] `AdButler.Chat.Tools.GetFindings` — [get_findings.ex](lib/ad_butler/chat/tools/get_findings.ex). Limit clamped to 25; severity/kind filters; metadata-only (no body/evidence).
  - Schema: `severity_filter: [type: {:in, [:low, :medium, :high]}]`,
    `kind_filter: [type: {:in, [:budget_leak, :creative_fatigue]}]`,
    `limit: [type: :pos_integer, default: 10]` (max 25 enforced inside
    `run/2`).
  - `run/2`: `Analytics.paginate_findings(scope, ...)` capped at 25; return
    list of `%{id, kind, severity, title, ad_id, inserted_at}` only —
    **no body, no evidence** (callers fetch detail via a follow-up
    `GetAdHealth` or W10 link).
  - Re-scopes via `Analytics.scope/2` using user_id (Analytics already does
    the meta_connection_id join internally).
- [x] [W9D3-T3] `AdButler.Chat.Tools` registry — [tools.ex](lib/ad_butler/chat/tools.ex). `read_tools/0` / `write_tools/0` / `all_tools/0`.
  ```elixir
  def read_tools, do: [
    AdButler.Chat.Tools.GetAdHealth,
    AdButler.Chat.Tools.GetFindings
    # GetInsightsSeries, CompareCreatives, SimulateBudgetChange land in W9D4/D5
  ]
  def write_tools, do: []  # Week 11
  def all_tools, do: read_tools() ++ write_tools()
  ```
  Single source of truth so `Chat.Server` builds one consistent
  `tools: ...` list per LLM call.
- [x] [W9D3-T4] `Ads.fetch_ad/2` — added at [ads.ex:524-545](lib/ad_butler/ads.ex#L524). Scopes through MetaConnection IDs; rescues `Ecto.Query.CastError` so non-UUID input returns `:not_found` (no leak via raise).
- [x] [W9D3-T5] `mix check.tools_no_repo` — added at [mix.exs:115-117](mix.exs#L115); greps `lib/ad_butler/chat/tools/` for `Repo.`; added to `precommit` alias.
- [x] [W9D3-T6] Tool tests — [get_ad_health_test.exs](test/ad_butler/chat/tools/get_ad_health_test.exs) (8 tests) + [get_findings_test.exs](test/ad_butler/chat/tools/get_findings_test.exs) (7 tests). Cover tenant isolation, payload size, schema validation via `validate_params/1`, NULL UUID, severity clamping.
  - **tenant isolation** (security; CLAUDE.md non-negotiable): create user
    A's ad; call from user B's `session_context`; assert `:not_found`,
  - happy path returns expected shape,
  - missing required arg returns NimbleOptions validation error
    (no raise; the agent receives `{:error, _}`),
  - payload size: JSON-encode the result and assert `byte_size < 4_000`,
  - extreme `limit` (e.g. 1000) clamped to 25,
  - `:not_found` returned on a syntactically-valid but non-existent UUID
    (so the LLM can't probe for ID existence).

**Verify**: full check loop. `mix check.tools_no_repo` clean.

---

## Day 4 — Read Tools: GetInsightsSeries + CompareCreatives

Goal: chartable / comparison data without exceeding payload caps. These
tools' outputs feed Week 10's chart rendering — Week 9 just produces the
data shape.

- [x] [W9D4-T1] `AdButler.Chat.Tools.GetInsightsSeries` — [get_insights_series.ex](lib/ad_butler/chat/tools/get_insights_series.ex). Schema-validated metric/window/ad_id; re-scopes via `Ads.fetch_ad/2`.
  - Schema: `ad_id: [type: :string, required: true]`,
    `metric: [type: {:in, [:spend, :impressions, :ctr, :cpm, :cpc, :cpa]},
    required: true]`,
    `window: [type: {:in, [:last_7d, :last_30d]}, default: :last_7d]`,
    `breakdown: [type: {:in, [:none, :age, :gender, :placement]},
    default: :none]`.
  - `run/2`: re-scope via `Ads.fetch_ad/2` first; then call
    `Analytics.get_insights_series/3` (new fn — same pattern as existing
    `Analytics` queries). Return `%{ad_id, metric, window, points: [{date,
    value}, ...], summary: %{min, max, avg, slope}}`.
  - Cap series at 30 points (last_30d natural ceiling). For breakdown,
    cap to top 5 buckets by spend; collapse rest into `"other"`.
- [x] [W9D4-T2] `Analytics.get_insights_series/3` — added at [analytics.ex](lib/ad_butler/analytics.ex). Reads `insights_daily` directly; supports spend/impressions/ctr/cpm/cpc/cpa across 7d/30d windows; returns `%{points, summary: %{min, max, avg, slope}}`.
  `insights_daily` (or matview) per metric. Closes over CTR / CPM / CPC /
  CPA derivations (CTR = clicks/impressions; CPM = spend/impressions·1000;
  etc.). Reuses derivation helpers from W7 if present.
- [x] [W9D4-T3] `AdButler.Chat.Tools.CompareCreatives` — [compare_creatives.ex](lib/ad_butler/chat/tools/compare_creatives.ex). Caps at 5 ad_ids; silently drops cross-tenant; `:no_valid_ads` on all-foreign list.
  - Schema: `ad_ids: [type: {:list, :string}, required: true]` (NimbleOptions
    `length: [max: 5]`).
  - `run/2`: re-scope every ad_id via `Ads.fetch_ad/2` — drop any that
    return `:not_found` (silent, like single-ad). For surviving ads,
    aggregate 7d insights and return `%{rows: [%{ad_id, name, spend,
    impressions, ctr, cpm, fatigue_score, leak_score}, ...]}`. Sorted by
    spend desc.
  - Returns `{:error, :no_valid_ads}` if all ad_ids were cross-tenant.
- [x] [W9D4-T4] Register both in `Chat.Tools.read_tools/0` — done in [tools.ex](lib/ad_butler/chat/tools.ex).
- [x] [W9D4-T5] Tool tests — [get_insights_series_test.exs](test/ad_butler/chat/tools/get_insights_series_test.exs) (7 tests) + [compare_creatives_test.exs](test/ad_butler/chat/tools/compare_creatives_test.exs) (5 tests). Cover tenant isolation, empty data, payload size, schema validation, mixed-tenant drop, 5-ad cap. Use `InsightsHelpers.insert_daily/3` and `create_insights_partition` setup.
  - tenant isolation,
  - schema validation (rejects unknown metric, > 5 ad_ids, etc.),
  - payload size assertion (< 8 KB serialized for CompareCreatives, <
    4 KB for GetInsightsSeries),
  - mixed-tenant `ad_ids` list — only own ads come back, no error,
  - empty-result shape (ad with no insights returns
    `points: []` not error).

**Verify**: full check loop.

---

## Day 5 — SimulateBudgetChange + Loop Cap + System Prompt + e2e

Goal: tools complete; agent runs end-to-end against a mocked LLM with the
real ReAct loop bounded by D0010.

- [x] [W9D5-T1] `AdButler.Chat.Tools.SimulateBudgetChange` — [simulate_budget_change.ex](lib/ad_butler/chat/tools/simulate_budget_change.ex). Pure read-only saturation curve (`reach' = reach × (1 - exp(-spend_ratio · 0.7))`). Confidence drops to `:low` under 7 days of data. Added `Ads.fetch_ad_set/2` and `Analytics.get_ad_set_delivery_summary/2`.
  - Schema: `ad_set_id: [type: :string, required: true]`,
    `new_budget_cents: [type: :pos_integer, required: true]`.
  - **Pure read-only** — no Meta API, no DB writes. Pulls 30d delivery
    via `Analytics.get_ad_set_delivery_summary/2`; applies a frequency
    saturation curve `reach' = reach × (1 - exp(-spend_ratio · k))` (k
    tunable, default 0.7 — captured as a `@saturation_constant` module
    attribute with a comment explaining provenance).
  - Returns `%{ad_set_id, current_budget_cents, new_budget_cents,
    projected_reach, projected_frequency, saturation_warning: bool,
    confidence: :low | :medium | :high}`. `confidence: :low` when the
    underlying 30d delivery has < 7 days of data.
- [x] [W9D5-T2] Loop-cap reinforcement — `@max_tool_calls_per_turn 6` hardcoded in [server.ex](lib/ad_butler/chat/server.ex); ReAct loop checks before each round. Telemetry `[:chat, :loop, :cap_hit]` with `count` + `session_id`. Allowlist updated in [config.exs](config/config.exs).
- [SKIPPED] [W9D5-T2-orig] (replaced by line above)
  cap (D0010) plays nice with the actual tool set. Hardcode the cap as
  `@max_tool_calls_per_turn 6` in `Chat.Server`; emit telemetry event
  `[:chat, :loop, :cap_hit]` when it triggers (one log line per event
  with metadata `[session_id:, user_id:, tool_call_count:]` — keys must
  be in [config/config.exs](config/config.exs) Logger allowlist; add
  any new ones).
- [x] [W9D5-T3] `AdButler.Chat.SystemPrompt` — [system_prompt.ex](lib/ad_butler/chat/system_prompt.ex). `@external_resource` triggers recompile on prompt edit; compile-time `byte_size < 8_000` assertion; `build/1` interpolates `{{today}}` and `{{ad_account_id}}`.
  - Loads from `priv/prompts/system.md` at compile time via
    `@external_resource` + `File.read!/1`,
  - `build/1` accepts `%{user_id, ad_account_id?, today}` and renders
    a final string with that context interpolated,
  - Asserts at compile time `byte_size(prompt) < 8_000` (rough ~2k
    token ceiling at 4 chars/token; tighten if W9D0 measurement
    suggests),
  - Sent via `cache_control` per ReqLLM 1.7+ caching rules
    (last-message gets the breakpoint — confirmed in W9D0).
- [x] [W9D5-T4] `priv/prompts/system.md` — drafted (~2k bytes < 8k cap). Covers role, tone, tool guidance, refusals, negative examples. See [priv/prompts/system.md](priv/prompts/system.md).
- [SKIPPED] [W9D5-T4-orig] (replaced by line above)
  tokens). Sketch:
  - Role: "media buyer's copilot".
  - Tone: terse, cite finding IDs, never invent metrics.
  - Tool guidance: prefer `GetFindings` for inbox queries; chain
    `GetAdHealth` after `GetFindings` for diagnosis; use
    `GetInsightsSeries` only when user asks about trend/chart.
  - Refusals: never propose budget changes outside tools; never
    speculate on ad performance without pulling a tool result first.
  - Negative examples (one-liners): "Don't compute CTR yourself —
    call `GetInsightsSeries`."
- [x] [W9D5-T5] `Chat.send_message/3` — [chat.ex](lib/ad_butler/chat.ex). Authorises session via `get_session/2`, lazy-starts the Server, forwards to `Server.send_user_message/2`. **Bonus**: rewrote `Chat.Server.run_turn` into a real ReAct loop that dispatches tools via `Jido.Action.run/2`, persists per-turn `tool` messages with jsonb `tool_calls`/`tool_results`, and recurses up to the cap.
  ```elixir
  def send_message(scope, session_id, body) do
    with {:ok, _} <- ensure_server!(session_id),
         {:ok, _msg} <- Chat.append_message(%{role: "user", ...}) do
      Chat.Server.send_user_message(session_id, body)
      :ok
    end
  end
  ```
  No quota check yet — `Billing.check_quota/1` lands in W11.
- [x] [W9D5-T6] **End-to-end test** — [e2e_test.exs](test/ad_butler/chat/e2e_test.exs). `@moduletag :integration`. Scripts 3 sequential `LLMClientMock.stream` calls (tool_call get_findings → tool_call get_ad_health → final text); asserts user/tool/assistant messages persist, finding_id appears in assistant content, `actions_log` rows = 0, `llm_usage` row inserted with correct user_id and token counts.
  - script the LLM to: tool_call `get_ad_health` → result → tool_call
    `get_findings` → result → final assistant text citing finding ID,
  - assert: 3 messages persisted (user, tool x2 *or* assistant w/ jsonb
    tool_calls per the schema, final assistant), final assistant
    `content` mentions the seeded finding's id, `actions_log` row
    count = 0 (read tools only), `llm_usage` row exists for the turn.
  - guard the test with `@moduletag :integration` so it doesn't run on
    every `mix test`.
- [DEFERRED] [W9D5-T7] Reality-check spike — manual iex against real LLM keys. Requires running app boot (RabbitMQ etc.); leaving for post-merge smoke test on dev box.
  phx.server`; in iex create a session for a test user, call
  `Chat.send_message/3`, watch logs, watch `chat_messages` table fill.
  This catches anything the test suite missed (wrong process linkage,
  missing telemetry attachment, etc.). Capture findings in
  [scratchpad.md](.claude/plans/week9-chat-foundation/scratchpad.md).
- [x] [W9D5-T8] **Verify full week** — compile clean, format clean, credo --strict clean, check.tools_no_repo clean, check.unsafe_callers clean. `mix test`: **510/510, 0 failures**. `mix test --include integration` adds the chat e2e (passes); 7 RabbitMQ-broker integration tests fail but are pre-existing (need running broker).
  ```
  mix compile --warnings-as-errors
  mix format --check-formatted
  mix deps.unlock --unused
  mix check.unsafe_callers
  mix check.tools_no_repo
  mix credo --strict
  mix test
  mix test --include integration   # the e2e test
  ```
  All green. `mix test` count should be ~470/470 by end of Week 9
  (438 entering + ~30 added). `mix precommit` itself still fails on
  `hex.audit` (pre-existing — see scratchpad).

---

## Risks (Week 9 specific)

1. **Jido 2.2 API drift from our assumptions.**
   *Mitigation*: W9D0 spike. If the spike reveals a fundamental shape
   mismatch (e.g., `Jido.AgentServer` doesn't exist as a public symbol
   in 2.2), update v0.3 plan D0007 + this plan's W9D2 immediately —
   don't proceed to W9D2 with the wrong abstraction.

2. **`[:req_llm, :token_usage]` event shape doesn't match
   `[:llm, :request, :stop]` schema.**
   *Mitigation*: W9D2-T8 has two paths (re-emit vs direct call). W9D0-T2
   measures the actual event. The plan already accommodates either
   choice.

3. **Tool payload bloats past 8 KB** as Analytics queries get richer
   (e.g., breakdown buckets multiply).
   *Mitigation*: payload-size asserts in every tool's tests. They fail
   loud; we trim on the spot. Don't ship a "we'll cap it later" tool.

4. **History replay is wrong direction** — `list_messages/3` returns ASC
   inserted_at, agent state expects last-N. Off-by-one in the order is
   easy and silent.
   *Mitigation*: explicit test (W9D2-T9 history replay). Unit test asserts
   `agent.history |> Enum.map(& &1.inserted_at)` is monotonic ascending.

5. **ETS `:llm_request_context` table not created before first LLM call.**
   *Mitigation*: own the table in `Chat.Telemetry` (started in Application
   children); make it `:public, :set, read_concurrency: true` so any
   process can populate. `Chat.Server` calls
   `Chat.Telemetry.set_context(request_id, ctx)` immediately before
   `LLMClient.stream/2`. The handler does `:ets.take/2` so duplicate
   firings can't double-count.

6. **`hibernate_after` masks a memory leak.**
   *Mitigation*: integration test (manual) — start 100 sessions, check
   `:erlang.memory(:processes)` before / after / 30 minutes after. If
   memory doesn't return to baseline, file a bug.

---

## Self-Check

- **Have you been here before?** v0.2's Oban worker pattern is well-trodden;
  the agent shape is novel. The risk concentrates in Days 0 + 2.
- **What's the failure mode you're not pricing in?** ReqLLM streaming
  silently truncating on chunked-encoding edge cases when the model emits
  binary tool args that include UTF-8 boundary bytes. If we observe
  truncated tool_calls in W9D5 e2e, add a runtime assertion that
  `Jason.decode!(args)` succeeds before passing to the action; surface
  parse failures as `{:turn_error, :malformed_tool_call}`.
- **Where's the Iron Law violation risk?** Tool modules sneaking a `Repo`
  call. W9D3-T5 adds `mix check.tools_no_repo` to make this a CI failure.
  Also: `Chat.Server` accidentally calling `Repo` for message persistence
  — it must go through `Chat.append_message/2`. Lint via the existing
  `mix check.unsafe_callers` (which already covers other contexts).

---

## Verification After Each Day

```
mix compile --warnings-as-errors
mix format --check-formatted
mix check.unsafe_callers
mix credo --strict
mix test
```

End of week additionally:
```
mix check.tools_no_repo
mix test --include integration
```

---

## Acceptance (Week 9)

- [x] All 4 chat tables migrated; tenant-isolation tests pass for every
  `Chat` read function.
- [x] `Chat.Server` lazy-starts under `SessionSupervisor`; replays last
  20 messages on init; hibernates after 15 min idle.
- [x] 5 read tools registered in `Chat.Tools.read_tools/0`; each has a
  cross-tenant test (`{:error, :not_found}` on foreign ID), a payload
  size test, and a schema-validation test.
- [x] `Chat.Telemetry` attached at boot; a synthetic
  `[:req_llm, :token_usage]` event triggers an `llm_usage` row.
- [x] 6-tool-call cap fires the expected `{:turn_error,
  :loop_cap_exceeded}` and persists the offending message as `error`.
- [x] `priv/prompts/system.md` < 2k tokens (asserted at compile time).
- [x] e2e integration test green: scripted LLM tool sequence produces
  a final assistant message citing a finding id, with no `actions_log`
  rows and exactly one `llm_usage` row.
- [x] `mix check.tools_no_repo` clean.

---

## Out of Scope (deferred)

- LiveView UI / streaming UI / charts — Week 10.
- `PauseAd` / `UnpauseAd` write tools + confirmation UI — Week 11.
- `Billing` context (quota check, circuit breaker) — Week 11.
- Eval harness `mix chat.eval` — Week 11.
- Admin LLM-usage dashboard — Week 11.
- Per-user `show_token_costs` toggle (requires user preferences schema —
  see Explore agent's note re: missing `Settings`/`users.preferences`).
- Rich agent-side conversation summarization for long sessions — handled
  implicitly by the 20-message replay window in Week 9; revisit at v0.4
  if turns drift past usefulness.
