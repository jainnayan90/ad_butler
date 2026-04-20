# Phased MVP Roadmap

A planning document. Phases are sized in "calendar weeks of full-time focus" so you can stretch or compress based on how much time is actually available. They are cumulative: each phase adds to the previous.

## Philosophy

Build in this order because the order inverts the usual mistake on LLM-native products:

1. Prove you can **reliably ingest and reason about Meta data** before building chat.
2. Prove the **two analyzers produce trustworthy findings** before wrapping them in an agent.
3. Build chat **last**, once there's something worth chatting about.

The temptation is to build the chat first because it's the most fun. Resist it — an LLM agent with nothing reliable to query behind it is just a very expensive autocomplete.

Also: ship the token ledger in v0.1, not v0.3. Adding it later means back-filling data you can't reconstruct. See `03-token-monitoring.md`.

## v0.1 — Foundation (weeks 1–3)

**Goal:** A user can connect a Meta ad account, and the system pulls and stores their data correctly. No insights, no analysis, no chat. Boring on purpose.

**Scope**

- Phoenix app skeleton with `Accounts`, `Meta`, `Ads`, `Sync`, `Billing` contexts.
- Tenant-scoping helper (`scope/2`) codified in each tenant-owned context; discipline that no `Repo` calls happen outside contexts. RLS deliberately skipped — see `decisions/0001-skip-rls-for-mvp.md`.
- Meta OAuth login (scopes: `ads_management`, `ads_read`, `email`). Multi-tenant Meta app — start App Review process on day one; it's a multi-week-long blocker.
- Encrypted token storage with `Cloak.Ecto`. Token refresh background job.
- Postgres schema for `users`, `meta_connections`, `ad_accounts`, `campaigns`, `ad_sets`, `ads`, `creatives`. Normalized + `raw_jsonb` column on each.
- `Sync.MetadataPipeline` (Broadway + RabbitMQ): pulls ad-object metadata for one account on demand. Batched calls. Rate-limit ledger in ETS. Telemetry on every API call.
- The token ledger from `03-token-monitoring.md`: `llm_usage` table, telemetry handler wired up. No LLM calls yet, but the plumbing is in place.
- Minimal LiveView: login, connect account, see a list of your ads. Nothing fancy.
- Staging deploy on Fly/Render/wherever. One `web` node, one `worker` node.

**Out of scope for v0.1**

- Insights data (no warehouse yet).
- Any UI beyond "look at your ad list."
- Any LLM features.
- Timescale — just plain Postgres until insights arrive.

**Acceptance criteria**

- You can log in with your own Meta account, connect a test ad account, see your ads listed.
- `mix ecto.dump` schema matches the planned model.
- A purposefully bogus request (e.g., invalid ad_id) surfaces as a graceful error, not a 500.
- At least one broken sync partition can be replayed from RabbitMQ DLQ without data loss.
- Meta App Review submission is in flight.

**Key risks**

- App Review takes longer than expected. Mitigation: use a test ad account (Meta Development mode) for all v0.1–v0.3 work, only blocking on review before v1.0 launch.
- Meta token encryption choice is wrong. Mitigation: pick Cloak.Ecto, don't write custom crypto.

## v0.2 — Warehouse + first analyzer (weeks 4–6)

**Goal:** Insights are flowing and the Budget Leak Auditor produces findings a real media buyer would nod at. No chat yet.

**Scope**

- Add `insights_daily` as a partitioned Postgres table (weekly partitions by `date_start`); create the `PartitionManager` Oban job that rolls partitions forward and detaches beyond retention. Materialized views for rolling-window aggregates. See `decisions/0002-partitioned-postgres.md`.
- `Sync.InsightsPipeline` (Broadway): every-30-min pull of last-2-days delivery metrics per account; every-2h async job for conversion metrics last 7 days.
- Jittered scheduler so 1k accounts don't hammer the API at once.
- Rate-limit-aware deferral: if account is >85% on usage, skip this cycle and emit a warning.
- `Analytics.BudgetLeakAuditor` as an Oban job. All five MVP heuristics (see architecture §6.1). Writes to `ad_health_scores` and `findings`.
- `findings` inbox in LiveView: list, filter by severity, drill down to see evidence and the raw insights data that triggered the finding.
- Email digest: daily/weekly summary of new high-severity findings.
- First design-partner user onboarded with their own account (not your test account).

