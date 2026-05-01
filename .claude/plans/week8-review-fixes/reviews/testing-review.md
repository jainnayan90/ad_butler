# Test Review — week8-review-fixes

**Verdict:** PASS WITH WARNINGS — 0 BLOCKER, 2 WARNINGS (1 valid, 1 plan-acknowledged), 3 SUGGESTIONS.

> ⚠️ Captured from testing-reviewer agent chat output (Write was denied).

Mox pattern is correct. All mocks are backed by behaviours. No `Process.sleep`. No Iron Law violations.

## Iron Law violations

None.

## Filtered findings (stale — not actionable)

### ~~WARN: bare float `==` at `analytics_insights_test.exs:99, 113`~~ (FILTERED)

Agent claimed PERSISTENT/unfixed. **Verified incorrect** — both lines use `assert_in_delta Analytics.get_7d_frequency(ad.id), 4.0, 0.0001`. Plan task P7-T3 applied this fix; agent had stale context.

## Warnings

### W1 — `week8_e2e_smoke_test.exs:88` — `drain_queue` asserts `failure: 0` only

`assert %{failure: 0} = Oban.drain_queue(queue: :fatigue_audit)` passes even if zero jobs ran. **Plan-acknowledged tradeoff** — incidental ad_accounts from the factory chain make exact `success` count unstable. Strengthen to `assert %{success: success, failure: 0} = ...; assert success >= 1` if you want a non-zero floor.

### W2 (PERSISTENT) — `embeddings_refresh_worker_test.exs:74, 96, 127` — test couples to `EmbeddingsRefreshWorker.ad_content/1` for hash derivation

Expected hashes are computed by calling the worker's own helper, so the test cannot catch content-format regressions. The new `ad_content/1` unit tests (lines 202–225 from P7-T1) anchor the contract; the hash-comparison tests should derive expected values from raw string literals (e.g., `"#{ad.name} | "`) instead.

## Suggestions

- **S1** — `embeddings_refresh_worker_test.exs:135` — Rename `"perform/1 — tenant isolation"` to `"perform/1 — cross-tenant embedding (by design)"` to prevent confusion.
- **S2** — `analytics_insights_test.exs:18` — Describe heading `"compute_ctr_slope/2 / get_7d_frequency/1"` should be `"compute_ctr_slope/2"` only; `get_7d_frequency/1` has its own block at line 78.
- **S3** — `embeddings_test.exs:105–130` — First `nearest/3` ordering test uses `shifted_vector` with small offsets (1 vs 50). Consider `partial_ones` (per the existing solution doc) for the wider gap, or add a comment acknowledging the approximation risk.
