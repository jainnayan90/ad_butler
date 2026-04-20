# Token Usage & Cost Monitoring

A focused design for tracking, attributing, and governing LLM token spend per user. This is called out separately because it's the dominant variable cost of the product and you explicitly said it's where MVP operational spend will concentrate.

## 1. Goals and non-goals

**Goals**

- Know, to the nearest cent, how much each user costs you per day, per week, per conversation, per chat turn.
- Stop runaway spend within seconds — not hours.
- Make the data trivially queryable so you can set pricing intelligently later.
- Instrument once; add policy (quotas, alerts, dashboards) on top without changing the capture layer.

**Non-goals for MVP**

- Charging users based on usage (no Stripe metering in MVP).
- Charging different prices per model — just track it.
- Optimizing prompts for cost (worth doing, but a separate workstream).
- Distributed rate limiting across multiple LLM API keys (single-key for MVP).

## 2. What to capture

Per LLM call, capture:

- `user_id`, `conversation_id`, `turn_id`
- `purpose` — an enum: `:chat_response`, `:embedding`, `:finding_summary`, `:tool_arg_classification`, ... — so you can later see "embeddings are 40% of my bill."
- `provider` (`:anthropic`, `:openai`), `model` (e.g., `claude-sonnet-4-6`), `api_version`
- `input_tokens`, `output_tokens`, `cached_tokens` (Anthropic/OpenAI both bill cached input cheaper; capture separately)
- `cost_cents_input`, `cost_cents_output`, `cost_cents_total` — computed at write time from a versioned pricing table, not at read time (prices change; you want to see what it *cost you* that day, not what it would cost today)
- `latency_ms`, `status` (`:ok` | `:error` | `:timeout`)
- `request_id` from ReqLLM for correlation
- `inserted_at`

Don't store the prompt or response body in this table. Store them separately (in `chat_messages`) if at all, with independent retention.

## 3. Data model

Three tables:

### 3.1 `llm_usage` — the ledger

```
llm_usage
  id bigserial
  user_id uuid (indexed)
  conversation_id uuid (indexed, nullable — embeddings run outside chats)
  turn_id uuid (nullable)
  purpose text
  provider text
  model text
  input_tokens int
  output_tokens int
  cached_tokens int default 0
  cost_cents_input int
  cost_cents_output int
  cost_cents_total int  -- generated column: input + output
  latency_ms int
  status text
  request_id text
  metadata jsonb  -- escape hatch for anything provider-specific
  inserted_at timestamptz default now()
```

Index `(user_id, inserted_at desc)` and `(inserted_at)` for aggregate queries. Append-only. Partition by month if it grows — will not in MVP.

### 3.2 `llm_pricing` — versioned pricing

```
llm_pricing
  id bigserial
  provider text
  model text
  cents_per_1k_input numeric(10,6)
  cents_per_1k_output numeric(10,6)
  cents_per_1k_cached_input numeric(10,6) nullable
  effective_from timestamptz
  effective_to timestamptz nullable  -- null = current

  unique(provider, model, effective_from)
```

Every LLM call's cost is computed against the row where `inserted_at` falls in `[effective_from, effective_to)`. When a provider changes prices, you close out the current row and insert a new one. Historic rows in `llm_usage` keep showing the cost you actually paid.

### 3.3 `user_quotas` — per-user policy

```
user_quotas
  user_id uuid primary key
  daily_cost_cents_limit int default 500      -- $5/day hard cap
  daily_cost_cents_soft int default 300       -- warn the user
  monthly_cost_cents_limit int default 10000  -- $100/mo hard cap
  tier text default 'free'                    -- 'free' | 'partner' | 'internal'
  cutoff_until timestamptz nullable           -- if set and in future, LLM disabled
  note text nullable
  updated_at timestamptz
```

Quotas are per-user, not per-org. For MVP this is enough. Add `organization_id` only when teams ship (post-MVP).

## 4. Capture path (telemetry, not wrapper)

jido_ai and its ReqLLM dependency already emit `[:req_llm, :request, :stop]` and `[:req_llm, :token_usage]` events. Attach a handler in application startup that:

1. Extracts token counts from measurements, model from metadata.
2. Resolves user context via the `request_id` → a lookup in a small ETS table we populate before each LLM call.
3. Computes cost against the current `llm_pricing` row (cached in ETS; refreshed on price table changes via Phoenix.PubSub).
4. Inserts an `llm_usage` row via `Billing.record_usage/1`.
5. Broadcasts a `Phoenix.PubSub` event `"user:#{user_id}:usage"` for live UIs.

The "lookup the user for a request_id" step matters because ReqLLM telemetry doesn't know about your `user_id`. Pattern:

```elixir
# Before invoking jido_ai:
request_id = Ecto.UUID.generate()
:ets.insert(:llm_request_context, {request_id, %{user_id: user_id, conversation_id: conv_id, purpose: :chat_response}})
Jido.AI.Agent.ask(agent, prompt, request_id: request_id, ...)

# In telemetry handler:
[{^request_id, ctx}] = :ets.take(:llm_request_context, request_id)
Billing.record_usage(Map.merge(ctx, token_data))
```

Telemetry handlers must be fast and must not raise. Move the DB write to a `Task.Supervisor.start_child` so any failure in the billing path never breaks the chat path. Accept that, in a crash, you might drop a handful of usage rows. Reconcile via the admin tool in §7.

## 5. Enforcement (quotas + circuit breakers)

Three layers, in order of how often they fire:

