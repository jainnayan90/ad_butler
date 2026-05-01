# Week 8 Iron Law Review

⚠️ EXTRACTED FROM AGENT MESSAGE (Write was denied for the agent)

Files scanned: 11 | Laws checked: 18 | **Violations: 5 (0 BLOCKER, 3 WARNING, 2 SUGGESTION)**

---

## Carried-Forward from Week 7 (unresolved)

The three Week 7 findings (N+1 `Repo.update_all` in `ads.ex:550`, silent `with true <-` in `analytics.ex:348`, `inspect(v)` in `finding_detail_live.ex:233`) were not touched in the Week 8 diff and remain open.

---

## WARNING

### [Iron Law #15] N+1 upserts in `EmbeddingsRefreshWorker.upsert_batch/3`
**File:** `lib/ad_butler/workers/embeddings_refresh_worker.ex:118-138`

`Enum.each` calls `Embeddings.upsert/1` (one `Repo.insert`) per candidate — up to `@batch_size = 100` serial round-trips per cron tick.

**Fix:** Build a list of maps and call `Repo.insert_all(Embedding, rows, on_conflict: ..., conflict_target: [:kind, :ref_id])` once. Check the returned row count against `length(candidates)` for the error log.

### [Iron Law #7 — Logger allowlist] Misleading key `ad_id:` for non-ad embedding failures
**File:** `lib/ad_butler/workers/embeddings_refresh_worker.ex:133`

When `kind` is `"finding"` or `"doc_chunk"` the value logged under `:ad_id` is a finding or chunk UUID. Misleads log queries.

**Fix:** Change key to `ref_id: c.ref_id` and add `:ref_id` to the allowlist in `config/config.exs`.

### [Iron Law #14 — N+1 queries] `heuristic_predicted_fatigue/1` issues 2 per-ad queries inside the ad loop
**File:** `lib/ad_butler/workers/creative_fatigue_predictor_worker.ex:256-275`

`Analytics.fit_ctr_regression/1` and `Analytics.get_ad_honeymoon_baseline/1` (cache miss) run per ad inside `run_all_heuristics/1`. Acceptable at current ad counts but degrades.

**Fix (pragmatic):** Bulk-fetch the 14-day `insights_daily` window for all `ad_ids` in a single `ad_id IN ^ad_ids` query before the loop, then group by `ad_id`. Add a TODO comment.

---

## SUGGESTION

### [Iron Law #1] `doc_ref_id/1` derivation deserves a comment
**File:** `lib/mix/tasks/ad_butler.seed_help_docs.ex:93-96`

Private function — `@doc` not required. But the SHA-256 → first 16 bytes → UUID derivation is non-obvious and the `conflict_target` invariant depends on it being stable. One-line comment recommended.

### [Iron Law #12 — Secrets] ReqLLM API key sourcing
**File:** `lib/ad_butler/embeddings/service.ex:28`

Verify ReqLLM's OpenAI key sourced via `System.fetch_env!` in `runtime.exs`. (Security agent confirmed: present at `.env.example:62-67`, loaded in `runtime.exs:60-64`.)

---

## Verified Clean (Week 8 new code)

- All 3 migrations reversible.
- Both new workers use `Oban.Worker` with `unique:` — no GenServer timer loops.
- Embeddings service uses Behaviour + `Application.get_env` indirection.
- No `String.to_atom`, no DaisyUI in new files.
- All Logger keys in new files in the `config/config.exs` allowlist.
- All new public functions have `@doc` + `@spec`; all new modules have `@moduledoc`.
- `Repo` called only from context modules.