**Out of scope for v0.2**

- Creative fatigue (next phase).
- Any LLM features.
- Multi-user teams / roles.
- Self-serve signup — invite-only.

**Acceptance criteria**

- For a real ad account with at least one underperforming ad, the auditor correctly identifies it within 24 hours of it going off the rails.
- False-positive rate on findings is tolerable in manual review (no hard number yet — review every finding in the first 2 weeks with the design partner).
- Insights sync completes within its 30-min window for the test cohort; no alerts about pipeline lag.
- One design partner actively logs in and reviews findings at least weekly.

**Key risks**

- Heuristics produce too many false positives, users lose trust. Mitigation: tune weights against the design partner's historical ad performance before going wider.
- Manual partition lifecycle is a new thing to monitor. Mitigation: alert if `PartitionManager` hasn't created a future partition within the safety buffer; keep at least 2 future partitions ahead at all times.

## v0.3 — Creative fatigue + chat MVP (weeks 7–11)

**Goal:** Both analyzers are live. Users can chat with their data, including "pause this ad" via confirmation. This is the first phase that feels like the product in your head.

**Scope**

- `Analytics.CreativeFatiguePredictor`:
  - Heuristic layer (frequency + CTR decay + quality_ranking drop).
  - Simple per-ad regression fit nightly to project CTR 3 days out.
  - Writes to `ad_health_scores` (fatigue_score, fatigue_factors) and `findings`.
- pgvector embeddings for ads, findings, and a small static doc corpus (help articles, glossary).
- Jido + jido_ai integration:
  - `ChatSession` Ecto schema; conversation history in Postgres.
  - `Jido.AgentServer` per active session under a `DynamicSupervisor`.
  - Read tools: `GetAdHealth`, `GetFindings`, `CompareCreatives`, `GetInsightsSeries`, `SimulateBudgetChange`.
  - Write tools: `PauseAd`, `UnpauseAd`. Both require `confirmation_token` in context or return `{:error, :confirmation_required}`.
  - ReAct strategy with a carefully-written system prompt ("you are a media buyer's copilot, be terse, always cite finding IDs, never invent metrics").
- LiveView chat UI with streaming, inline chart rendering via server-rendered Contex SVGs, and confirmation buttons for write tools.
- Per-user token quotas + soft / hard limits (see `03-token-monitoring.md` §5).
- `actions_log` table for every write tool call.

**Out of scope for v0.3**

- The "What-If Simulator" covering budget changes beyond saturation warnings — keep it to projected reach/frequency, no deep modeling.
- Multi-turn tool chaining beyond 4 steps — cap agent loops to prevent runaway token burn.
- Voice / mobile.
- Shareable chat transcripts.

**Acceptance criteria**

- On a representative eval set of 20 questions about a real ad account, the chatbot produces correct, cited answers for ≥16 of them.
- "Pause this ad" flow: the LLM proposes, user confirms, ad is paused in Meta within 30 seconds.
- Average chat turn under 10 seconds end-to-end for a simple question; under 30 seconds for a multi-tool question.
- Per-user token usage visible in your admin dashboard, down to per-conversation granularity.
- No chat session has ever triggered a write to Meta without an explicit user click — enforced by tests.

**Key risks**

- LLM makes things up about metrics. Mitigation: structured output for any numeric claim ("I'd trust this response only if every number came from a tool call"); no freestyle math in the response.
- Token costs balloon on power users. Mitigation: quota cut-off (hard limit) + per-user admin view.
- Jido learning curve eats time. Mitigation: spike a throw-away "pause ad" agent in v0.2 evenings to de-risk.

## v0.4 — Polish for design partners (weeks 12–14)

**Goal:** Product is in the hands of 5–10 paying-intent design partners. You get real feedback loops. Not public yet.

**Scope**