**Layer 1 — Pre-flight check (every LLM call).** Before calling `Jido.AI.Agent.ask`, call `Billing.check_quota(user_id)`:

- Reads today's total cost from `llm_usage` (cached in ETS with a 30-second TTL per user).
- Reads user's `daily_cost_cents_limit`.
- If over hard limit, returns `{:error, :quota_exceeded}` and the chat layer responds with a friendly "you've hit today's limit" message — no LLM call made.
- If over soft limit, proceed but set a flag on the response so the UI can show a warning banner.

**Layer 2 — Circuit breaker (anomaly protection).** A GenServer (`Billing.CircuitBreaker`) tracks rolling 5-minute spend per user. If it exceeds a reasonable threshold (e.g., $1.00 in 5 minutes), flip the breaker open for that user: set `user_quotas.cutoff_until = now() + 15 minutes`, log it, page yourself. This catches bugs like infinite tool loops before they become a line item on your bill.

**Layer 3 — Global cap.** Across all users, if total hourly spend exceeds $X (e.g., 5× your normal peak), raise an alert and optionally flip a kill switch that refuses new LLM calls entirely. Insurance against the worst case where the telemetry handler itself is broken and per-user checks aren't firing.

## 6. Avoiding common leaks

Several patterns that silently burn tokens:

- **Unbounded tool-call loops.** The LLM calls a tool → the tool returns → the LLM calls another → forever. Cap agent loops at N tool calls per turn (N=6 is a reasonable starting point). Enforce in the Jido agent's `cmd/2`.
- **Retry storms.** An LLM timeout triggers an app retry, which triggers another, which retries the whole conversation including all history. Use a strict retry budget (1 retry max) and never retry with full history by default.
- **Huge system prompts.** Every turn re-sends the system prompt. Keep the static system prompt under 2k tokens. Put user-specific context in the user message (cachable for Anthropic/OpenAI prompt caching).
- **Shoving entire insights tables into the prompt.** The agent should retrieve narrow slices via tools, not get pre-loaded with "here are all your ads." Cap tool responses to ~1k tokens of serialized data; if larger, return a summary plus a `fetch_more_via_X` hint.
- **Re-embedding unchanged content.** Before calling the embeddings API, check whether the row has changed since last embedding. Hash the text; only re-embed on hash change.
- **Embedding entire finding bodies repeatedly.** Embed once on write; never on read.
- **Debug mode left on in prod.** A "log the full prompt" toggle that prints to stdout can balloon your log bill to match your LLM bill. Guard it, and never enable by default.

## 7. Observability and ops

**User-facing.** Every chat response footer shows `this turn cost you X tokens (~Y cents)`. Users appreciate the transparency, and it trains them to ask better questions. Toggle via a settings flag; default on for partners, off for general users.

**Admin dashboard.** A single LiveView page showing:

- Today's total spend, MTD spend, 30-day rolling spend.
- Top 10 users by today's spend.
- Top 10 users by MTD spend.
- Spend breakdown by `purpose` (chat vs embeddings vs classification).
- Spend breakdown by `model`.
- Users currently over their soft limit.
- Users currently cut off (circuit-broken or hit hard limit).
- A "reconcile" button: re-computes costs against current pricing for a date range (used if you discover a pricing bug).

**Alerts.** Wire to whatever you use (Slack, email, PagerDuty for whenever you graduate). Default alerts:

- Global hourly spend > 5× last 7-day average → page.
- Any single user > $5 in one hour → page.
- Circuit breaker tripped → Slack notification.
- Telemetry handler crash rate > 1% → page (this is the "we're flying blind" alarm).

**Reports.** Weekly CSV export of per-user usage for the week, emailed to yourself. Cheap to build, invaluable when you're setting pricing.

## 8. Pricing thought (not in MVP, but shaped by this)

You don't need to pick pricing now, but the data model should support any of:

- Flat subscription with generous but real token quotas ("Solo $49/mo includes up to $8/mo of LLM spend; cap enforced").
- Usage-based ("base $29 + metered tokens").
- Tiered ("Solo: 1 account, $X; Pro: 3 accounts, $Y").

Since you're tracking per-user, per-conversation cost with provider/model breakdown, any of these is a straightforward reporting query post-MVP. Resist integrating Stripe metering until you actually know which model you'll use — the data is the hard part, and you're capturing it.

## 9. Testing the billing path

Billing correctness is a sensitive zone. Before v0.3 ships:

- Deterministic test: stub ReqLLM to emit known telemetry events; assert `llm_usage` rows are created with correct costs.
- Quota test: set `daily_cost_cents_limit = 10`; run 20 small LLM calls in a test; assert the 11th or so is blocked with `:quota_exceeded`.
- Circuit breaker test: simulate rapid calls; assert breaker opens at the threshold and closes after cooldown.
- Pricing migration test: insert `llm_pricing` row with new prices; assert new `llm_usage` rows use new prices while historic rows retain old.
- Reconciliation test: corrupt one day of `cost_cents_*` rows; run the reconcile tool; assert totals match pre-corruption.

## 10. What success looks like at v0.4

- You can answer "what did user X cost us this month?" from a SQL query in under a minute.
- No user has surprised you with a cost spike larger than 3× their rolling average without you hearing about it within 5 minutes.
- Every penny you've spent on the LLM provider can be attributed to a user, a purpose, and a conversation.
- You can change models (Claude 3.5 → Claude 4.x → GPT-4o-mini) with a `llm_pricing` row insert and a config flag — no code changes to the capture path.
