# Week 7 Pass-4 Triage

**Source:** [week7-pass4-consolidated.md](week7-pass4-consolidated.md)
**Decision:** All findings approved for fixing. 9 items.

---

## Fix Queue

### WARNINGs (5)

- [x] **W-4** Replaced `inspect/1` with raw term in three `Logger.error` calls (`creative_fatigue_predictor_worker.ex:236, 354, 365`). `:reason` is already in the metadata allowlist.

- [x] **W-5** Documented the raise-on-failure contract in [`Ads.append_quality_ranking_snapshots/2`](../../../../lib/ad_butler/ads.ex#L538) `@doc` — explains that `SQL.query!` raises on DB failure so the unconditional `:ok` is "completed without raising".

- [x] **W-6** Replaced `length(rows) < 2` with `[]`/`[_]`/`rows` head pattern match in [`Analytics.compute_ctr_slope/2`](../../../../lib/ad_butler/analytics.ex#L268).

- [x] **W-7** [`Analytics.avg_cpm/1`](../../../../lib/ad_butler/analytics.ex#L356) now returns `{:error, :insufficient}` (tagged tuple). The single caller (`get_cpm_change_pct/1`) already used `with` + `else _ -> nil` so no callsite change needed; tests stayed green.

- [x] **W-8** [`FindingDetailLive`](../../../../lib/ad_butler_web/live/finding_detail_live.ex#L73) render now has a `<div :if={!@finding}>` block showing a "Loading finding…" placeholder + back link on disconnected first paint.

### SUGGESTIONs (4)

- [x] **S-8** [`simple_linear_slope/1`](../../../../lib/ad_butler/analytics.ex#L373) now uses `Enum.zip_reduce/4` instead of `Enum.zip |> Enum.reduce`.

- [x] **S-9** Moved `Ads.list_ad_accounts/1` out of `load_findings/1` into the `:reload_on_reconnect` handler ([findings_live.ex:94-103](../../../../lib/ad_butler_web/live/findings_live.ex#L94)). Now fetched once per session, not on every filter/page click.

- [x] **S-10** [`Finding`](../../../../lib/ad_butler/analytics/finding.ex#L1-L17) `@moduledoc` rewritten to name both writers, list all six kinds, and explain the partial unique index + MapSet pre-check pattern.

- [x] **S-11** Added inline comment at [`audit_scheduler_worker.ex:36-37`](../../../../lib/ad_butler/workers/audit_scheduler_worker.ex#L36) marking the kill-switch as intentionally runtime — guards against future refactor to a compile-frozen `@fatigue_enabled` module attribute.

---

## Skipped

(none)

## Deferred (carried from pass-3)

- **S-6** — `handle_create_result/N` arity asymmetry between leak vs fatigue worker. Intentional per pass-3 review.
- **S-7** — Tenant-isolation test could pin firing-precondition explicitly. Preventive.

Both stay deferred unless re-prioritized later.

---

## Affinity Grouping (for fix planning)

| File | Items |
|------|-------|
| `lib/ad_butler/analytics.ex` | W-6, W-7, S-8 |
| `lib/ad_butler/workers/creative_fatigue_predictor_worker.ex` | W-4 |
| `lib/ad_butler/ads.ex` | W-5 (doc-only) |
| `lib/ad_butler_web/live/finding_detail_live.ex` | W-8 |
| `lib/ad_butler_web/live/findings_live.ex` | S-9 |
| `lib/ad_butler/analytics/finding.ex` | S-10 |
| `lib/ad_butler/workers/audit_scheduler_worker.ex` | S-11 |

7 files, ~9 items. Most are <5-line fixes; W-7 has a one-callsite ripple (`get_cpm_change_pct/1`); W-8 needs the most thought (LV UX choice).

---

## Test Impact

- W-7 (`:insufficient` → `{:error, :insufficient}`) may break tests asserting on the bare atom. Verify: `grep -r ':insufficient' test/`.
- W-6 (head pattern match) — should not change behavior; existing tests must still pass.
- W-8 (disconnected render) — add a test for the disconnected mount path.
- Other items are doc/comment/perf and shouldn't need new tests.

Run `mix test test/ad_butler/analytics_test.exs test/ad_butler_web/live/finding_detail_live_test.exs test/ad_butler_web/live/findings_live_test.exs test/ad_butler/workers/creative_fatigue_predictor_worker_test.exs` after fixes.
