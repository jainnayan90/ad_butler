# Triage: audit-2026-04-29-perf-arch

**Date**: 2026-04-29
**Source review**: `.claude/plans/audit-2026-04-29-perf-arch/reviews/perf-arch-review.md`
**Decision**: Fix all BLOCKERs + WARNINGs + all SUGGESTIONs

---

## Fix Queue

- [ ] [BLOCKER] Add unit tests for `Analytics.bulk_insert_health_scores/1`
  - File: `test/ad_butler/analytics_test.exs`
  - Cases: empty list → `:ok`; single entry inserts row; same `(ad_id, computed_at)` upserts on conflict

- [ ] [BLOCKER] Add unit tests for `Analytics.list_open_finding_keys/1`
  - File: `test/ad_butler/analytics_test.exs`
  - Cases: `[]` → `MapSet.new()`; open findings return `{ad_id, kind}` tuples; resolved findings excluded

- [ ] [WARNING] Log the insert count in `bulk_insert_health_scores/1`
  - File: `lib/ad_butler/analytics.ex:153`
  - Bind `{count, _} = Repo.insert_all(...)` and warn when count == 0 with entries non-empty

- [ ] [WARNING] Fix `apply_check/5` semantics — rename `fired_kinds` or exclude `:skipped`
  - File: `lib/ad_butler/workers/budget_leak_auditor_worker.ex:148`
  - `:skipped` results should not be in `fired_kinds` if name implies "newly emitted"
  - Option: rename `fired_kinds` → `detected_kinds` with a comment, OR exclude `:skipped` from acc

- [ ] [WARNING] Fix `finding_factory` and `ad_health_score_factory` to use `insert(:ad)`
  - File: `test/support/factory.ex:94-113`
  - Change `build(:ad)` → `insert(:ad)` so FK fields point to real DB rows

- [ ] [WARNING] Add tests for `Ads.list_ad_account_ids_for_mc_ids/1`
  - File: `test/ad_butler/ads_test.exs`
  - Cases: `[]` returns `[]`; one MC's IDs returns only that MC's ad_account_ids

- [ ] [WARNING] Address `scope_findings/2` two-query overhead
  - File: `lib/ad_butler/analytics.ex:263`
  - Option: collapse into one query via subquery (preferred) or document the tradeoff

- [ ] [SUGGESTION] Rename `list_open_finding_keys/1` → `unsafe_list_open_finding_keys/1`
  - File: `lib/ad_butler/analytics.ex:118` + caller in `budget_leak_auditor_worker.ex`

- [ ] [SUGGESTION] Add `@doc` ownership warning to `upsert_ad_account/2`
  - File: `lib/ad_butler/ads.ex:165`
  - "Caller MUST verify meta_connection_id ownership. Never call from controller/LiveView with user-supplied UUID."

- [ ] [SUGGESTION] Add comment explaining changeset bypass in worker bulk path
  - File: `lib/ad_butler/workers/budget_leak_auditor_worker.ex:93`
  - `# changeset validation intentionally skipped; score is capped 0..100 by compute_leak_score/1`

- [ ] [SUGGESTION] Fix `list_open_finding_keys` pipe style
  - File: `lib/ad_butler/analytics.ex:122`
  - `from(f in Finding, ...) |> Repo.all() |> MapSet.new()`

- [ ] [SUGGESTION] Remove `_ = mc` noise from 3 test heads
  - File: `test/ad_butler_web/live/findings_live_test.exs:61,89,179`

---

## Skipped

None.

## Deferred

- PRE-EXISTING: `FindingsLive` plain list assign (should be stream) — separate issue
- PRE-EXISTING: `FindingDetailLive` no explicit LiveView auth guard — separate issue
