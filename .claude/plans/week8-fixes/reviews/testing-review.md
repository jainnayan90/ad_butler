# Test Review — v0.3 + week8 fixes

⚠️ EXTRACTED FROM AGENT MESSAGE — agent could not write directly (hook-restricted). Findings preserved verbatim.

**Files reviewed:** `analytics_test.exs`, `analytics_insights_test.exs`, `creative_fatigue_predictor_worker_test.exs`, `embeddings_test.exs`, `embeddings_refresh_worker_test.exs`, `week8_e2e_smoke_test.exs`, `test/support/mocks.ex`

**Summary:** Suite is structurally sound. `async: false` usage justified and documented, Mox setup follows convention (`set_mox_from_context` + `verify_on_exit!`), `ServiceMock` correctly backed by `ServiceBehaviour`, tenant isolation tests exist where required, no `Process.sleep` calls. Three issues need attention.

---

## WARNING

**`embeddings_refresh_worker_test.exs:74, 96, 127` — Test couples to internal helper `EmbeddingsRefreshWorker.ad_content/1`**
Tests call `EmbeddingsRefreshWorker.ad_content/1` to compute expected hashes. The helper was made public specifically for test use. Consider either:
- A dedicated unit test for `ad_content/1` so its contract is anchored, OR
- Compute the hash from raw ad attributes (`Embeddings.hash_content("Promo July 2026")`) so test correctness doesn't depend on the helper's exact format.

**`analytics_insights_test.exs:99, 113` — Float `==` on `get_7d_frequency/1` return (PERSISTENT)**
`assert Analytics.get_7d_frequency(ad.id) == 4.0` uses bare `==` against a float from `AVG()` over `Decimal` columns. Today's integer-average happens to land exactly on 4.0, but `assert_in_delta result, 4.0, 0.0001` is safer and documents intent. PERSISTENT from prior /phx:full review (was skipped — re-raised here).

**`week8_e2e_smoke_test.exs:3–14 vs 73` — `@moduledoc` claims `FatigueNightlyRefitWorker` → `CreativeFatiguePredictorWorker` enqueue chain, but test calls the predictor directly**
Step 1 in the moduledoc says the nightly refit worker enqueues the predictor; the test body skips that and calls `perform_job(CreativeFatiguePredictorWorker, …)` directly. Smoke test does not exercise the enqueue chain it claims to validate.
→ Fix: Either update `@moduledoc` to reflect what is actually tested, OR add `perform_job(FatigueNightlyRefitWorker, %{})` + `assert_enqueued worker: CreativeFatiguePredictorWorker` before step 2 and drain from there.

---

## SUGGESTION

**`embeddings_refresh_worker_test.exs:135` — describe "tenant isolation" is misleadingly named**
The block deliberately verifies *cross-tenant* global embedding. Rename to `"perform/1 — cross-tenant embedding (by design)"` to avoid future readers second-guessing the absence of a scope filter.

**`analytics_insights_test.exs:18` — describe heading conflates two functions**
`"compute_ctr_slope/2 / get_7d_frequency/1"` should be just `"compute_ctr_slope/2"` — `get_7d_frequency/1` has its own dedicated describe block below.
