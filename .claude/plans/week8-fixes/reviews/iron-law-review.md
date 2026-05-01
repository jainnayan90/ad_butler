# Iron Law Review — v0.3 + week8 fixes

⚠️ EXTRACTED FROM AGENT MESSAGE — agent could not write directly (hook-restricted).

**Files scanned:** 11 | **Laws checked:** 13 | **Violations: 2 (1 BLOCKER, 1 WARNING)**

---

## BLOCKER

### [#1 — Repo boundary] Direct `Repo` calls inside worker

`lib/ad_butler/workers/embeddings_refresh_worker.ex:53–64`

`build_candidates/2` issues bare `Repo.all` against `Ad`/`Creative` and `Finding` directly inside the worker — bypassing the context boundary. **Workers must not call `Repo` directly.**

**Fix:** Extract both queries into context functions:
- `AdButler.Ads.unsafe_list_ads_with_creative_names/0` → returns `[%{id, name, creative_name}]`
- `AdButler.Analytics.unsafe_list_all_findings_for_embedding/0` → returns `[%{id, title, body}]`

Remove the `Repo`, `Ad`, `Creative`, and `Finding` aliases from the worker entirely.

---

## WARNING

### [#7 — N+1 / Bulk writes] Single-row upsert loop instead of bulk

`lib/mix/tasks/ad_butler.seed_help_docs.ex:72–89`

`upsert_all/2` calls `Embeddings.upsert/1` (single-row `Repo.insert`) once per help doc inside `Enum.each`. `Embeddings.bulk_upsert/1` already exists for exactly this case.

**Fix:** Build the rows list from `Enum.zip(docs, vectors)` and call `Embeddings.bulk_upsert(rows)` once. Compare returned count against `length(docs)` to detect partial failures.

---

## Clean Items (verified in this diff)

- All 3 migrations reversible: `change` (nullable add) and explicit `up`/`down`. ✓
- No `String.to_atom/1` on user input. ✓
- No `inspect/1` in Logger metadata. ✓
- No PII in logs. ✓
- `EmbeddingsRefreshWorker` snooze path has no `attempt` guard — no Smart Engine infinite-loop risk. ✓
- `CreativeFatiguePredictorWorker` uses string Oban args keys (`"ad_account_id"`). ✓
- `bulk_insert_fatigue_scores/1` uses `Repo.insert_all`. ✓
- `nearest/3` documents that callers must scope `ref_id` lookups to the user's MetaConnection IDs before surfacing results. ✓
- No unbounded list assigns in any LiveView (no LiveView files in this diff). ✓
