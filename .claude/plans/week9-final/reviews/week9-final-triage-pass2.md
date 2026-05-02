# Triage: W9 Final — Pass 2

**Date**: 2026-05-02
**Source**: [week9-final-pass2-review.md](week9-final-pass2-review.md)
**Decision**: Fix W5 + S5 + S6 in this session. Pre-existing ads.ex:904 deferred.

---

## Fix Queue (3 items)

### W5 — CompareCreatives N+1 (Iron Law auto-approved)

- [x] **Add `Ads.fetch_ads/2` returning `[Ad.t()]`**
  File: [ads.ex](../../../lib/ad_butler/ads.ex) (new public fn near `fetch_ad/2` and `filter_owned_ad_ids/2`)
  Body: mirrors `filter_owned_ad_ids/2` but `select([a], a)` (returns full Ad structs).

- [x] **Replace `Enum.map(&Ads.fetch_ad(user, &1))` in CompareCreatives**
  File: [compare_creatives.ex:35-40](../../../lib/ad_butler/chat/tools/compare_creatives.ex#L35)
  Body: `case Ads.fetch_ads(user, capped) do [] -> {:error, :no_valid_ads}; ads -> ... end`. Drops the `flat_map` over fetch_ad results.

### S5 — Non-exhaustive `health_metric/2` heads

- [x] **Add catchall `%AdHealthScore{} = score, key` head**
  File: [compare_creatives.ex:79-85](../../../lib/ad_butler/chat/tools/compare_creatives.ex#L79)
  Body: `Logger.warning("chat: unknown health metric key", key: key, ad_id: score.ad_id)` then return `nil`. Add `:key` to Logger allowlist if missing.

### S6 — `bin_to_uuid` silent nil

- [x] **Add Logger.warning to catchall**
  File: [analytics.ex:377](../../../lib/ad_butler/analytics.ex#L377)
  Body: `defp bin_to_uuid(other) do; Logger.warning("analytics: unexpected ad_id shape", kind: kind_of(other)); nil; end`. Reuse existing `:kind` allowlist key.

---

## Skipped

(none — user approved everything they were asked about)

## Deferred / Out of scope

- **PRE-EXISTING** [ads.ex:904](../../../lib/ad_butler/ads.ex#L904) — `Logger.error("bulk_upsert_insights failed: #{Exception.message(e)}", reason: ...)` string interpolation. User chose to skip; track separately. Could fold into next pass when touching that area.

---

## Execution

User chose: **Fix in this session**. Proceeding with edits, then re-running the verification gate.
