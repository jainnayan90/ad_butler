# Review: day-01-database-migrations

**Verdict: REQUIRES CHANGES**
**Date:** 2026-04-20
**Files reviewed:** 10 migration files in `priv/repo/migrations/`

---

## Blocker / Critical

### B1. Missing `null: false` on tenant-scope FK columns (8 columns, 6 migrations)

`references/2` does not imply non-null. Every FK listed is currently nullable at the DB level, allowing orphaned rows and fail-open authorization checks.

| Migration | Column | Risk |
|-----------|--------|------|
| `create_ad_accounts.exs:9` | `meta_connection_id` | orphaned account |
| `create_creatives.exs:7` | `ad_account_id` | scope escape |
| `create_campaigns.exs:7` | `ad_account_id` | scope escape |
| `create_ad_sets.exs:7` | `ad_account_id` | scope escape |
| `create_ad_sets.exs:8` | `campaign_id` | scope escape |
| `create_ads.exs:7` | `ad_account_id` | scope escape |
| `create_ads.exs:8` | `ad_set_id` | scope escape |
| `create_llm_usage.exs:7` | `user_id` | unbillable rows |

`ads.creative_id` is intentionally nullable (nilify_all). `meta_connections.user_id` already correct.

```elixir
# Fix: add null: false to every required FK
add :ad_account_id, references(:ad_accounts, type: :binary_id, on_delete: :delete_all), null: false
```

---

## High Severity

### H1. `user_quotas` limit columns missing `null: false` — fail-open quota enforcement

`daily_cost_cents_limit`, `daily_cost_cents_soft`, `monthly_cost_cents_limit`, `tier` have defaults but no `null: false`. A NULL limit typically becomes "no limit" in application code, enabling unlimited LLM spend.

**File:** `create_user_quotas.exs:10-13`

```elixir
# Add null: false + consider CHECK constraints
add :daily_cost_cents_limit, :integer, null: false, default: 500
add :tier, :string, null: false, default: "free"

create constraint(:user_quotas, :soft_le_hard,
  check: "daily_cost_cents_soft <= daily_cost_cents_limit")
create constraint(:user_quotas, :non_negative,
  check: "daily_cost_cents_limit >= 0 AND daily_cost_cents_soft >= 0 AND monthly_cost_cents_limit >= 0")
```

### H2. `meta_connections.status` nullable + unconstrained — revocation bypass risk

`status` has no `null: false` and no CHECK. A NULL status after a partial write could leave a revoked token active if application gates are `status == "active"`.

**File:** `create_meta_connections.exs:12`

```elixir
add :status, :string, null: false, default: "active"
create constraint(:meta_connections, :status_values,
  check: "status IN ('active','revoked','expired','error')")
```

---

## Warnings

### W1. `llm_usage.user_id` — `on_delete: :delete_all` destroys financial audit trail

A GDPR erasure or user deletion wipes billing history. For a cost ledger this is almost certainly wrong (tax, fraud review, quota reconciliation). Needs an explicit product decision.

**File:** `create_llm_usage.exs:7`

Options:
- `on_delete: :restrict` + separate anonymization job (recommended)
- `on_delete: :nilify_all` + make `user_id` nullable (loses attribution)
- Keep `:delete_all` if full wipe is a confirmed product/legal requirement

### W2. `user_quotas` uses `:integer` for cent limits; rest of schema uses `:bigint`

`campaigns.daily_budget_cents` and `ad_sets.daily_budget_cents` are `:bigint`. Using `:integer` (int4) for quota limits risks overflow at high spend levels.

**File:** `create_user_quotas.exs:10-12`

```elixir
add :daily_cost_cents_limit, :bigint, default: 500
add :daily_cost_cents_soft, :bigint, default: 300
add :monthly_cost_cents_limit, :bigint, default: 10_000
```

### W3. `users.email` — case-sensitive unique index (pre-auth risk)

`unique_index(:users, [:email])` permits `Alice@x.com` alongside `alice@x.com`. Add before public signup lands:

```elixir
execute "CREATE EXTENSION IF NOT EXISTS citext", "DROP EXTENSION IF EXISTS citext"
# change column type to :citext and remove separate unique_index
```
Or use a functional index: `create unique_index(:users, ["lower(email)"])`.

---

## Suggestions

### S1. `llm_usage` — BRIN index for monotonic `inserted_at`

Append-only table, rows inserted in time order. A BRIN index is far smaller than B-tree and handles range scans well:

```elixir
create index(:llm_usage, [:inserted_at], using: :brin)
```
The composite `[:user_id, :inserted_at]` should stay B-tree.

### S2. `llm_pricing` — add index on `effective_to`

Current-price queries (`WHERE effective_to IS NULL`) have no index support.

```elixir
create index(:llm_pricing, [:effective_to])
```

### S3. `llm_usage` + `llm_pricing` — add non-negative CHECK constraints

For a financial ledger, guard at the DB level:

```elixir
# llm_usage
create constraint(:llm_usage, :non_negative_tokens,
  check: "input_tokens >= 0 AND output_tokens >= 0 AND cached_tokens >= 0")
create constraint(:llm_usage, :non_negative_costs,
  check: "cost_cents_input >= 0 AND cost_cents_output >= 0 AND cost_cents_total >= 0")

# llm_pricing
create constraint(:llm_pricing, :non_negative_prices,
  check: "cents_per_1k_input >= 0 AND cents_per_1k_output >= 0")
create constraint(:llm_pricing, :effective_range,
  check: "effective_to IS NULL OR effective_to > effective_from")
```

### S4. Enumerated string columns — consider CHECK constraints

`campaigns.status`, `campaigns.objective`, `ad_sets.status`, `ads.status`, `llm_usage.status/purpose/provider` are unconstrained strings. Add CHECKs for each once the valid value sets are finalized (Day 2 context module work is the right time).

---

## Notes (Application Layer — Not DDL Bugs)

- **JSONB fields** (`raw_jsonb`, `targeting_jsonb`, `metadata`, `asset_specs_jsonb`): Store untrusted Meta API payloads verbatim. Day 2: never use `raw/1` on nested strings, never `String.to_atom/1` on keys, verify `:filter_parameters` redacts these fields in logs.
- **`ads.creative_id` nilify_all**: When a creative is deleted, the ad stays with NULL `creative_id`. Rendering path must handle NULL gracefully — flag for template layer review.
- **`access_token :binary`**: Correct staging for Cloak (Day 2). When Cloak lands, verify vault key is loaded via `System.fetch_env!/1` in `runtime.exs`, never compiled config.

---

## Confirmations (Passing)

- UUID PKs via `gen_random_uuid()` everywhere — no sequential ID enumeration ✅
- `meta_connections.token_expires_at` — present, `null: false`, `:utc_datetime_usec` ✅
- `access_token :binary` (not `:string`) — correct for encrypted-at-rest ✅
- No `:float` anywhere in cost/pricing fields ✅
- Composite unique indexes scope `meta_id` per parent correctly ✅
- `llm_usage` has no `updated_at` (append-only, `inserted_at` with `fragment("now()")`) ✅
- `user_quotas` has `user_id` as PK, no surrogate id (`primary_key: false`) ✅
- Rollback round-trip clean (all `change/0`, auto-reversible) ✅
- `mix compile --warnings-as-errors` + `mix format` + `mix test` all pass ✅
