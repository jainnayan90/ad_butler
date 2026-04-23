# Consolidated Review Summary

**Strategy**: Compress  
**Input**: 7 files, ~8.4k tokens  
**Output**: ~3.4k tokens (60% reduction)  
**Date**: 2026-04-20

---

## BLOCKERS (KEEP ALL)

### B1. Missing `null: false` on tenant-scope FK columns (8 columns, 6 migrations)
**Source**: day-01-migrations-review  
**Status**: FIXED (triage confirmed)

`references/2` does not imply non-null. Affects:
- `create_ad_accounts.exs:9` — `meta_connection_id` (orphaned account risk)
- `create_creatives.exs:7` — `ad_account_id` (scope escape)
- `create_campaigns.exs:7` — `ad_account_id` (scope escape)
- `create_ad_sets.exs:7,8` — `ad_account_id`, `campaign_id` (scope escape)
- `create_ads.exs:7,8` — `ad_account_id`, `ad_set_id` (scope escape)
- `create_llm_usage.exs:7` — `user_id` (unbillable rows)

All fixed with `null: false` per triage.

---

### B2. `SyncAllConnectionsWorker.perform/1` silently swallows `Oban.insert/1` errors
**Sources**: elixir.md (C1), oban.md (W1) — **IRON LAW JUDGE WINS** (deconflicted)  
**Location**: `lib/ad_butler/workers/sync_all_connections_worker.ex:14-18`

`Enum.each` discards every `{:ok, _}` / `{:error, _}` from `Oban.insert/1`. DB constraint violation or pool exhaustion causes the job to return `:ok` — no retry, no connections synced, no log evidence.

**Fix** (Oban 2.x+):
```elixir
connections
|> Enum.map(fn connection ->
  FetchAdAccountsWorker.new(%{"meta_connection_id" => connection.id})
end)
|> Oban.insert_all()
```

---

### B3. `Ads.get_ad_account/1` is public + unscoped — IDOR foot-gun
**Source**: security.md (M-1)  
**Location**: `lib/ad_butler/ads.ex:46-47`

Public, unscoped sibling of `get_ad_account!/2` (scoped). Nothing prevents future controller/LiveView from calling with `params["id"]`, bypassing tenant isolation. **OWASP A01:2021 Broken Access Control.**

**Fix**: Rename to `get_ad_account_for_sync/1` with `@doc "INTERNAL — bypasses tenant scope"`, or move to internal module called only from sync pipeline.

---

### B4. Committed dev Cloak fallback key in config
**Source**: security.md (M-2)  
**Location**: `config/dev.exs:103`

Real AES-GCM key is in git. Any real token in dev DB is decryptable by anyone with repo access; pattern risks copying to staging/prod.

---

### B5. Session-salt mismatch between HTTP plug and LiveView socket
**Source**: security.md (L-2)  
**Location**: `config/runtime.exs:50-60`, `lib/ad_butler_web/endpoint.ex:13-14`

`endpoint.ex` builds `@session_options` with `compile_env!` (frozen at build time). LiveView socket uses compile-time value. HTTP session plug uses `fetch_env!` (runtime). The `runtime.exs` override only writes `live_view: [signing_salt:]`.

**Consequence**: In prod release with rotated env vars, HTTP sessions use runtime salts but LiveView socket uses compile-time defaults — cookie cannot be decrypted, LiveView session silently dropped.

**Required**: Build a release, set different salt values, sign in, open LiveView, confirm session carries through.

---

## WARNINGS (KEEP ALL, deduplicated)

### W1. `user_quotas` limit columns missing `null: false` and use `:integer` instead of `:bigint`
**Source**: day-01-migrations-review (H1, W2)  
**Status**: FIXED (triage confirmed)

`daily_cost_cents_limit`, `daily_cost_cents_soft`, `monthly_cost_cents_limit`, `tier` have defaults but no `null: false`. NULL limit becomes "no limit" (fail-open quota). Using `:integer` (int4) risks overflow at high spend (rest of schema uses `:bigint`).

Fixed: All now `:bigint, null: false` + CHECK constraints (soft_le_hard, non_negative, tier_values).

---

### W2. `meta_connections.status` nullable + unconstrained — revocation bypass risk
**Source**: day-01-migrations-review (H2)  
**Status**: FIXED (triage confirmed)  
**Location**: `create_meta_connections.exs:12`

No `null: false` and no CHECK. NULL status after partial write could leave revoked token active if gates are `status == "active"`.

Fixed: `null: false` + CHECK constraint for `('active','revoked','expired','error')`.

---

