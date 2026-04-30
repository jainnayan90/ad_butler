# Week 7 Review-Fixes — Triage Decisions

**Source review:** [week7-fixes-review.md](week7-fixes-review.md)
**Decision:** All 6 findings approved for fix in this branch.

## Fix Queue (6)

### Warnings

- [x] **W-1** [hardening] Add `unique_constraint` to `Finding.create_changeset/2` and pattern-match the constraint changeset error in both workers' `maybe_emit_finding/N`.
  - **File:** [lib/ad_butler/analytics/finding.ex:43-49](../../../lib/ad_butler/analytics/finding.ex#L43)
  - **Workers to update:**
    - [lib/ad_butler/workers/budget_leak_auditor_worker.ex `maybe_emit_finding/4`](../../../lib/ad_butler/workers/budget_leak_auditor_worker.ex#L365)
    - [lib/ad_butler/workers/creative_fatigue_predictor_worker.ex `maybe_emit_finding/5`](../../../lib/ad_butler/workers/creative_fatigue_predictor_worker.ex)
  - **Approach:** in changeset, `|> unique_constraint(:kind, name: :findings_ad_id_kind_unresolved_index)`. In each worker's `maybe_emit_finding`, match `{:error, %Ecto.Changeset{errors: [kind: {_, [constraint: :unique, ...]}]}}` and return `:skipped` (mirror the existing dedup branch). Audit_account/build_entries continues unchanged — `_ok_or_skipped -> {:ok, build_entry(...)}` already covers it.

### Suggestions

- [x] **S-1** [test-clarity] Rewrite the CTR-slope formula in the tenant-isolation test or add a comment so the intent ("declining CTR over the 7-day window") is explicit.
  - **File:** [test/ad_butler/workers/creative_fatigue_predictor_worker_test.exs ~line 479](../../../test/ad_butler/workers/creative_fatigue_predictor_worker_test.exs#L479)
  - **Approach:** prefer `clicks = 20 + (6 - d) * 10` (numerically identical) — newer days (`d` smaller) have fewer clicks, which reads naturally as "CTR is declining toward today."

- [x] **S-2** [test-clarity] Replace the `async: false` comment with the real reason: setup creates partitions via DDL which is not transactional in Postgres.
  - **File:** [test/ad_butler/workers/creative_fatigue_predictor_worker_test.exs:3-4](../../../test/ad_butler/workers/creative_fatigue_predictor_worker_test.exs#L3)
  - **Approach:** one-line comment swap.

- [x] **S-3** [test-coverage] Add a DB-state assertion to the all-nil-rankings test in `append_quality_ranking_snapshots/2`.
  - **File:** [test/ad_butler/ads_test.exs ~line 449](../../../test/ad_butler/ads_test.exs#L449)
  - **Approach:** after `assert :ok = ...`, reload the row and assert `quality_ranking_history` is unchanged (still nil or `%{"snapshots" => []}`).

- [x] **S-4** [doc] Add a one-line comment to `find_drop/4` pinning the newest-to-oldest ordering invariant of `older`.
  - **File:** [lib/ad_butler/workers/creative_fatigue_predictor_worker.ex ~line 162](../../../lib/ad_butler/workers/creative_fatigue_predictor_worker.ex#L162)
  - **Approach:** comment above the `Date.compare(snap_date, cutoff) == :lt -> :skip` clause: `"# `older` is reversed (newest first); first-out-of-window means all remaining are too — safe to early-skip."`

- [x] **S-5** [context-API] Add `Ads.unsafe_list_ad_ids_for_account/1` and replace `Ads.unsafe_build_ad_set_map(ad_account.id) |> Map.keys()` in the predictor worker.
  - **Files:**
    - Add to [lib/ad_butler/ads.ex](../../../lib/ad_butler/ads.ex)
    - Update [lib/ad_butler/workers/creative_fatigue_predictor_worker.ex:214](../../../lib/ad_butler/workers/creative_fatigue_predictor_worker.ex#L214)
  - **Approach:** new `defp` not needed — public `unsafe_*` function returning `[binary()]`. Single `select([a], a.id)` query.

---

## Skipped

(none)

## Deferred

(none)

---

## Next steps

- `/phx:work .claude/plans/week7-fixes/reviews/week7-fixes-triage.md` — execute the 6 fixes ad-hoc (approaches are pre-decided per item).
- `/phx:plan .claude/plans/week7-fixes/reviews/week7-fixes-triage.md` — phase-grouped fix plan (probably overkill for 6 small items).
- `/phx:compound` — capture the dedup retry-safety pattern + the JSONB-append upsert pattern after fixes land.
