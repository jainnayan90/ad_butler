# Triage: week-2-review-fixes-2

**Date**: 2026-04-29
**Source**: week-2-review-fixes-2-review.md
**Fix queue**: 6 items · **Skipped**: 4

---

## Fix Queue

- [x] [B1] Fix `Oban.insert_all` failure filter — replaced dead `match?({:error,_})` with deduplication count (`length(valid) - length(results)`); logs skipped count
- [x] [W1] Fix `keys: []` → `fields: [:queue, :worker]` and update comment — intent now explicit and robust to future args changes
- [x] [W2] Fix `check_bot_traffic` float division — `total_clicks * 100 > total_impressions * 5` and `total_conversions * 1000 < total_clicks * 3`; Float.round kept for display in evidence map
- [x] [W3] Fix `async: false` comment in both worker test files — updated to "shared insights_daily partitions and ad_insights_30d mat-view; concurrent processes would see each other's seeded rows and could deadlock on mat-view refresh"
- [x] [W4] N/A — `Ads.list_ad_accounts/1` already has `limit(200)` at source
- [x] [W5] Guard `get_finding/2` against malformed UUID — rescue `Ecto.Query.CastError` → `{:error, :not_found}`; added malformed UUID test case

---

## Skipped

- S1: Health score idempotency test wall-clock boundary risk — low-probability flake, accepted
- S2: `acknowledge_finding/2` missing nonexistent-ID test — covered transitively
- S3: `unsafe_get_latest_health_score/1` scoped helper — deferred, doc invariant sufficient for now
- S4: Verify `unique_constraint` in Finding changeset — deferred, investigate separately
