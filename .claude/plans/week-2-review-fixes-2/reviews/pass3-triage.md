# Triage: week-2-review-fixes-2 (Pass 3)

**Date**: 2026-04-29
**Source**: pass3-review.md
**Fix queue**: 4 items · **Skipped**: 4

---

## Fix Queue

- [x] [B1] Replace `Oban.insert_all` with one-at-a-time `Oban.insert/2` in `AuditSchedulerWorker.perform/1` — Enum.flat_map + Oban.insert/2 per changeset; log message updated to "unique conflict"
- [x] [W1] Add `else {:error, reason} -> Logger.error(...)` clause to `with` in `audit_account/1` — failure now logged with ad_account_id + reason before propagating
- [x] [W2] Add migration to drop redundant plain index on `ad_health_scores(ad_id, computed_at)` — `20260429000001_drop_redundant_ad_health_scores_index.exs`
- [x] [W3] Add `@spec` to all 4 public functions in `FindingHelpers` — `@spec severity_badge_class(String.t()) :: String.t()` and `@spec kind_label(String.t()) :: String.t()`

---

## Skipped

- S1: `unsafe_get_latest_health_score/1` signature change — deferred
- S2: Add inline comment to `acknowledge` handler — deferred
- S3: Flatten nested `if` in `check_stalled_learning/5` — deferred
- S4: Informational insert_all return-type note — already documented in compound doc
