# Triage: day-01-database-migrations
**Date:** 2026-04-20
**Source review:** `.claude/plans/review/reviews/day-01-migrations-review.md`

---

## Fix Queue (10 items)

- [x] [B1] Add `null: false` to 8 FK columns across 6 migrations — all 8 FK columns now NOT NULL
  - `create_ad_accounts.exs` — `meta_connection_id`
  - `create_creatives.exs` — `ad_account_id`
  - `create_campaigns.exs` — `ad_account_id`
  - `create_ad_sets.exs` — `ad_account_id`, `campaign_id`
  - `create_ads.exs` — `ad_account_id`, `ad_set_id`
  - `create_llm_usage.exs` — `user_id`

- [x] [H1] Add `null: false` to `user_quotas` limit/tier columns + CHECKs — bigint, soft_le_hard, non_negative, tier_values
  - `daily_cost_cents_limit`, `daily_cost_cents_soft`, `monthly_cost_cents_limit` → `:bigint, null: false`
  - `tier` → `null: false`

- [x] [H2] Add `null: false` to `meta_connections.status` + status_values CHECK — `('active','revoked','expired','error')`

- [x] [W1] Change `llm_usage.user_id` to `on_delete: :restrict` — done alongside B1 fix

- [x] [W2] Change `user_quotas` cent limit columns from `:integer` to `:bigint` — done alongside H1

- [x] [W3] Switch `users.email` to `citext` — `CREATE EXTENSION IF NOT EXISTS citext`, column now `:citext`

- [x] [S1] Add BRIN index on `llm_usage.inserted_at` — `using: :brin`

- [x] [S2] Add index on `llm_pricing.effective_to`

- [x] [S3] Add non-negative CHECK constraints to `llm_usage` and `llm_pricing`
  - `llm_usage`: non_negative_tokens, non_negative_costs
  - `llm_pricing`: non_negative_prices, effective_range

- [x] [S4] Add CHECK constraints for enumerated string columns
  - `meta_connections.status` (covered by H2)
  - `user_quotas.tier` (covered by H1)
  - `llm_usage.status` → `('success','error','pending','timeout','partial')`
  - `llm_usage.provider` → `('anthropic','openai','google')`
  - Note: Meta-sourced fields (campaigns.status/objective, ad_sets.status, ads.status, ad_accounts.status) deferred to Day 2 — values come from external API and are not yet defined

---

## Skipped
(none)

## Deferred
- S4 partial: Meta-API enum CHECKs (campaigns.status, campaigns.objective, ad_sets.status, ads.status, ad_accounts.status) — add in Day 2 context modules once valid values confirmed

---

## Approach Notes
- W1: `on_delete: :restrict` (application must handle user deletion explicitly)
- W3: `citext` extension (not functional index)
- All fixes applied directly to existing migration files (not yet committed)
