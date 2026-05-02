# Iron Law Violations Report — W9 Final Triage Fixes (iron-law-judge, post-fix pass)

> **⚠️ EXTRACTED FROM AGENT MESSAGE** — Write denied to agent; orchestrator captured chat output verbatim.

**Files scanned:** `analytics.ex`, `ads.ex`, `chat/server.ex`, `chat/tools/compare_creatives.ex`, `chat/tools/get_ad_health.ex`
**Violations found:** 2 (0 critical, 2 high/WARNING)
**Prior BLOCKER resolved:** `Jason.encode!` → safe `Jason.encode/1` case is in place at `get_ad_health.ex:93`.

---

## High Violations (WARNING)

### [WARNING] N+1 — CompareCreatives per-ad `fetch_ad/2` loop

- **File**: `lib/ad_butler/chat/tools/compare_creatives.ex:36`
- **Code**: `Enum.map(&Ads.fetch_ad(user, &1))` — up to 5 individual scoped DB queries (each a `JOIN ads → ad_accounts WHERE meta_connection_id IN (...)`)
- **Confidence**: LIKELY
- **Context**: `Analytics.get_ads_delivery_summary_bulk/3` correctly eliminates the per-ad analytics N+1 (the stated W9 goal), but the upstream ownership loop is still per-id. `Ads.filter_owned_ad_ids/2` was added in this same W9 pass and performs the identical ownership check in one query — it just returns IDs. A `list_owned_ads/2` that returns structs instead of IDs would collapse the loop to one query.
- **Fix**: Add `Ads.list_owned_ads(user, ad_ids) :: [Ad.t()]` — same body as `filter_owned_ad_ids/2` but `select([a], a)` — and replace the `Enum.map(&fetch_ad(...))` loop in `compare_creatives.ex`.

### [WARNING] Structured logging — `bulk_upsert_insights` interpolates into message string [PRE-EXISTING]

- **File**: `lib/ad_butler/ads.ex:890`
- **Code**: `Logger.error("bulk_upsert_insights failed: #{Exception.message(e)}", reason: Exception.message(e))`
- **Confidence**: DEFINITE
- **Context**: CLAUDE.md prohibits string interpolation in log messages. The error text is correctly passed as `:reason` metadata but also embedded via `#{}` in the message string, duplicating it and defeating structured aggregation.
- **Fix**: `Logger.error("bulk_upsert_insights failed", reason: Exception.message(e))`
- **NOTE**: Line 890 is OUTSIDE the W9 final diff (changes are around lines 149, 414, 521). Verified via `git diff HEAD -- lib/ad_butler/ads.ex` hunks. Tag as PRE-EXISTING.

---

## Clean (W9 diff)

- **Analytics → Ads schema boundary**: PASS — `analytics.ex` aliases only `Analytics.*` schemas; ownership fully delegated to `Ads.filter_owned_ad_ids/2`, no `Ad`/`AdAccount` schema aliased in Analytics.
- **`filter_owned_ad_ids/2` tenant scope**: PASS — routes through `Accounts.list_meta_connection_ids_for_user` → `scope/2` join.
- **No scope duplication**: PASS — `scope_findings/2` delegates to `Ads.list_ad_account_ids_for_user/1`, not a reimplementation.
- **`normalise_params/1`**: PASS — uses `String.to_existing_atom/1` (safe), structured `unknown_keys:` metadata; key is in the Logger allowlist at `config/config.exs:119`.
- **`truncate/2` visibility change**: PASS — `@doc false` is the correct marker for test-only public helpers per CLAUDE.md.
- **SQL identifier interpolation in `create_future_partitions/0`**: PASS — `safe_identifier!` validates against `~r/\A[a-zA-Z0-9_]+\z/` before use; dates come from `Date.to_iso8601` (safe).
