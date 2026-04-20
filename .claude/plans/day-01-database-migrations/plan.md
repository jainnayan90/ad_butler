# Day 1: Database Schema Migrations

**Feature:** Create all core Postgres tables for the AdButler v0.1 foundation.  
**Branch:** `day-01-database-migrations`  
**Sprint ref:** `docs/plan/sprint_plan/plan-adButlerV01Foundation.prompt.md` — Day 1 section  
**Depth:** Standard

---

## Context

Fresh Phoenix app — no migrations exist yet. The database needs 10 tables before any context module (Day 2+) can be written. The sprint plan contains exact column specs; this plan converts them into ordered, reversible migration files.

Key constraints:
- UUID primary keys everywhere (`binary_id`, `gen_random_uuid()`)
- `utc_datetime_usec` timestamps throughout
- `meta_connections.access_token` is `:binary` — encrypted at rest by Cloak (Day 2); the migration just stores bytes
- `ads.creative_id` uses `on_delete: :nilify_all` (all other FKs use `:delete_all`)
- `insights_daily`, `findings`, `ad_health_scores`, `embeddings` etc. are **not** in scope for Day 1

---

## Migration Order (FK dependency chain)

```
users
  └─ meta_connections
       └─ ad_accounts
            ├─ creatives          ← must precede ads
            ├─ campaigns
            │    └─ ad_sets
            │         └─ ads ──── (also refs creatives, ad_accounts)
  └─ llm_usage
  └─ user_quotas
llm_pricing  (no deps)
```

---

## Phase 1 — Core Ad Hierarchy Migrations

- [x] [ecto] Generate migration `create_users` — UUID PK, email unique index, meta_user_id index
  - UUID PK with `gen_random_uuid()` default
  - `email :string, null: false`
  - `meta_user_id :string`
  - `name :string`
  - `timestamps(type: :utc_datetime_usec)`
  - `unique_index(:users, [:email])`
  - `index(:users, [:meta_user_id])`

- [x] [ecto] Generate migration `create_meta_connections` — access_token :binary, scopes array, unique (user_id, meta_user_id)
  - UUID PK
  - `user_id references(:users, type: :uuid, on_delete: :delete_all), null: false`
  - `meta_user_id :string, null: false`
  - `access_token :binary, null: false`
  - `token_expires_at :utc_datetime_usec, null: false`
  - `scopes {:array, :string}, null: false, default: []`
  - `status :string, default: "active"`
  - `timestamps(type: :utc_datetime_usec)`
  - `index(:meta_connections, [:user_id])`
  - `unique_index(:meta_connections, [:user_id, :meta_user_id])`

- [x] [ecto] Generate migration `create_ad_accounts` — raw_jsonb, unique (meta_connection_id, meta_id)
  - UUID PK
  - `meta_connection_id references(:meta_connections, type: :uuid, on_delete: :delete_all)`
  - `meta_id :string, null: false`
  - `name :string, null: false`
  - `currency :string, null: false`
  - `timezone_name :string, null: false`
  - `status :string, null: false`
  - `last_synced_at :utc_datetime_usec`
  - `raw_jsonb :jsonb, default: "{}"`
  - `timestamps(type: :utc_datetime_usec)`
  - `index(:ad_accounts, [:meta_connection_id])`
  - `unique_index(:ad_accounts, [:meta_connection_id, :meta_id])`

- [x] [ecto] Generate migration `create_creatives` (**before ads**) — asset_specs_jsonb, unique (ad_account_id, meta_id)
  - UUID PK
  - `ad_account_id references(:ad_accounts, type: :uuid, on_delete: :delete_all)`
  - `meta_id :string, null: false`
  - `name :string`
  - `asset_specs_jsonb :jsonb, default: "{}"`
  - `raw_jsonb :jsonb, default: "{}"`
  - `timestamps(type: :utc_datetime_usec)`
  - `index(:creatives, [:ad_account_id])`
  - `unique_index(:creatives, [:ad_account_id, :meta_id])`

- [x] [ecto] Generate migration `create_campaigns` — budget_cents bigint, unique (ad_account_id, meta_id)
  - UUID PK
  - `ad_account_id references(:ad_accounts, type: :uuid, on_delete: :delete_all)`
  - `meta_id :string, null: false`
  - `name :string, null: false`
  - `status :string, null: false`
  - `objective :string, null: false`
  - `daily_budget_cents :bigint`
  - `lifetime_budget_cents :bigint`
  - `raw_jsonb :jsonb, default: "{}"`
  - `timestamps(type: :utc_datetime_usec)`
  - `index(:campaigns, [:ad_account_id])`
  - `unique_index(:campaigns, [:ad_account_id, :meta_id])`

- [x] [ecto] Generate migration `create_ad_sets` — refs campaigns + ad_accounts, targeting_jsonb
  - UUID PK
  - `ad_account_id references(:ad_accounts, type: :uuid, on_delete: :delete_all)`
  - `campaign_id references(:campaigns, type: :uuid, on_delete: :delete_all)`
  - `meta_id :string, null: false`
  - `name :string, null: false`
  - `status :string, null: false`
  - `daily_budget_cents :bigint`
  - `lifetime_budget_cents :bigint`
  - `bid_amount_cents :bigint`
  - `targeting_jsonb :jsonb, default: "{}"`
  - `raw_jsonb :jsonb, default: "{}"`
  - `timestamps(type: :utc_datetime_usec)`
  - `index(:ad_sets, [:ad_account_id])`
  - `index(:ad_sets, [:campaign_id])`
  - `unique_index(:ad_sets, [:ad_account_id, :meta_id])`

