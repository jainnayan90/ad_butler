# Review: audit-fixes-round2
**Verdict: PASS WITH WARNINGS**
**Date: 2026-04-27**
**Agents: elixir-reviewer, iron-law-judge, security-analyzer, testing-reviewer, oban-specialist**

---

## Issue Summary

| Severity | Count |
|----------|-------|
| BLOCKER  | 0 |
| WARNING  | 8 |
| SUGGESTION | 4 |

---

## Warnings (act on before merging to main)

### W1 — InsightsConversionWorker: publish failures not logged
**Files:** `lib/ad_butler/workers/insights_conversion_worker.ex:20-26`
**Source:** elixir-reviewer, oban-specialist (duplicate — kept once)

`InsightsConversionWorker` uses `Enum.map(payloads, &publisher().publish/1)` then `Enum.find` to detect errors, but never logs failures. `InsightsSchedulerWorker` correctly logs each failure in `publish_payload/1`. The two sibling workers are inconsistent — partial failures are invisible in `InsightsConversionWorker`.

Fix: mirror the scheduler pattern with `Enum.reduce` + `Logger.error`.

---

### W2 — InsightsSchedulerWorker.collect_payloads/1: unnecessary Stream.chunk_every
**File:** `lib/ad_butler/workers/insights_scheduler_worker.ex:42-44`
**Source:** elixir-reviewer, oban-specialist

`Stream.chunk_every(200) |> Enum.flat_map(&Enum.map(&1, ...))` is semantically identical to `Enum.map(stream, &build_payload/1)`. No per-chunk operations occur; the chunking adds complexity with no benefit. `InsightsConversionWorker` does it correctly.

Fix: `Enum.map(stream, &build_payload/1)`.

---

### W3 — Jason.encode! in worker perform paths raises instead of returning {:error, reason}
**Files:** `lib/ad_butler/workers/insights_scheduler_worker.ex:49`, `lib/ad_butler/workers/insights_conversion_worker.ex:37`
**Source:** iron-law-judge

`Jason.encode!` raises `Jason.EncodeError` on un-encodable terms. Inside a `perform/1` chain, this violates the "never raise in the happy path" principle and bypasses Oban's error return contract.

Fix: `Jason.encode/1` + `case`, or ensure account IDs are always strings/UUIDs before encoding.

---

### W4 — analytics.ex: @spec says {:error, String.t()} but Repo.query! raises
**File:** `lib/ad_butler/analytics.ex:14-16`
**Source:** elixir-reviewer

`refresh_view/1` is specced `:: :ok | {:error, String.t()}` but `do_refresh/1` calls `Repo.query!` (raises on DB failure). Only the `"unknown view"` clause returns a proper error tuple. Callers that match on `{:error, _}` will not catch DB failures.

Fix: Either wrap `Repo.query!` in `rescue` → `{:error, inspect(e)}`, or change spec to `:: :ok | no_return()` and add a `@doc` note that DB failures raise.

---

### W5 — Two workers, same config key, different default modules
**Files:** `lib/ad_butler/workers/insights_conversion_worker.ex:46`, `lib/ad_butler/workers/insights_scheduler_worker.ex:63`
**Source:** elixir-reviewer

Both read `Application.get_env(:ad_butler, :insights_publisher, ...)` but default to `AdButler.Messaging.Publisher` vs `AdButler.Messaging.PublisherPool` respectively. If the key is absent, the workers silently use different publishers.

Fix: Align both defaults to the same module (likely `PublisherPool`) or use `fetch_env!/2`.

---

### W6 — bulk_upsert_insights/1 rescue returns raw Postgrex.Error struct
**File:** `lib/ad_butler/ads.ex:597-599`
**Source:** security-analyzer

`rescue e -> {:error, e}` returns the full exception. `Postgrex.Error` carries SQL text and parameter values. Broadway's `Message.failed/2` will `inspect/1` it on log output. While current params are internal UUIDs (no PII), it violates the project's redact-at-boundary guidance.

