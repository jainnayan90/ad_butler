# Scratchpad: week8-review-fixes

## Dead Ends (DO NOT RETRY)

(none yet — fresh plan)

## Decisions

### From the post-week8-fixes review triage

- **B2**: chose tagged-tuple `{:error, {:invalid_kind, kind}}` over fail-fast crash. More defensive, callers must handle the error path. Worker uses internal-controlled kinds so its `{:error, _}` branch can `raise "BUG"`.
- **B3**: stringify in `build_factors_map/1` at construction so atom-key writes never reach Postgres. Avoids the post-Postgres mismatch entirely. The `format_predictive_clause` and `build_evidence` reads are updated to string keys.
- **W6**: add `tenant_filter_results/2` to `Embeddings` context now (rather than waiting for W9 Chat context). Migrate later when Chat exists.
- **W7**: just docstring tightening — actual `content_excerpt` UI filtering happens at the W9 caller, not here.
- **All 8 SUGGESTIONs skipped** — see triage rationale.

### Carried over from week8-fixes

- `fatigue_factors` map keys: top-level strings, inner `values` map will now ALSO be strings (B3 fix). Pattern matchers must use string keys throughout after this plan.
- `Ecto.UUID.dump!(ad.id)` is wrong for `bulk_insert_fatigue_scores/1` entries — pass `ad.id` directly.
- `cast_uuid` helper in `Analytics.unsafe_list_insights_window_for_ads/2` is fine — Postgres returns binary UUID for raw-table queries.

## Open Questions

- **P6-T1 / W6 helper location**: `Embeddings.tenant_filter_results/2` is in the Embeddings context, but its implementation reaches into `Ads` and `Analytics` for tenant lookups. Cross-context call from Embeddings → Ads / Analytics is allowed (per CLAUDE.md, Embeddings calls `Ads.list_*` etc.; just not the inverse Ecto query construction). Confirm during implementation.
- **W5**: does `Oban.drain_queue` cooperate with the test's `Mox.expect` ordering? The smoke test today uses `set_mox_from_context` + ordered `expect`s. Drain runs jobs in insertion order so the contract should hold; verify post-implementation.

## Handoff

- Branch: main (uncommitted, piled on top of week8-fixes)
- Plan: .claude/plans/week8-review-fixes/plan.md (all 28 tasks ✓)
- Triage: .claude/plans/week8-fixes/reviews/week8-fixes-triage.md
- Per-agent reviews from this cycle:
  - elixir-reviewer: 0 BLOCKER, 3 WARNING (DRY @valid_kinds ✓ fixed; N+1 in tenant_filter — deferred to Chat per moduledoc TODO; bulk_upsert spec note ✓ addressed by drop dead branch)
  - oban-specialist: 0 BLOCKER, 2 WARNING (snooze precedence ✓ fixed by re-ordering; pre-existing snooze-comment lie at line 159 — NOT in scope of this plan, deferred)
  - security-analyzer: 0 BLOCKER, 1 WARNING (unknown-kind leak ✓ fixed via fail-closed three-way split)
  - testing-reviewer: 0 BLOCKER, 3 WARNING (test name ✓ renamed; drain assertion stays loose per plan; second-test-split deferred)
- Solution docs added this cycle:
  - `.claude/solutions/ecto/per-kind-tenant-filter-after-knn-fail-closed-20260501.md`
  - `.claude/solutions/oban/error-precedence-over-snooze-in-multi-step-perform-20260501.md`
- Solution docs from prior cycle (still relevant):
  - `.claude/solutions/ecto/bulk-upsert-context-wrapper-keeps-repo-boundary-20260430.md`
  - `.claude/solutions/oban/snooze-on-rate-limit-not-error-20260430.md`
  - `.claude/solutions/testing-issues/hnsw-pgvector-knn-needs-orthogonal-vectors-20260430.md`
- Final verification: 449 tests pass, 9 excluded, integration smoke clean. credo --strict 0 issues. Format clean. check.unsafe_callers clean.
- Next: commit changes; address pre-existing snooze-comment misinformation in a separate small PR if needed.
