# D0001: Skip Postgres RLS for MVP; enforce tenant isolation at the Ecto query layer

Date: 2026-04-20
Status: accepted

## Context

The product has one tenant boundary — the user. Every user owns one or more Meta ad connections; each connection owns one or more ad accounts; every downstream row (campaign, ad set, ad, creative, insight, finding, ad_health_score, chat_message, llm_usage) traces back to a `user_id` through that chain.

Two plausible ways to enforce isolation:

1. **Postgres Row-Level Security (RLS)** — policies on every tenant-owned table, session variables set per request/job, a "service" role that bypasses RLS for bulk sync writes.
2. **Application-layer scoping** — every query goes through a context function that joins back to `user_id` via the association chain.

## Decision

Use application-layer scoping for MVP. Codify it in week one of v0.1:

- One `scope/2` helper per tenant-owned context (`Ads`, `Analytics`, `Chat`, `Billing`) that takes a query and a `%User{}` and adds the join-and-where to `meta_connections.user_id`.
- No direct `Repo` calls outside of context modules. Enforced by code review and (optionally) a Credo or Sobelow custom rule.
- Jido chat tools take a `session_context` struct with `user_id` and `ad_account_id`; every tool re-scopes its reads against that struct. An LLM hallucinating an `ad_id` from another tenant resolves to `{:error, :not_found}`, not a leak.
- Encrypted token storage on `meta_connections.access_token` via `Cloak.Ecto` provides an extra layer of protection for the most sensitive column regardless of RLS status.

## Consequences

- **Simpler Ecto code and migrations.** No connection-level session variable plumbing, no policy DDL, no RLS-aware Repo wrappers.
- **Broadway and Oban jobs stay straightforward.** Bulk inserts to `insights_daily` don't need a "service" role or policy exception — they're already naturally scoped by `ad_account_id`, and app code governs who reads them.
- **Tenant isolation is a code discipline, not a database guarantee.** A missing `scope/2` call in a context function = potential leak. Mitigation: centralize `Repo` access in contexts; code review rule; add a Credo/Sobelow check before v0.4.
- **Future compliance work may require revisiting.** SOC2 auditors often want database-level controls; adding RLS later is mechanical but not free.

## When to revisit (triggers)

Any of these flips the decision:

1. A user-facing SQL / custom reporting surface ships.
2. A second service starts hitting the same Postgres (data-science job, Retool, Grafana direct connection, BI tool).
3. Compliance (SOC2, HIPAA, enterprise contract) demands database-level controls.
4. Team/organization accounts ship and the tenant boundary becomes `organization_id` instead of `user_id`.
5. An incident occurs — a shipped feature is missing a scoping call.

Any trigger opens a new decision record (D00NN) that either (a) adopts RLS across the board, or (b) adopts RLS only on the most sensitive tables (`meta_connections`, `chat_messages`, `llm_usage`).

## Alternatives considered

- **Full RLS from day one.** Rejected for MVP. Friction on Broadway bulk upserts, connection-checkout discipline, Ecto preload/join surprises, and zero marginal safety for a single-app single-DB setup.
- **Partial RLS on sensitive tables only** (`meta_connections`, `chat_messages`). Plausible middle ground but deferred — adds operational complexity without a current forcing function. Revisit alongside any trigger above.
- **Postgres schemas per tenant.** Rejected. Doesn't fit the shape (too many tenants, solo users each with modest data volume) and creates migration pain at scale.
