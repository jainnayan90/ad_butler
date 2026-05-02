# Iron Law Violations — Pass 2 (W9 Triage Delta)

> **⚠️ EXTRACTED FROM AGENT MESSAGE** — Write denied to agent; orchestrator captured chat output verbatim.

## Summary

- Files scanned: 4 (ads.ex, analytics.ex, chat/server.ex, chat/tools/compare_creatives.ex)
- Iron Laws checked: 5 spot-checks
- Violations found: 1 BLOCKER, 1 PRE-EXISTING (unchanged)

---

## Critical Violations (BLOCKER)

### [N+1] CompareCreatives per-ad `fetch_ad` loop

- **File**: `lib/ad_butler/chat/tools/compare_creatives.ex:37`
- **Code**: `Enum.map(&Ads.fetch_ad(user, &1))` — up to 5 sequential `Repo.get` calls, each internally re-running `Accounts.list_meta_connection_ids_for_user(user)`
- **Confidence**: DEFINITE
- **Upgrade rationale**: `Ads.filter_owned_ad_ids/2` now exists and performs a single scoped query for the ownership check. The loop performs up to 5×2 queries (5 `fetch_ad` calls × 1 `list_meta_connection_ids_for_user` each). The W2 bulk helper makes this indefensible. The caller needs full `Ad` structs (id + name), which `filter_owned_ad_ids` doesn't return (ids only), but the fix is straightforward.
- **Fix**: Add `Ads.fetch_ads(user, ad_ids)` — a single `Ad |> scope(mc_ids) |> where([a], a.id in ^ids) |> Repo.all()` call — and replace the `Enum.map(&fetch_ad(...))` loop in `compare_creatives.ex`.

---

## Spot-Check Results (all PASS)

1. **Repo isolation** — `filter_owned_ad_ids/2` lives inside the Ads context. `Analytics.get_ads_delivery_summary_bulk/3` delegates ownership to `Ads.filter_owned_ad_ids/2` rather than querying Ad schemas directly. PASS.

2. **Tenant scoping** — UUID pre-filter runs before `list_meta_connection_ids_for_user/1` (correct early-exit). For any valid UUID, `scope(mc_ids)` join still runs. Tenant isolation intact. PASS.

3. **Structured logging** — `normalise_params/1` logs `unknown_keys` once after the reduce. `:unknown_keys` is in the `config/config.exs` Logger allowlist. PASS.

4. **No swallowed errors** — `filter_owned_ad_ids/2` has no `rescue` around `Repo.all`. DBConnection errors propagate. PASS.

5. **Context boundary (`AdHealthScore` alias in CompareCreatives)** — The alias is used only for read-only struct pattern matching on a value `Analytics` already returned. No constructors or queries are called against `AdHealthScore` from the Chat layer. Acceptable; not a boundary violation. PASS.

---

## Pre-Existing (Outside W9 Diff — No Change Required)

- **File**: `lib/ad_butler/ads.ex:904` — `Logger.error("bulk_upsert_insights failed: #{Exception.message(e)}", ...)` — string interpolation in message string. Pre-existing, carry-forward from prior audit.