Fix:
```elixir
rescue
  e ->
    Logger.error("bulk_upsert_insights failed", reason: Exception.message(e))
    {:error, :upsert_failed}
```

---

### W7 — Partial-publish retry is not idempotent (both workers)
**Source:** oban-specialist

If a scheduler worker publishes 80/100 messages then crashes, retry will re-publish all 100 — the first 80 downstream consumers receive duplicates. This is not a regression introduced in this diff (the old code had the same issue), but worth acknowledging.

**Resolution options:**
1. Document it and ensure downstream consumers are idempotent (preferred for RabbitMQ fan-out)
2. Track published IDs externally on retry

---

### W8 — No Oban timeout/1 callback on either worker
**Source:** oban-specialist

`stream_ad_accounts_and_run` has a 5-minute DB transaction timeout; Oban's default job timeout is `:infinity`. Without a `timeout/1` callback, the Oban job can outlive the DB transaction in unexpected failure modes.

Fix: `def timeout(_job), do: :timer.minutes(6)` on both workers (just above the DB timeout so the DB call fails cleanly first).

---

## Suggestions (nice-to-have)

### S1 — bulk_upsert_insights missing :updated_at in conflict replace list
**File:** `lib/ad_butler/ads.ex:577-593` (pre-existing, not introduced in this diff)
The upsert conflict list does not include `:updated_at`. Rows updated via upsert retain their original `updated_at`, making it hard to know when the last sync ran.

### S2 — normalise_row/2 uses Date.from_iso8601! inside a Broadway processor
**File:** `lib/ad_butler/sync/insights_pipeline.ex:151` (pre-existing)
A malformed `date_start` from Meta API raises inside the processor rather than cleanly failing the message. Prefer `Date.from_iso8601/1` with a `case`.

### S3 — do_refresh/1: view name not double-quoted for consistency
**File:** `lib/ad_butler/analytics.ex:91`
`create_future_partitions/0` wraps `safe_pname` in double quotes; `do_refresh/1` does not. The guard makes both safe, but consistency aids readability.
Fix: `~s[REFRESH MATERIALIZED VIEW CONCURRENTLY "#{safe_name}"]`

### S4 — Add CI grep gate for Ads.unsafe_ in web/LiveView files
**Source:** security-analyzer
The `unsafe_*` naming convention is correct signalling, but not compiler-enforced. A CI grep that fails if `lib/ad_butler_web/` or any `*_live.ex` references `Ads.unsafe_` would catch accidental use.

---

## Test-Specific Notes

- **Config key mismatch** (testing-reviewer): `config/test.exs` uses `:messaging_publisher`; the tests `put_env` under `:insights_publisher` manually. If the explicit `put_env` were removed, real publisher would be called. Low risk given tests already do the right thing, but consolidating the key would remove the discrepancy.
- **Tenant isolation quality**: New tests verify row-level isolation by `ad_id`, which is the relevant isolation for these `unsafe_*` views. Tests are appropriate given the views have no tenant column.
- **Jitter test**: `expect` callback ignores payload contents. Consider decoding and asserting `jitter_secs` is within expected range.

---

## Passing Checks

- Repo boundary: both workers correctly delegate to `Ads.stream_ad_accounts_and_run/2`, no `alias Repo` in workers ✓
- Structured logging: all Logger calls use keyword metadata in changed files ✓
- CLOAK_KEY zero-check: `<<0::256>>` guard is correct and complete ✓
- `safe_identifier!` DDL guard: regex correctly rejects all SQL metacharacters ✓
- Auth controller Logger: structured, sliced to 200 chars, no PII ✓
- Oban callbacks: `@impl Oban.Worker` on `perform/1` ✓
- O(n²) fix in meta/client.ex: prepend + reverse pattern is correct ✓
- ISO year fix in partition test: correctly uses `{iso_year, week}` from `:calendar.iso_week_number` ✓
- Migration down: pg_inherits loop correctly drops all child partitions ✓