- Onboarding flow polish: clearer empty states, the first-24-hour "here's what I'm scanning for" explainer.
- Chat: "Compare Mode" explicit UI affordance, not just a prompt; dedicated entry point.
- Chat: "What-If Simulator" proper UI with sliders and saturation warnings.
- Notification preferences (per-severity email throttles).
- Per-ad-account settings: leak/fatigue weighting customization for users who say "your 'dead spend' threshold is too aggressive for me."
- Admin dashboard: total users, connected accounts, findings delivered, LLM spend per user and in aggregate, pipeline health.
- Status page / health checks for your team; public status page can wait.
- Data export: CSV / JSON of findings and insights, in case a user wants to leave.

**Out of scope for v0.4**

- Payments. Charge partners by invoice or free; integrate Stripe post-MVP.
- Self-serve signup. Still invite-only or waitlist.
- Google Ads / TikTok Ads. Stay Meta-only until v1.0.
- Team accounts / roles.

**Acceptance criteria**

- 5+ design partners actively using the product weekly.
- At least 2 partners have pushed the "Pause" button from chat and reported the outcome useful.
- Median user's weekly LLM cost is predictable enough to set a price.
- Admin dashboard answers "who are my highest-risk-of-churn users" at a glance.
- You have a list of 20+ real feature requests from partners, prioritized.

**Key risks**

- Design partners want features that fragment focus (e.g., Google Ads). Mitigation: written "not in MVP" doc shared at onboarding.
- Word-of-mouth outpaces the waitlist. Good problem; have a "coming soon" page ready.

## Explicit "NOT in MVP" list

Things that will be asked for and that you should say no to until post-v0.4:

- **Payments / billing / Stripe integration.** Handle design partners by invoice if anyone wants to pay.
- **Teams, seats, roles.** Solo users only. Everything is scoped to one `user_id`.
- **Google Ads, TikTok Ads, LinkedIn Ads.** Adding channels doubles the data model; each channel has its own API quirks.
- **Automated rules engine** ("if CPA > X, pause automatically"). Revealbot's product. Stay in the diagnose-and-recommend lane; automation is a wedge for v2.
- **White-labeling / agency dashboards.** Not your target user.
- **Creative generation (AI-produced ad images/copy).** Separate product with separate risks.
- **Real-time (<5 min) ingestion.** The data isn't there — Meta's own delay makes this meaningless.
- **Mobile app.** LiveView works passably on mobile web; native can wait.
- **Audit log / compliance dashboard.** `actions_log` exists internally; no user-facing surface until an enterprise buyer asks.
- **Multi-language UI.** English only.
- **Custom dashboards / drag-drop reporting.** The opinionated view is the product.

## Cross-cutting risks

**Meta App Review is the critical path.** Start week 1. Use Development mode for all internal testing. Budget 4–8 weeks of calendar time even if active work is ~2 weeks. If review rejects, your v0.4 launch slips — mitigation is to start early and respond to reviewer feedback within 24 hours.

**Data accuracy > feature breadth.** A single "CTR is wrong" bug kills trust faster than any missing feature. Have a reconciliation job (weekly) that cross-checks totals against Meta's own reports.

**LLM cost runaway.** Users can burn $20 of tokens in a bad afternoon. Quotas are not optional. Default hard limit for MVP: $5/user/day worth of tokens, bumpable per account.

**Tokens leak from logs / error reports.** Meta access tokens in a Sentry breadcrumb is a security incident. Redaction helpers in the logger from day one.

**Solo-founder bus factor.** The architecture uses five non-trivial systems (Phoenix, Broadway, RabbitMQ, Oban, Timescale, Jido). Keep docs in `adflux-plan/` updated as decisions change; future-you (or a teammate) will need them.

## Decision log template

Throughout v0.1–v0.4, log every non-trivial decision in `adflux-plan/decisions/NNNN-title.md`:

```
# DNNNN: <title>
Date: YYYY-MM-DD
Status: proposed | accepted | superseded by DMMMM

## Context
## Decision
## Consequences
## Alternatives considered
```

Low friction, pays back hugely when you're trying to remember why you chose Timescale over partitioned Postgres in month 6.
