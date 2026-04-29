# Review: week-2-review-fixes-2

**Date**: 2026-04-29
**Verdict**: REQUIRES CHANGES
**Breakdown**: 1 blocker · 5 warnings · 4 suggestions

All 13 prior tasks (P1–P5) from the plan confirmed implemented. One critical implementation bug found.

---

## BLOCKERS

### B1: `Oban.insert_all` failure filter is dead code — error logging never fires
**Source**: Oban Specialist + Elixir Reviewer
**Location**: `lib/ad_butler/workers/audit_scheduler_worker.ex:31–35`

`Oban.insert_all/1` returns `[%Oban.Job{}]` — a flat list of inserted structs. It raises on DB error; it never returns `{:error, _}` tuples. The filter:

```elixir
failed = Enum.filter(results, &match?({:error, _}, &1))
```

never matches anything. `failed` is always `[]`. The `Logger.error` call is unreachable dead code. The intent of P2-T2 (capture and log errors) is not achieved.

**Fix**:
```elixir
results = Oban.insert_all(valid)
skipped = length(valid) - length(results)
if skipped > 0, do: Logger.info("audit_scheduler: jobs deduplicated", count: skipped)
Logger.info("audit_scheduler enqueued jobs", count: length(results))
```

---

## WARNINGS

### W1: `keys: []` comment is inaccurate — `fields:` is the correct opt
**Source**: Oban Specialist
**Location**: `lib/ad_butler/workers/audit_scheduler_worker.ex:9–10`

`keys: []` means "args maps must be exactly equal", not "args not considered". Works today because the scheduler is always called with `%{}` args, making any two runs always equal. But the comment says "job args are not considered" which is wrong and will mislead if args are ever added.

Correct form to truly ignore args: `unique: [period: 21_600, fields: [:queue, :worker]]`

### W2: `check_bot_traffic` still uses float division — inconsistent with other heuristics
**Source**: Elixir Reviewer
**Location**: `lib/ad_butler/workers/budget_leak_auditor_worker.ex:219–224`

`check_cpa_explosion` and `check_placement_drag` were fixed to integer arithmetic but `check_bot_traffic` still uses `total_clicks / total_impressions` and `total_conversions / total_clicks`. These values are not stored, so no precision bug — but inconsistent with the fix goal.

### W3: `async: false` comment reason is technically inaccurate
**Source**: Elixir Reviewer
**Location**: both worker test files, line 3

"REFRESH MATERIALIZED VIEW cannot run CONCURRENTLY inside a sandbox transaction" — the calls don't use CONCURRENTLY. The real reason: shared mutable state across concurrent test processes would cause flakes and potential deadlocks. Suggested correction:
```elixir
# async: false — tests share insights_daily partitions and ad_insights_30d mat-view;
# concurrent processes would see each other's seeded rows
```

### W4: `ad_accounts_list` assign is potentially unbounded
**Source**: Iron Law Judge
**Location**: `lib/ad_butler_web/live/findings_live.ex:213`

`Ads.list_ad_accounts/1` appears unbounded. For a high-volume tenant this grows without limit. The findings table correctly uses `stream(:findings, ...)` — only the dropdown assign is unguarded. Add a `LIMIT` to `list_ad_accounts/1` or paginate.

### W5: `get_finding/2` may raise on malformed UUID instead of returning `{:error, :not_found}`
**Source**: Testing Reviewer
**Location**: `lib/ad_butler/analytics.ex:67–72` / `test/ad_butler/analytics_test.exs`

`Repo.get/2` with a `:binary_id` primary key raises `Ecto.Query.CastError` for non-UUID strings. `get_finding/2` currently does not rescue this. A caller passing a raw URL segment gets an unexpected raise instead of `{:error, :not_found}`.

---

## SUGGESTIONS

### S1: Health score idempotency test has wall-clock boundary risk
**Source**: Testing Reviewer
**Location**: `test/ad_butler/workers/budget_leak_auditor_worker_test.exs`

If the test runs exactly at a 6-hour UTC boundary (00:00, 06:00, 12:00, 18:00) and the two `perform_job` calls straddle it, they produce different `computed_at` buckets and `count == 2` fails the assertion. Low-probability flake. Document the risk with a comment or mock `six_hour_bucket/0`.

### S2: `acknowledge_finding/2` missing explicit nonexistent-ID test
**Source**: Testing Reviewer

No test for `acknowledge_finding(user, Ecto.UUID.generate())` where the finding simply doesn't exist. Covered transitively through `get_finding/2` tests but an explicit test would pin the contract.

### S3: `unsafe_get_latest_health_score/1` invariant is doc-only
**Source**: Security Analyzer
**Location**: `lib/ad_butler/analytics.ex:142`

Doc names the precondition; nothing structural enforces it. A future caller taking `ad_id` from params (e.g. `/ads/:ad_id/health`) could leak cross-tenant health scores. Consider exposing `get_health_score_for_finding(user, finding_id)` that bundles both lookups behind one scope boundary.

### S4: Verify `unique_constraint` in `Finding` changeset for TOCTOU guard
**Source**: Oban Specialist

The TOCTOU partial unique index (`findings_ad_id_kind_unresolved_index`) produces clean `{:error, changeset}` on concurrent duplicates only if `unique_constraint` is declared in `Finding.create_changeset/2`. Without it, the DB error surfaces as a raw `Postgrex.Error` raise. Check `lib/ad_butler/analytics/finding.ex`.

---

## Pre-existing Issues (Not In This Diff)

- B2 PERSISTENT: `/app/bin/migrate` missing — Fly deploys will fail
- B3 PERSISTENT: Docker ARG not exported as ENV — build fails
- W1 PERSISTENT: `inspect(reason)` leaks access_token in `fetch_ad_accounts_worker.ex`
- W2 PERSISTENT: Empty SESSION_SIGNING_SALT accepted
- W3 PERSISTENT: `auto_stop_machines = true` tears down RabbitMQ consumers
- W5 PERSISTENT: `Task.start/1` for RabbitMQ topology unsupervised
- W6 PERSISTENT: `/health/readiness` no rate limiting
