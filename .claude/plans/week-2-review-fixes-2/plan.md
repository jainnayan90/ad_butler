# Plan: week-2-review-fixes-2

Post-review fix plan from `/phx:triage`. 13 tasks across 5 phases.
Source: `.claude/plans/week-2-auditor-triage-fixes/reviews/week-2-triage.md`
Branch: `v2-week-2Auditor-Findings`

---

## Phase 1 — Analytics context (B1, S3, S4)

- [x] [P1-T1] Fix `acknowledge_finding/2` — replace `get_finding!` with `get_finding/2` + `with` (B1) — updated @spec, updated existing test from assert_raise to {:error, :not_found}
- [x] [P1-T2] Strengthen `@doc` on `unsafe_get_latest_health_score/1` (S3) — added MUST invariant naming get_finding/2 or get_finding!/2
- [x] [P1-T3] Add TOCTOU comment in `maybe_emit_finding/3` (S4) — named partial unique index as DB-level guard

---

## Phase 2 — Workers (W2, W3, W4, S2)

- [x] [P2-T1] Fix `six_hour_bucket/0` midnight race (W2) — replaced Date.utc_today() with DateTime.to_date(now)
- [x] [P2-T2] Capture `Oban.insert_all/1` return and log errors (W3) — captures results, filters {:error,_}, logs count
- [x] [P2-T3] Replace float division with integer arithmetic for ratio comparisons (W4) — cpa_3d*10>baseline*25, div/2 in aggregate_placement_cpas, max*10>min*30
- [x] [P2-T4] Add explicit `keys: []` to `AuditSchedulerWorker` unique config (S2) — added keys: [], added comment

---

## Phase 3 — LiveViews (B2, W5)

- [x] [P3-T1] Add nil-guard function head for `handle_event("acknowledge")` (B2) — guard clause returns {:noreply, socket} when finding is nil
- [x] [P3-T2] Apply allowlist + UUID cast to `handle_params/3` filter params (W5) — severity/kind via @valid_* allowlists, ad_account_id via Ecto.UUID.cast/1

---

## Phase 4 — Code quality (W6)

- [x] [P4-T1] Fix `with false <- is_nil(...)` anti-pattern in `insights_pipeline.ex` (W6) — replaced with guard `normalised when not is_nil(normalised.date_start)`

---

## Phase 5 — Tests (W1, S1, S5)

- [x] [P5-T1] Add `Analytics.get_finding/2` test coverage (W1) — 3 cases: owned, cross-tenant, nonexistent UUID
- [x] [P5-T2] Add health score idempotency test (S1) — new describe "health score upsert", asserts count == 1 after two runs
- [x] [P5-T3] Add `async: false` explanation comments to worker tests (S5) — both test files updated

---

## Verification

Per-phase: `mix compile --warnings-as-errors && mix credo --strict`
Final gate: `mix test` (full suite)

---

## Key Decisions

- **W4 float fix**: Use integer multiplication for comparisons (`cpa_3d * 10 > baseline_cpa * 25`)
  rather than Decimal — avoids new abstractions, comparisons are equivalent. Float ratio kept
  in evidence map as display-only data.
- **P3-T2 UUID cast**: `Ecto.UUID.cast/1` returns `{:ok, uuid} | :error`. Empty string maps to
  `:error` → nil, which `maybe_put` then drops from opts. No new dep needed.
- **B1 spec**: `acknowledge_finding/2` now returns `{:error, :not_found}` via `with` passthrough —
  update `@spec` to include the third variant.
