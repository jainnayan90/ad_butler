# Audit Fixes Round 3 — Review

**Date:** 2026-04-27
**Agents:** elixir-reviewer, iron-law-judge, oban-specialist
**Verdict:** REQUIRES CHANGES

⚠️ EXTRACTED FROM AGENT MESSAGES (agents could not write output files — see scratchpad)

---

## BLOCKER — check.unsafe_callers shell logic is inverted: check always passes

`mix.exs:108`

The command is:
```sh
grep ... && echo 'ERROR...' && exit 1 || exit 0
```
Shell precedence: `(grep ... && echo ... && exit 1) || exit 0`. When grep finds a match and `exit 1` runs, `|| exit 0` catches the non-zero exit and the overall command exits 0. **The check always succeeds regardless of violations.** Correct idiom:
```sh
! grep -rn 'Ads\.unsafe_' lib/... || (echo 'ERROR: ...' && exit 1)
```

---

## BLOCKER — check.unsafe_callers would false-fail once logic is fixed

`lib/ad_butler/sync/insights_pipeline.ex:51`

`InsightsPipeline` calls `Ads.unsafe_get_ad_account_for_sync/1` and lives in `lib/ad_butler/sync`, which is one of the scanned directories. Once the exit-code bug is fixed, `mix precommit` will fail on every run due to this legitimate internal call. Either remove `lib/ad_butler/sync` from the scan paths, or limit scanning to `lib/ad_butler_web` only.

---

## WARNING — bulk_upsert_insights rescue too broad; swallows connection errors

`lib/ad_butler/ads.ex:599-602`

Blanket `rescue e ->` catches transient `DBConnection.ConnectionError`, returning `{:error, :upsert_failed}` instead of crashing and letting Broadway retry correctly. Per CLAUDE.md: rescue is for wrapping third-party code that raises, never your own. Narrow to `Postgrex.Error` or remove the rescue and let Broadway's retry semantics handle transient DB failures.

---

## WARNING — normalise_row nil :ad_id can reach NOT NULL constraint

`lib/ad_butler/sync/insights_pipeline.ex:167`

`meta_id_map[row.ad_id]` returns `nil` if the key is absent (e.g. concurrent deletion between `Enum.filter` and `Enum.map`). The nil `:ad_id` passes the date_start nil-reject and hits the NOT NULL constraint in bulk_upsert, returning `{:error, :upsert_failed}` with no useful context. Use `Map.fetch!(meta_id_map, row.ad_id)` — a crash lets Broadway fail the message with correct semantics.

---

## WARNING — collect_payloads drops encode-failed accounts with no aggregate signal

`insights_scheduler_worker.ex:49-54`, `insights_conversion_worker.ex:52-57`

If every account fails to encode, jobs return `:ok` with `count: 0` — indistinguishable from "no active accounts." Log dropped count when non-zero, or add a `Logger.warning` when `count == 0 && errors == []`.

---

## WARNING — get_ad_meta_id_map/1 bypasses tenant scope without `unsafe_` prefix (PRE-EXISTING)

`lib/ad_butler/ads.ex:134`

Used in the sync pipeline, so bypass is intentional, but naming is inconsistent with `unsafe_get_ad_account_for_sync/1`. Rename to `unsafe_get_ad_meta_id_map/1` for consistency and to ensure it's caught by the unsafe_callers check.

---

## WARNING — DB timeout layering risk (both workers)

If Postgres `idle_in_transaction_session_timeout` is configured below 5 min on managed DBs, Postgres kills the connection before the Oban timeout fires, the stream raises, and the worker retries with misleading error context. Recommend verifying Postgres session timeout configuration exceeds the 5-min transaction timeout.

---

## SUGGESTION — Log error_count on publish failures

`lib/ad_butler/workers/insights_scheduler_worker.ex:29-32`

When multiple publishes fail, only the head error is surfaced. Log `error_count: length(errors)` before returning `{:error, reason}`.

---

## SUGGESTION — Add note to Insight schema about absent timestamps() macro

`lib/ad_butler/ads/insight.ex:32-33`

Manual `:naive_datetime` fields are correct for a write-bypass schema. A short inline comment explaining why `timestamps()` is intentionally absent prevents future reviewers from "fixing" it.

---

## SUGGESTION — Move workers to dedicated `insights` queue

Both workers use `queue: :default`. A dedicated `insights` queue prevents head-of-line blocking against unrelated jobs during high-volume syncs.

---

## Clean (no violations)

- Tenant scope: all user-facing queries scoped correctly
- Oban for scheduled work: correct, no GenServer loops
- Structured logging: all Logger calls use key-value metadata
- Migration reversibility: `up/down` defined, append-only preserved
- No Repo calls in LiveViews/controllers/Broadway pipeline
- Jason.encode! removed; safe variant used throughout
- timeout/1 callback: 6-min correct relative to 5-min DB timeout
