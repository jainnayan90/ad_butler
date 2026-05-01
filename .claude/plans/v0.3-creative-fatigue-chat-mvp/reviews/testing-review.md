# Week 8 Testing Review

⚠️ EXTRACTED FROM AGENT MESSAGE (Write was denied for the agent)

**Severity counts: 3 BLOCKERS, 5 WARNINGS, 3 SUGGESTIONS**

---

## BLOCKERS

### B1 — `analytics_test.exs` DDL under `async: true`
`test/ad_butler/analytics_test.exs:316, 375, 434, 486, 626`

Five `describe` blocks call `create_insights_partition` in `setup`. DDL takes `AccessExclusiveLock`, commits immediately, bypasses sandbox rollback, and races against parallel async processes.

**Note:** PERSISTENT from Week 7 (existing `compute_ctr_slope/get_7d_frequency/get_cpm_change_pct` describes already had this). Week 8 added 2 more (honeymoon baseline + fit_ctr_regression) compounding the surface.

**Fix:** Extract these describes into a separate file with `async: false` (same pattern as `creative_fatigue_predictor_worker_test.exs`).

### B2 — `week8_e2e_smoke_test.exs` missing `@moduletag :integration`
`test/ad_butler/integration/week8_e2e_smoke_test.exs`

Project convention: integration tests carry `@moduletag :integration` so `test_helper.exs` can exclude them. Without the tag, the smoke test runs on every `mix test`.

**Fix:** Add `@moduletag :integration` or move to a non-integration directory.

### B3 — No tenant-isolation test for `EmbeddingsRefreshWorker`
CLAUDE.md: "Tenant isolation tests are non-negotiable." The worker is intentionally cross-tenant (processes all ads), but that design decision is untested and undocumented.

**Fix:** Add a two-tenant test that inserts ads under two `meta_connection` owners, runs the worker, and asserts embeddings exist for both — proving cross-tenant processing is deliberate.

---

## WARNINGS

**W1** — Idempotency test hard-codes `"#{ad.name} | "` as the hash content (`embeddings_refresh_worker_test.exs:71`). If the worker adds any field to the content string the hash diverges silently and the test degrades into a first-run test without failing loudly.

**W2** — `get_7d_frequency` asserts `== 4.0` float equality (`analytics_test.exs:394, 408`). Use `assert_in_delta`. (PERSISTENT from Week 7.)

**W3** — `nearest/3` limit test only asserts `length == 2`; which 2 rows are returned is unverified (`embeddings_test.exs:167`).

**W4** — Two `expect` calls in the "first run" embeddings worker test assume ads-before-findings batch ordering (`embeddings_refresh_worker_test.exs:39–49`).

**W5** — `fit_ctr_regression` declining-series test asserts `slope < 0.0` with no lower bound (`analytics_test.exs:673`). A slope of `-1e-10` satisfies the condition. Tighten to `< -0.001`.

---

## SUGGESTIONS

**S1** — `describe "compute_ctr_slope/2 / get_7d_frequency/1"` heading is misleading. Rename to `"compute_ctr_slope/2"`. (PERSISTENT.)

**S2** — `heuristic_frequency_ctr_decay` "fires" test seeds then immediately deletes and re-seeds (`creative_fatigue_predictor_worker_test.exs:83–95`). (PERSISTENT.)

**S3** — `test/ad_butler/integration/` is a new subdirectory not consistent with `test/integration/` (existing). Consolidate or document.
