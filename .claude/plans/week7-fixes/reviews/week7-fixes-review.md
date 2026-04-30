# Week 7 Review-Fixes — Consolidated Review

**Plan:** [.claude/plans/week7-fixes/plan.md](../plan.md)
**Verdict:** PASS WITH WARNINGS
**Reviewers:** elixir-reviewer, testing-reviewer, oban-specialist, iron-law-judge

## Summary

All 14 plan items landed. 395 tests pass, no new credo issues, `mix check.unsafe_callers` passes. The bulk JSONB UPDATE escape hatch is justified, the `reduce_while` halt-on-error restructure mirrors the BudgetLeakAuditorWorker pattern correctly, retry-safety holds (verified via the four-step trace in oban-specialist's review), and tenant scope is intact.

**1 WARNING, 4 SUGGESTIONS** worth addressing before next cut. All findings are non-blocking — none required to ship the W7 review fixes.

---

## Findings

### WARNING

#### W-1: Findings unique-constraint not handled in changeset → noisy retries on dedup race
**File:** [lib/ad_butler/analytics/finding.ex:43-49](../../../../lib/ad_butler/analytics/finding.ex#L43)
**Source:** oban-specialist
**Scope:** PRE-EXISTING — affects both `BudgetLeakAuditorWorker` and `CreativeFatiguePredictorWorker`. Not introduced by this fix set.

`Finding.create_changeset/2` lacks a `unique_constraint(:kind, name: :findings_ad_id_kind_unresolved_index)`. If two concurrent workers race past the `MapSet.member?` pre-check and both call `Repo.insert`, Postgres raises a unique violation that surfaces as a raw `{:error, %Ecto.InvalidChangesetError{...}}`. Under the new `reduce_while` halt-on-error path this propagates → `audit_account/1` returns `{:error, _}` → Oban logs ERROR + retries. On retry the MapSet picks up the dedup so the job completes. No data loss; just noisy logs and a wasteful retry.

**Fix:** Add the `unique_constraint` to `create_changeset/2`, then in both workers' `maybe_emit_finding/N`, pattern-match the constraint changeset error and return `:skipped` to keep the score-emit path intact.

### SUGGESTIONS

#### S-1: Tenant-isolation test CTR-slope formula is correct but counter-intuitive
**File:** [test/ad_butler/workers/creative_fatigue_predictor_worker_test.exs ~line 479](../../../../test/ad_butler/workers/creative_fatigue_predictor_worker_test.exs#L479)
**Source:** testing-reviewer (downgraded from BLOCKER — math is correct, only the readability is at risk)

`clicks = 80 - (6 - d) * 10` for `d=0..6` produces a genuinely decreasing CTR when sorted oldest→newest, so the heuristic does fire. But the formula reads "newer days have fewer clicks" which is opposite to a typical "declining CTR" mental model. A future maintainer rewriting this could flip the direction and silently break the regression guard (the test would still pass — account B gets zero scores either way).

**Fix:** Add a one-line comment or rewrite as `clicks = 20 + (6 - d) * 10` (same numbers, intent-explicit).

#### S-2: `async: false` rationale on the worker test is misleading
**File:** [test/ad_butler/workers/creative_fatigue_predictor_worker_test.exs:3-4](../../../../test/ad_butler/workers/creative_fatigue_predictor_worker_test.exs#L3)
**Source:** testing-reviewer

The comment says "heuristics read shared insights_daily partitions"; the actual hazard is `CREATE TABLE` DDL inside `setup` blocks (DDL is not transactional and races under sandbox checkouts). `analytics_test.exs` runs `async: true` despite calling the same `create_insights_partition` helper — the inconsistency will confuse a reviewer.

**Fix:** Replace the comment with the real reason, e.g. *"`async: false` — setup creates partitions via DDL which is not transactional"*.

#### S-3: All-nil-rankings test asserts only `:ok`, not DB state
**File:** [test/ad_butler/ads_test.exs ~line 449](../../../../test/ad_butler/ads_test.exs#L449)
**Source:** testing-reviewer

`Ads.append_quality_ranking_snapshots/2` could silently insert a null-filled snapshot and still return `:ok`. Add an assertion that the row's `quality_ranking_history` is unchanged (still `%{"snapshots" => []}` or nil).

#### S-4: `find_drop/4` early-skip relies on an undocumented ordering invariant
**File:** [lib/ad_butler/workers/creative_fatigue_predictor_worker.ex ~line 162](../../../../lib/ad_butler/workers/creative_fatigue_predictor_worker.ex#L162)
**Source:** elixir-reviewer

When `Date.compare(snap_date, cutoff) == :lt` the function returns `:skip` immediately — this is correct only because `[latest | older] = Enum.reverse(snapshots)` guarantees `older` is newest-to-oldest. A future change to the snapshot ordering would silently break the lookback. One-line comment to pin the invariant.

#### S-5: `Ads.unsafe_build_ad_set_map(ad_account.id) |> Map.keys()` — context API gap
**File:** [lib/ad_butler/workers/creative_fatigue_predictor_worker.ex:214](../../../../lib/ad_butler/workers/creative_fatigue_predictor_worker.ex#L214)
**Source:** elixir-reviewer

Discards the `ad_set_id` values immediately. An explicit `Ads.unsafe_list_ad_ids_for_account/1` would document the worker's actual intent and keep query-shape decisions in the context. Cheap to add, but cosmetic.

---

## Rejected Findings

#### Rejected: "BLOCKER — `Ecto.UUID.dump!/1` causes Postgrex to encode binaries as `bytea`" (elixir-reviewer)
**Verification:** The 30-ad bulk-write test passes (`mix test test/ad_butler/ads_test.exs:364` — 72ms). The earlier test run actually failed with the *opposite* error — *"Postgrex expected a binary of 16 bytes"* when we tried to pass string UUIDs without `dump!`. Postgrex's UUID extension correctly encodes 16-byte binaries to PostgreSQL `uuid` type when the parameter cast is `::uuid[]` (the cast disambiguates the encoder). The reviewer's claim that the binary becomes `bytea` is incorrect for typed parameters.

#### Deconfliction: AuditHelpers `@moduledoc false` + `@doc`
**oban-specialist** flagged this as a SUGGESTION; **iron-law-judge** confirms it's compliant. Per the deconfliction rule, iron-law-judge's interpretation prevails: `@moduledoc false` is an ExDoc-visibility decision; CLAUDE.md's "every public def needs `@doc`" still applies and is satisfied.

---

## Iron Law Compliance

**iron-law-judge: 0 violations.** Confirmed clean across 8 changed `.ex` files: tenant-scoped queries on user-facing paths, structured logging with `kind:` metadata in `format_fatigue_values/2` fallback, head-pattern-match split on `detect_quality_drop`, `Ecto.Adapters.SQL.query!` confined to the `Ads` context (Repo-boundary intact), parameterized SQL (no string interpolation), all `@moduledoc`/`@doc` coverage complete.

---

## Verification State

| Check | Result |
|---|---|
| `mix compile --warnings-as-errors` | ✓ |
| `mix format --check-formatted` | ✓ |
| `mix credo --strict` | ✓ (only 2 pre-existing issues, declared OOS in plan) |
| `mix check.unsafe_callers` | ✓ |
| `mix test` | ✓ 395 tests, 0 failures |
| `mix hex.audit` | ✓ no retired packages |
