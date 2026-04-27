# Triage: audit-fixes-round2
**Date:** 2026-04-27
**Source review:** `.claude/plans/v0.2-audit-fixes-round2/reviews/audit-fixes-round2-review.md`

---

## Fix Queue

- [ ] [W1] InsightsConversionWorker: log publish failures per-item — mirror scheduler's `publish_payload/1` pattern with `Logger.error`
  - File: `lib/ad_butler/workers/insights_conversion_worker.ex`

- [ ] [W2] InsightsSchedulerWorker: remove pointless `Stream.chunk_every(200)` in `collect_payloads/1` — replace with `Enum.map(stream, &build_payload/1)`
  - File: `lib/ad_butler/workers/insights_scheduler_worker.ex:42-44`

- [ ] [W3] Replace `Jason.encode!` with `Jason.encode/1` + case in both workers — raises on un-encodable terms, violates "never raise in happy path"
  - Files: `lib/ad_butler/workers/insights_scheduler_worker.ex:49`, `lib/ad_butler/workers/insights_conversion_worker.ex:37`

- [ ] [W4] Fix `analytics.ex` `@spec refresh_view/1` — either wrap `Repo.query!` in rescue → `{:error, ...}` or change spec to `:: :ok | no_return()`
  - File: `lib/ad_butler/analytics.ex:14-16`

- [ ] [W5] Align `publisher()` default module in both workers — both use `:insights_publisher` key but default to different modules (`Publisher` vs `PublisherPool`)
  - Files: `lib/ad_butler/workers/insights_conversion_worker.ex:46`, `lib/ad_butler/workers/insights_scheduler_worker.ex:63`

- [ ] [W6] Fix `bulk_upsert_insights/1` rescue — return atom reason instead of raw exception struct to avoid logging Postgrex internals
  - File: `lib/ad_butler/ads.ex:597-599`

- [ ] [W7] Document partial-publish idempotency assumption — add `@doc` or `@moduledoc` note to both workers that retry may republish to already-sent accounts; downstream consumers must be idempotent
  - Files: `lib/ad_butler/workers/insights_scheduler_worker.ex`, `lib/ad_butler/workers/insights_conversion_worker.ex`

- [ ] [W8] Add `timeout/1` Oban callback to both workers — `def timeout(_job), do: :timer.minutes(6)` so DB tx timeout fires before Oban job timeout
  - Files: `lib/ad_butler/workers/insights_scheduler_worker.ex`, `lib/ad_butler/workers/insights_conversion_worker.ex`

- [ ] [S1] Add `:updated_at` to `bulk_upsert_insights/1` on_conflict replace list
  - File: `lib/ad_butler/ads.ex:577-593`

- [ ] [S2] Replace `Date.from_iso8601!` with safe `Date.from_iso8601/1` + case in `normalise_row/2` — raises inside Broadway processor on bad Meta API date
  - File: `lib/ad_butler/sync/insights_pipeline.ex:151`

- [ ] [S3] Double-quote view name in `do_refresh/1` for consistency with partition DDL — `~s[REFRESH MATERIALIZED VIEW CONCURRENTLY "#{safe_name}"]`
  - File: `lib/ad_butler/analytics.ex:91`

- [ ] [S4] Add CI grep gate — fail build if `lib/ad_butler_web/` or `*_live.ex` references `Ads.unsafe_`
  - Likely a mix alias or `.credo.exs` custom check

---

## Skipped

None.

---

## Deferred

None.