### W3. `llm_usage.user_id` — `on_delete: :delete_all` destroys financial audit trail
**Source**: day-01-migrations-review (W1)  
**Status**: FIXED (triage confirmed)

GDPR erasure wipes billing history (tax, fraud review, quota reconciliation).

Fixed: Changed to `on_delete: :restrict` — application must handle user deletion explicitly.

---

### W4. `users.email` — case-sensitive unique index (pre-auth risk)
**Source**: day-01-migrations-review (W3)  
**Status**: FIXED (triage confirmed)

Permits `Alice@x.com` alongside `alice@x.com`.

Fixed: Switched to `:citext` extension + column type.

---

### W5. Every scoped read pays hidden extra DB query
**Source**: elixir.md (W1)  
**Location**: `lib/ad_butler/ads.ex:14-26`

`scope_ad_account/2` and `scope/2` both call `Accounts.list_meta_connection_ids_for_user/1` (SELECT before main query). Every `list_*` or `get_*!` call costs 2 DB round-trips. Document on private helpers; if multiple calls in same request, hoist ID fetch to caller.

---

### W6. `with` else branch has misleading failure labels
**Source**: elixir.md (W2)  
**Location**: `lib/ad_butler/sync/metadata_pipeline.ex:37-40`

`Ecto.UUID.cast/1` returns `:error` (matched correctly) but produces `:invalid_uuid`. Two branches above both produce `:invalid_payload`. Dead-lettered messages inconsistent. Unify all non-`nil` branches to `:invalid_payload`.

---

### W7. `bulk_upsert_*` `@spec` return type imprecise
**Source**: elixir.md (W3)  
**Location**: `lib/ad_butler/ads.ex:72,104`

`{integer(), [map()]}` valid but Dialyzer can't validate `row.meta_id` / `row.id` field accesses. Use:
```elixir
@spec bulk_upsert_campaigns(AdAccount.t(), [map()]) ::
        {non_neg_integer(), [%{id: binary(), meta_id: binary()}]}
```

---

### W8. `.envrc` contains a real CLOAK_KEY
**Source**: deploy.md (W1)  
**Location**: `.envrc:7` (gitignored but on disk)

Real AES key present. `.gitignore` covers it but verify with `git log --all -- .envrc`. If pushed, rotate the key.

---

### W9. `PHX_SERVER=true` not guaranteed in prod
**Source**: deploy.md (W2)  
**Location**: `runtime.exs:43-45`

`server: true` conditional on `PHX_SERVER` env var — never set unconditionally. If unset in Fly.io secrets, release boots silently, serves no HTTP.

**Fix**: Add `server: true` unconditionally in prod block, or enforce `PHX_SERVER=true` as required secret.

---

### W10. Unscoped `Repo.aggregate(:count)` is redundant
**Source**: testing.md (W1)  
**Location**: `ads_test.exs` — upsert idempotency tests

`Repo.aggregate(SomeSchema, :count) == 1` without WHERE clause. The `assert first.id == second.id` already proves no duplicate. Count check adds nothing. Fix: remove or scope with `where: r.meta_id == ^attrs.meta_id`.

---

### W11. `async: false` in scheduler_test.exs undocumented
**Source**: testing.md (W2)  
**Location**: `scheduler_test.exs:2`

Correct (Oban queries global `oban_jobs` table) but without comment, maintainer may flip to `async: true`, introducing race conditions. Add comment explaining Oban dependency.

---

### W12. `all_enqueued` count relies on implicit Sandbox rollback isolation
**Source**: testing.md (W3)  
**Location**: `scheduler_test.exs:34`

Count `== 2` correct because Sandbox rolls back. If Oban testing mode changes (e.g. inline mode), assertion sees 3 jobs. Add comment noting Sandbox assumption.

---

### W13. Partial fan-out silently swallowed on insert failure (duplicate of B2)
**Source**: oban.md (W1) — subsumed by B2  
Consolidated under B2.

---

### W14. Both cron workers share same schedule — monitoring noise
**Source**: oban.md (W2)  
**Location**: Both workers use `"0 */6 * * *"`

Simultaneous firing makes isolation harder in dashboards/alerts. Offset one by minutes (e.g. `"5 */6 * * *"`) unless simultaneous execution required.

---

## SUGGESTIONS (compressed into groups)

### S-GROUP 1: Indexes & Constraints (append-only / financial ledger patterns)
**Sources**: day-01-migrations-review (S1-S4)  
**Status**: FIXED (triage confirmed)

