# Week 8 Oban Worker Review

⚠️ EXTRACTED FROM AGENT MESSAGE (Write was denied for the agent)

Files reviewed: `fatigue_nightly_refit_worker.ex`, `embeddings_refresh_worker.ex`, `creative_fatigue_predictor_worker.ex` (modified), `config/config.exs`. Week 7 BLOCKERs (non-atomic score/finding write, discarded `maybe_emit_finding` return, runtime.exs kill-switch) all resolved.

---

## BLOCKER 1 — `upsert_batch/3` swallows per-row errors, returns `:ok` to Oban unconditionally

**`embeddings_refresh_worker.ex:118–138` and `99`**

`upsert_batch/3` uses `Enum.each/2` and logs on `{:error, changeset}` but discards the return. The calling clause at line 99 returns `:ok` unconditionally. Any embedding upsert failure (pgvector dimension mismatch, DB constraint) is silently ignored — Oban marks the job complete, no retry fires, and the failed row sits at its stale hash with zero alerting signal.

**Fix:** Collect errors, emit `Logger.error` with `failure_count:` (already in allowlist), and return `{:error, :partial_upsert_failure}` if `failures > 0`.

## BLOCKER 2 — `FatigueNightlyRefitWorker` unique window (1h) escapable by Lifeline's 30-min rescue

**`fatigue_nightly_refit_worker.ex:16`**

`unique: [period: 3_600, ...]`. Cron is daily (86 400s). Lifeline `rescue_after: :timer.minutes(30)`. Scenario: job starts at 03:00, gets rescued at 03:31 and rescheduled, unique window expires at 04:00, rescheduled job executes at 04:01 — full second fan-out. Child predictor jobs are deduplicated by their own 6h unique window so no duplicate predictor runs, but the refit worker itself runs twice.

**Fix:** `period: 82_800` (23h) to match daily cron intent, consistent with `DigestSchedulerWorker` and `AuditSchedulerWorker` patterns.

---

## WARNING 1 — 2N uncached Repo queries from `heuristic_predicted_fatigue/1` risks 10-min timeout

**`creative_fatigue_predictor_worker.ex:256–275`**

Per ad: `fit_ctr_regression/1` queries `insights_daily` (14-day window) with no cache. `get_ad_honeymoon_baseline/1` has cache but falls through on miss. For N=200 ads: up to 400 added round-trips. At 20ms/query that is 8s; N=500 is 20s. Combined with other heuristics this can breach `timeout/1 => :timer.minutes(10)`.

**Fix:** Pre-batch `insights_daily` for all ad IDs in a single query and split in Elixir, OR raise timeout to 20 min with backlog item.

## WARNING 2 — Nightly refit fan-out silently absorbed by 6h predictor unique window

**`creative_fatigue_predictor_worker.ex:24–27`**

`unique: [period: 21_600, ...]`. If 00:03 6h audit completed, predictor jobs are still in unique window at 03:00. Nightly refit fan-out produces only `conflict?` jobs. Documented in moduledoc — no bug, but expect refit `count` log to regularly show 0 non-conflicted jobs.

## WARNING 3 — Default backoff thrashes on rate limits; 3 attempts exhausted in ~75s

**`embeddings_refresh_worker.ex:21`**

Default Oban backoff: ~15s, ~60s. OpenAI rate limit resets ~60s. All 3 attempts can be consumed inside the rate-limit window, permanently discarding the batch until the next 30-min cron.

**Fix:** Return `{:snooze, 90}` for `:rate_limit` so attempt counter is not consumed.

## WARNING 4 — 25-min unique window vs 30-min cron leaves backfill overlap gap

**`embeddings_refresh_worker.ex:24`**

`unique: [period: 1_500, ...]`. If a run during initial backfill takes >25 min, two jobs overlap. Upsert is idempotent (correct data) but doubles embedding API cost. Low risk at steady state.

---

## SUGGESTION — Logger `expected` semantics inverted in vector mismatch log

**`embeddings_refresh_worker.ex:103–108`**

`count: length(candidates)` is what was sent; `expected: length(vectors)` is what came back — opposite of conventional naming. Swap labels or rename `vectors_received`.

---

## Queue Config

- No Oban queue overrides in `runtime.exs` — `:embeddings: 3` takes effect from `config.exs`. Confirmed.
- Pool size comment correctly updated.
- Cron entries present and correctly formatted.
- 03:00 audit queue: refit is fast fan-out on `:audit`; predictor children go to `:fatigue_audit`. AuditScheduler fires at 03:03. No starvation.

## Logger Allowlist

All new metadata keys present in allowlist: `kind`, `count`, `reason`, `ad_id`, `finding_id`, `expected`, `ad_account_id`, `ads_audited`, `ads_with_signals`. No `inspect/1` wrapping.
