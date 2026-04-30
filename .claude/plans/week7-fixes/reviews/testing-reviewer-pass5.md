# Test Coverage Review — Pass 5

**Verdict:** PASS WITH WARNINGS — 2 missing tests

> Note: written by parent after agent returned findings inline.

---

## Per-fix coverage

- **W-4** (`inspect(reason)` → raw in Logger) — COVERED. Worker tests assert on return values, not Logger format.
- **W-5** (docstring update in `ads.ex`) — N/A.
- **W-6** (`compute_ctr_slope/2` head-match) — **COVERED FOR BOTH PATHS**. `analytics_test.exs:352` seeds exactly 1 row (hits `[_]`); line 363 seeds no rows (hits `[]`). Both arms exercised.
- **W-7** (`avg_cpm/1` tag-tuple change) — COVERED INDIRECTLY. `avg_cpm/1` is private; `get_cpm_change_pct/1`'s `with ... else _ -> nil` handles both arms. Tests at `analytics_test.exs:461, 474` still assert `nil` correctly.
- **W-8** (`<div :if={!@finding}>` disconnected placeholder) — **MISSING TEST**. No test exercises the nil-finding render path. Existing `finding_detail_live_test.exs` tests either redirect or mount with a seeded finding.
- **S-8** (`Enum.zip_reduce/4`) — N/A.
- **S-9** (ad_accounts moved to `:reload_on_reconnect`) — **MISSING TEST**. No test asserts `list_ad_accounts/1` is called once per session vs. on every filter event. The perf invariant can regress silently.
- **S-10**, **S-11** — N/A.

---

## Missing Tests

1. **`test/ad_butler_web/live/finding_detail_live_test.exs`** — Disconnected static render: `Phoenix.ConnTest.get/2` on `/findings/:id` and assert the 200 response contains the loading placeholder rather than a 500, confirming `@finding = nil` renders without crash.

2. **`test/ad_butler_web/live/findings_live_test.exs`** — Telemetry query-counter test: attach a handler in setup counting `[:ad_butler, :repo, :query]` events scoped to the `ad_accounts` table, mount the view, fire 3 `filter_changed` events, assert the count is 1. Without this the `:reload_on_reconnect` perf claim is an untested contract.

---

## Test brittleness in existing suite

- `creative_fatigue_predictor_worker_test.exs` correctly `async: false` (DDL partition creation) — fine.
- `analytics_test.exs` creates partitions in per-describe setups without teardown; benign under sandbox isolation but partition count grows over CI runs. Pre-existing, out of scope for this round.
