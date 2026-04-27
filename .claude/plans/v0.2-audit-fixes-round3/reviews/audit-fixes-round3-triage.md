# Triage — Audit Fixes Round 3

**Date:** 2026-04-27
**Source:** audit-fixes-round3-review.md

---

## Fix Queue

- [x] [B1] Fix inverted shell logic in check.unsafe_callers — mix.exs:108 — `! grep ... || (echo && exit 1)`
- [x] [B2] Limit check.unsafe_callers scan to `lib/ad_butler_web` only — remove sync/workers from grep paths
- [x] [W1] Narrow bulk_upsert_insights rescue to Postgrex.Error — ads.ex:599
- [x] [W2] Replace `meta_id_map[row.ad_id]` with `Map.fetch!` in normalise_row — insights_pipeline.ex:167
- [x] [W3] Log dropped encode count when non-zero in both workers collect_payloads
- [x] [W4] Rename get_ad_meta_id_map/1 to unsafe_get_ad_meta_id_map/1 — ads.ex:134 (pre-existing, now fixing for naming consistency)
- [x] [W5] Verify/document Postgres session timeout config relative to 5-min transaction timeout (note only — no code change)

---

## Skipped

None.

---

## Deferred

None.
