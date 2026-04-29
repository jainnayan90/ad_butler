# Triage: week-2-auditor-review-fixes

**Review verdict:** REQUIRES CHANGES
**Triage result:** 16 to fix · 3 skipped

---

## Fix Queue

### BLOCKERs

- [ ] **B1** [Iron Law] Move Repo calls out of `BudgetLeakAuditorWorker` — `load_48h_insights/1`, `build_ad_set_map/1`, `load_stalled_learning_ad_sets/1` must become context functions in `AdButler.Ads` or `AdButler.Analytics`
- [ ] **B2** Propagate `maybe_emit_finding/3` errors through `fire_if_triggered/4` → `run_heuristics/5` → `reduce_while` accumulator so Oban retries on finding creation failures
- [ ] **B3** Add `unique: [period: 21_600, keys: [:ad_account_id]]` to `use Oban.Worker` in `BudgetLeakAuditorWorker` module declaration
- [ ] **B4** Add `import Ecto.Query` to `test/ad_butler/analytics_test.exs` (compile error — `from/2` used without import)
- [ ] **B5** Add tests for `handle_event("filter_changed", ...)` and `handle_event("paginate", ...)` in `test/ad_butler_web/live/findings_live_test.exs`
- [ ] **B6** Add test for acknowledge `{:error, _}` flash path in `test/ad_butler_web/live/finding_detail_live_test.exs`

### WARNINGs

- [ ] **W1** Add `User` param or explicit `@doc` ownership disclaimer to `Analytics.get_latest_health_score/1` — latent tenant leak risk
- [ ] **W2** Preload all 30d baselines for the account before `Enum.reduce` in `BudgetLeakAuditorWorker` — eliminates N+1 in `check_cpa_explosion`
- [ ] **W3** Rename `upsert_ad_health_score/1` → `insert_ad_health_score/1` everywhere; update `@doc` to clarify append-only + non-idempotent under retries
- [ ] **W4** Handle `Oban.insert_all/1` return in `AuditSchedulerWorker.perform/1` — log or propagate error if fan-out fails
- [ ] **W5** Guard `paginate_findings` in `FindingsLive.handle_params/3` with `if connected?(socket)` — avoid double query on initial page load
- [ ] **W6** Load `ad_accounts` unconditionally in `FindingsLive.handle_params/3` — remove stale cache pattern
- [ ] **W7** Replace `Float.round` with integer arithmetic for cents in `BudgetLeakAuditorWorker` finding body strings
- [ ] **W8** Remove `@doc false` from `defp maybe_emit_finding/3` in `BudgetLeakAuditorWorker`

### Suggestions

- [ ] **S1** Extract `severity_badge_class/1` and `kind_label/1` to shared helper module (e.g. `AdButlerWeb.FindingHelpers`) — currently duplicated in `FindingsLive` and `FindingDetailLive`
- [ ] **S3** Add `placement_drag` skip test (single placement or ratio < 3x) and `dead_spend` reach-uplift guard skip test (growing reach should skip even with zero conversions)

---

## Skipped

- S2 — Tag `with` clauses in `check_cpa_explosion` (style, low priority)
- S4 — Uniqueness test should exercise worker config not override (minor test quality)
- S5 — Re-acknowledge test timestamp assertion (minor assertion gap)
