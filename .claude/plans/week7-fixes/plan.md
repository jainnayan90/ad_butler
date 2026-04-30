# Plan: Week 7 Review Fixes

**Source:** [.claude/plans/v0.3-creative-fatigue-chat-mvp/reviews/week7-triage.md](../v0.3-creative-fatigue-chat-mvp/reviews/week7-triage.md)
**Scope:** 14 findings (3 BLOCKER, 6 WARNING, 5 SUGGESTION) — all approved, all queued.

## Goal

Land all 14 fixes from the Week 7 review with no regressions. Approaches are pre-decided in the triage file; this plan groups them into phases by file affinity to minimize re-touches.

---

## Phases

### Phase 1 — Context layer (Ads + Analytics + Schema doc)

- [ ] [P1-T1][ecto] **B1** Replace N+1 loop in [`Ads.append_quality_ranking_snapshots/2`](../../../lib/ad_butler/ads.ex) ([lib/ad_butler/ads.ex:550-561](../../../lib/ad_butler/ads.ex#L550)) with a single bulk write. Keep the existing `load_existing_history/1` bulk read; build a list of `%{id, quality_ranking_history, inserted_at, updated_at}` entries in app code; one `Repo.insert_all(Ad, entries, on_conflict: {:replace, [:quality_ranking_history, :updated_at]}, conflict_target: [:id])`. Verify with new test seeding 30 ads + asserting one query in the upsert path.

- [ ] [P1-T2][ecto] **W4** Drop redundant boolean guard in [`Analytics.get_cpm_change_pct/2`](../../../lib/ad_butler/analytics.ex#L348) — remove `with true <- prior_cpm > 0`. `avg_cpm/1` already returns `:insufficient` for zero spend; the guard is dead code that violates Iron Law #8.

- [ ] [P1-T3][ecto] **S11** Drop unused `_window_days` parameter from `Analytics.get_cpm_change_pct/2`. Make it 1-arity. Update the single call site in `creative_fatigue_predictor_worker.ex` (`heuristic_cpm_saturation/1`).

- [ ] [P1-T4] **W7** Rewrite `@moduledoc` on [`AdButler.Analytics.AdHealthScore`](../../../lib/ad_butler/analytics/ad_health_score.ex#L3) to mention both writers (BudgetLeakAuditor + CreativeFatiguePredictor) and the column-isolation strategy on conflict.

### Phase 2 — Worker correctness rebuild

The blocker fixes B2/B3 + warning W5 + suggestion S10 all touch the same `audit_account` reduce loop. Treat as one cohesive restructure.

- [ ] [P2-T1][oban] **B3** Pattern-match in heads for [`detect_quality_drop/1`](../../../lib/ad_butler/workers/creative_fatigue_predictor_worker.ex#L134). Replace `when length(snapshots) < 2` with `defp detect_quality_drop([])` + `defp detect_quality_drop([_])` + generic.

- [ ] [P2-T2][oban] **B2 + W5 + S10** Restructure `audit_account/1` ([creative_fatigue_predictor_worker.ex:211-250](../../../lib/ad_butler/workers/creative_fatigue_predictor_worker.ex#L211)):
  - Always emit a fatigue-score `entry` for every audited ad — including those where `maybe_emit_finding` returns `:skipped` (dedup). Score upsert is idempotent so retries are safe.
  - Switch `Enum.reduce` → `Enum.reduce_while` (or `with` chain) so a `{:error, reason}` from `maybe_emit_finding` halts and propagates up through `audit_account/1` → Oban retries.
  - Drop the `_emit_count` accumulator; entry list is the only state needed.
  - Mirror BudgetLeakAuditor's `apply_check/5` halt-on-error pattern.

- [ ] [P2-T3][oban] **S13** Extract `six_hour_bucket/0` from both auditor workers into `AdButler.Workers.AuditHelpers` (`@moduledoc false`). Replace inline copies in `creative_fatigue_predictor_worker.ex` and `budget_leak_auditor_worker.ex`.

### Phase 3 — Configuration + LiveView + docs polish

- [ ] [P3-T1] **W6** Move fatigue kill-switch to [`config/runtime.exs`](../../../config/runtime.exs):
  ```elixir
  config :ad_butler, fatigue_enabled: System.get_env("FATIGUE_ENABLED", "true") == "true"
  ```
  Add `FATIGUE_ENABLED` to `.env.example` with comment "true|false (default true) — disable creative-fatigue audits without redeploy". Update `AuditSchedulerWorker` moduledoc to confirm hot-toggle path.

- [ ] [P3-T2][liveview] **S12** Replace `inspect/1` fallback in [`finding_detail_live.ex:233`](../../../lib/ad_butler_web/live/finding_detail_live.ex#L233):
  ```elixir
  defp format_fatigue_values(kind, _values) do
    Logger.warning("format_fatigue_values: unrecognised kind", kind: kind)
    ""
  end
  ```
  Add `:kind` to the Logger metadata allowlist in `config/config.exs` if not already present.

- [ ] [P3-T3] **S14** Update stale POOL_SIZE comment in [`config/config.exs:138`](../../../config/config.exs#L138). New worker totals: 10 + 20 + 5 + 5 + 5 + 5 = 50. Recommend `>= 60` in `.env.example`. Adjust the comment to "fatigue_audit + audit + sync run concurrently — set POOL_SIZE >= 60 in prod".

### Phase 4 — Test cleanup

- [ ] [P4-T1] **W8** Create `test/support/insights_helpers.ex` exporting `insert_daily/3` (canonical version). Accept all attrs (spend_cents, impressions, clicks, frequency, reach_count, cpm_cents, ctr_numeric, by_placement_jsonb). Both `analytics_test.exs` and `creative_fatigue_predictor_worker_test.exs` import it; remove the duplicate `defp insert_daily` from both files.

- [ ] [P4-T2] **W9** Rewrite tenant-isolation test in `creative_fatigue_predictor_worker_test.exs:463-498`:
  - Account A has ads with insights but NO triggering signals (frequency 1.0, stable CTR, equal CPM).
  - Account B has separate ads with all 3 heuristic-firing signals.
  - Run `perform_job(CreativeFatiguePredictorWorker, %{"ad_account_id" => account_a.id})`.
  - Assert: zero findings under account B; zero AdHealthScore rows for account B's ads.
  - Old test (account B has NO ads) is removed — it passed by absence.

- [ ] [P4-T3] Verify integration tests in worker test still pass after P2-T2's reduce_while refactor (existing tests should not need updates if structure is preserved).

### Phase 5 — Verification gate

- [ ] [P5-T1] Format + compile: `mix format && mix compile --warnings-as-errors`
- [ ] [P5-T2] Full test: `mix test` — all 392 tests pass + any new ones added in P1-T1 / P4-T2.
- [ ] [P5-T3] Credo: `mix credo --strict` — no NEW issues introduced (the 1 pre-existing warning + 1 pre-existing nesting issue in `accounts.ex` and `insights_pipeline.ex` are out of scope).
- [ ] [P5-T4] Iron-law: `mix check.unsafe_callers` — must pass.

---

## Risks (and mitigations)

1. **B1 bulk write may conflict with existing on_conflict semantics on `ads`.**
   *Mitigation*: Use a different conflict_target (`[:id]`) and a different replace set (`[:quality_ranking_history, :updated_at]`) than the metadata sync's `bulk_upsert_ads` (which uses `[:ad_account_id, :meta_id]` target). They never compete because `quality_ranking_history` is separate from the `name/status/raw_jsonb` set.

2. **P2-T2 restructure could regress existing integration tests.**
   *Mitigation*: All 6 worker integration tests assert observable behavior (score Decimal value, finding severity, dedup count). Restructure preserves these. Run worker tests immediately after P2-T2.

3. **P3-T1 runtime config change breaks tests that toggle the kill-switch.**
   *Mitigation*: The existing test (`audit_scheduler_worker_test.exs:36-50`) uses `Application.put_env` in test, which still works at runtime — `config/runtime.exs` only sets the initial value. Test path unchanged.

---

## Self-Check

- **Have you been here before?** Yes — most fixes are restating existing patterns from `BudgetLeakAuditorWorker` (halt-on-error reduce, always-emit-score). The novel work is the bulk JSONB upsert in P1-T1.
- **What's the failure mode you're not pricing in?** P1-T1's `on_conflict: {:replace, [:quality_ranking_history, :updated_at]}, conflict_target: [:id]` will succeed on every row because `id` is always populated for upserted ads. But if a metadata sync deletes an ad between `bulk_upsert_ads` and `append_quality_ranking_snapshots`, the bulk insert silently inserts a stub row. *Mitigation*: keep current ordering — append always runs immediately after upsert in the same MetadataPipeline batch; no realistic window for deletion.
- **Where's the Iron Law violation risk?** P2-T2 must keep the worker calling only `Ads.*` and `Analytics.*` — no new `Repo.` calls. P4-T2 must keep `unsafe_*` markers if it adds query helpers.

---

## Acceptance Criteria

- [ ] All 14 triage items checked off.
- [ ] `mix test` passes (≥ 392 tests).
- [ ] `mix credo --strict` introduces no new issues.
- [ ] `mix check.unsafe_callers` passes.
- [ ] N+1 verified eliminated in P1-T1 (single SQL statement for the upsert path).
- [ ] Retry safety verified: kill the process between finding-emit and score-write in a manual `iex` run; on retry, scores are still written.

---

## Out of Scope

- The 2 pre-existing credo issues (`accounts.ex` nesting, `insights_pipeline.ex` Logger metadata).
- Pool size enforcement at runtime — comment-only update; CI/deploy adjustments belong to a separate ops ticket.
- The `:fatigue_enabled` env var being type-checked (boolean parsing accepts only `"true"` literal) — sufficient for v0.3 MVP per CLAUDE.md "validate at boundaries, not internal."