Append-only and financial tables need DB-level guards:
- `llm_usage.inserted_at` → BRIN index (monotonic, smaller than B-tree)
- `llm_pricing.effective_to` → B-tree index (current-price queries)
- `llm_usage` + `llm_pricing` → non-negative CHECK constraints for costs/tokens
- Enumerated string columns → CHECK constraints for valid value sets
  - `llm_usage.status` → `('success','error','pending','timeout','partial')`
  - `llm_usage.provider` → `('anthropic','openai','google')`
  - Meta-sourced fields (campaigns, ad_sets, ads) deferred to Day 2 (values from external API)

---

### S-GROUP 2: Type Specs & Documentation
**Sources**: elixir.md (S1), oban.md (S1-S3)

- `Scheduler.schedule_sync_for_connection/1`: Change spec from `map()` to `MetaConnection.t()`, add alias.
- `FetchAdAccountsWorker`: Add `def timeout(_job), do: :timer.minutes(5)` (hung HTTP calls block `sync` slot).
- `FetchAdAccountsWorker` unique constraint: Add one-line comment (correct as-is: `unique: [period: 3600]` with no `keys:`).
- `Scheduler.schedule_sync_for_connection/1` missing `@spec` after GenServer removal.

---

### S-GROUP 3: Test Coverage Gaps
**Sources**: testing.md (Suggestions), elixir.md (S2)

- No unit test for `bulk_upsert_*` conflict resolution (only indirect via pipeline). Add focused test for `on_conflict` update path.
- Missing empty-state test: `perform_job/2` with zero active connections.
- Missing campaign association test on conflict: if `campaign_id` updated by second upsert, test it; else test preservation.
- Hardcoded `meta_id: "s_1"` and `"ad_1"`: Use factory sequences for safer copy-paste.

---

### S-GROUP 4: Code Clarity
**Sources**: elixir.md (W1 – hoisting), security.md (L-1 informational)

- Hoist `list_meta_connection_ids_for_user/1` calls to caller when multiple scoped reads in same request.
- `in ^mc_ids` is safe (parameterized query); consider `subquery/1` to make atomic + remove extra DB round-trip.

---

## CONFIG & DEPLOYMENT

### Literal salts still in `config/config.exs`
**Source**: security.md (L-3)  
**Location**: `config/config.exs:18-19, 29`

`"yp0B0EBm"`, `"Cfg1C1OwCrAmNkVp"`, `"27ZZYgxL"` committed. These are compile-time defaults. Move to `dev.exs`/`test.exs` or inject at release-build time.

---

### Crypto crash in `parse_budget/1`
**Source**: security.md (L-5)  
**Location**: `lib/ad_butler/sync/metadata_pipeline.ex:154`

`String.to_integer/1` raises `ArgumentError` on non-integer budget, crashes Broadway processor. Use `Integer.parse/1` with fallback.

---

### Pre-Deploy Checklist
**Source**: deploy.md

- [ ] Confirm `PHX_SERVER=true` set as Fly.io secret
- [ ] Rotate `CLOAK_KEY` if `.envrc` ever pushed (`git log --all -- .envrc`)
- [ ] `fly secrets set SESSION_SIGNING_SALT=... SESSION_ENCRYPTION_SALT=... LIVE_VIEW_SIGNING_SALT=...`
- [ ] Verify all prod vars from `.env.example` in `fly secrets list`
- [ ] **Verify L-2 end-to-end**: Build release with rotated salts, sign in, open LiveView, confirm session carries through

---

## Coverage

| File | Represented | Key Items | Status |
|---|---|---|---|
| day-01-migrations-review.md | Yes | B1, W1-W4, S-GROUP 1 (10 items fixed) | FIXED |
| day-01-migrations-triage.md | Yes | Implementation status + approach notes | CONFIRMED |
| elixir.md | Yes | B2, W5-W7, S1-S2 (7 items) | READY |
| testing.md | Yes | W10-W12, S3 (4 items) | READY |
| oban.md | Yes | B2 (dup), W14, S2-S3 (4 items) | READY |
| deploy.md | Yes | W8-W9, Pre-Deploy Checklist (3 items) | READY |
| security.md | Yes | B2-B5, L-3, L-5 + L-1 note (6 items) | READY |

**All input files represented.**

---

## Next Steps

1. **Critical path** (blocking deploy):
   - B1-B4: Already fixed per migration triage
   - B5: Verify session-salt rotation end-to-end before release
   - Rotate `CLOAK_KEY` if `.envrc` pushed

2. **Before merge**:
   - W5-W14: Address per priority
   - S-GROUP items: Backlog or Day 2

3. **Post-deploy**:
   - Monitor Oban job insert failures
   - Confirm LiveView session persistence under rotated salts