- [x] [ecto] Generate migration `create_ads` — creative_id uses :nilify_all (ON DELETE SET NULL)
  - UUID PK
  - `ad_account_id references(:ad_accounts, type: :uuid, on_delete: :delete_all)`
  - `ad_set_id references(:ad_sets, type: :uuid, on_delete: :delete_all)`
  - `creative_id references(:creatives, type: :uuid, on_delete: :nilify_all)` ← nilify, not delete
  - `meta_id :string, null: false`
  - `name :string, null: false`
  - `status :string, null: false`
  - `raw_jsonb :jsonb, default: "{}"`
  - `timestamps(type: :utc_datetime_usec)`
  - `index(:ads, [:ad_account_id])`
  - `index(:ads, [:ad_set_id])`
  - `index(:ads, [:creative_id])`
  - `unique_index(:ads, [:ad_account_id, :meta_id])`

---

## Phase 2 — LLM Cost Tracking Tables

- [x] [ecto] Generate migration `create_llm_usage` — append-only, inserted_at only (no updated_at), indexes on user_id+inserted_at, conversation_id
  - UUID PK
  - `user_id references(:users, type: :uuid, on_delete: :delete_all)`
  - `conversation_id :uuid`
  - `turn_id :uuid`
  - `purpose :string, null: false`
  - `provider :string, null: false`
  - `model :string, null: false`
  - `input_tokens :integer, null: false, default: 0`
  - `output_tokens :integer, null: false, default: 0`
  - `cached_tokens :integer, null: false, default: 0`
  - `cost_cents_input :integer, null: false, default: 0`
  - `cost_cents_output :integer, null: false, default: 0`
  - `cost_cents_total :integer, null: false, default: 0`
  - `latency_ms :integer`
  - `status :string, null: false`
  - `request_id :string`
  - `metadata :jsonb, default: "{}"`
  - `inserted_at :utc_datetime_usec, null: false, default: fragment("now()")` — no `updated_at`
  - `index(:llm_usage, [:user_id, :inserted_at])`
  - `index(:llm_usage, [:inserted_at])`
  - `index(:llm_usage, [:conversation_id])`

- [x] [ecto] Generate migration `create_llm_pricing` — decimal(10,6) pricing cols, unique (provider, model, effective_from)
  - UUID PK
  - `provider :string, null: false`
  - `model :string, null: false`
  - `cents_per_1k_input :decimal, precision: 10, scale: 6, null: false`
  - `cents_per_1k_output :decimal, precision: 10, scale: 6, null: false`
  - `cents_per_1k_cached_input :decimal, precision: 10, scale: 6`
  - `effective_from :utc_datetime_usec, null: false`
  - `effective_to :utc_datetime_usec`
  - `timestamps(type: :utc_datetime_usec)`
  - `unique_index(:llm_pricing, [:provider, :model, :effective_from])`
  - `index(:llm_pricing, [:effective_from])`

- [x] [ecto] Generate migration `create_user_quotas` — user_id as PK (no surrogate id), primary_key: false table
  - Composite PK: `user_id` is the primary key (no separate `id` column)
  - `user_id references(:users, type: :uuid, on_delete: :delete_all), primary_key: true`
  - `daily_cost_cents_limit :integer, default: 500`
  - `daily_cost_cents_soft :integer, default: 300`
  - `monthly_cost_cents_limit :integer, default: 10_000`
  - `tier :string, default: "free"`
  - `cutoff_until :utc_datetime_usec`
  - `note :text`
  - `timestamps(type: :utc_datetime_usec)`

---

## Phase 3 — Verification

- [x] Run `mix ecto.migrate` — succeeded, all 10 migrations ran
- [x] Run `mix ecto.rollback --all` then `mix ecto.migrate` — round-trip clean
- [x] Run `mix format` — no changes needed
- [x] Run `mix compile --warnings-as-errors` — no warnings
- [x] Inspect schema: `mix ecto.dump` — all tables, PKs, FKs, indexes confirmed correct
- [x] Constraint smoke test (psql) — all 4 cases rejected correctly:
  - Duplicate email insert → should reject (unique)
  - Null email insert → should reject (null constraint)
  - Orphaned meta_connection insert → should reject (FK)
  - Duplicate `(ad_account_id, meta_id)` in campaigns → should reject (unique)

---

## Risks

1. **`ads` ↔ `creatives` ordering** — `ads` references `creatives`; if migrations run out of order this fails. Mitigation: generate creatives migration (timestamp) *before* ads, verified in the dependency chain above.

2. **`user_quotas` has no surrogate PK** — uses `user_id` directly as primary key. This means `create table(:user_quotas, primary_key: false)` with `add :user_id, ..., primary_key: true`. This deviates from the Ecto default; verify schema inspection shows correct PK.

3. **`llm_usage` has no `updated_at`** — append-only ledger. Use `add :inserted_at, ..., default: fragment("now()")` manually; do NOT use `timestamps()` macro (which would add both). This is intentional per spec.

4. **JSONB default is `"{}"` (string)** — `fragment/1` is not needed; Postgres accepts the string literal. Confirmed correct for Ecto's `add :col, :jsonb, default: "{}"`.

---

## Scratchpad

- No Ecto schemas are written in Day 1 — migrations only. Schemas come Day 2.
- `mix phx.gen.schema` is intentionally NOT used here — it would generate schema files we don't want yet, and force us to roll back generated code. Use `mix ecto.gen.migration` directly.
- Tidewave not available yet (no schema to inspect). Verification is purely via `mix ecto.*` commands and psql.
