# Scratchpad: week8-followup-fixes

## Dead Ends (DO NOT RETRY)

(none yet — fresh plan)

## Decisions

### From the post-week8-review-fixes triage

- **B1 migration tweak**: amend in place (unreleased). Test DB needs reset to pick up the new constraint.
- **Sec WARN-1**: implement `Embeddings.scrub_for_user/1` now (don't defer to W9). Idempotent. Composes after `tenant_filter_results/2`.
- **Testing W2**: decouple by using raw string literal `"#{ad.name} | "` in hash assertions; the `describe "ad_content/1"` block locks the format independently.
- **Ecto W1**: schema-side only. DB-level FK already exists at
  `priv/repo/migrations/20260427000001_create_ad_health_scores.exs:7` with
  `on_delete: :delete_all`. No new migration needed.
- **Snooze comment fix**: rewrite to be accurate (snoozes DO consume an attempt under standard Oban OSS). Don't claim auto-bump.
- **Worker timeout**: 5 min for `EmbeddingsRefreshWorker` — sequential Repo + HTTP path, lifeline rescues at 30 min as backstop.
- **All 8 SUGGESTIONs in scope**: user opted to fold them in rather than batch into a separate PR.

## Open Questions

- **P5 struct shape**: switching `field :ad_id` → `belongs_to :ad` may affect any code that does `%AdHealthScore{} = ...` exhaustive matching. Pre-impl grep `grep -rn "%AdHealthScore{" lib test` will enumerate sites.
  - RESOLVED: 3 sites (`test/support/factory.ex:112`, `lib/ad_butler/analytics.ex:188`, `:386`); all open struct usage, no exhaustive match. No change needed.
- **P7-T1 (`Path.safe_relative/2`)**: project is on Elixir 1.18 per verification report — safe.
  - RESOLVED: verified contract via REPL — `Path.safe_relative("billing.md", "/tmp/help") => {:ok, "billing.md"}`; `"../../etc/passwd" => :error`. First arg must be relative; use `Path.relative_to/2` first.

## Resolved (this session)

- All 25 plan tasks shipped + 2 review-cycle fixes (B1 snooze comment, D1 cross-context schema dep). 454 tests pass, credo --strict clean, format clean.
- Pre-existing flaky test: `test/ad_butler_web/live/findings_live_test.exs:101` (`:reload_on_reconnect`) attaches a global telemetry handler on `ad_accounts` `LIMIT 200` queries; concurrent async tests can leak the message into its mailbox. Passes in isolation. Not caused by any change in this PR. Out-of-scope to fix here.
- Reviewer findings triaged: 1 Warning + 1 Suggestion both verified-safe (Path.safe_relative correct; `inserted_at` has DB default `NOW()` per `20260427000001_create_ad_health_scores.exs:14`).
- Out-of-scope reviewer suggestions intentionally skipped per CLAUDE.md "no scope creep": broader length→Enum.count migration, structural enforcement of scrub_for_user chain (defer to W9 chat-tool PR).

## Handoff

- Branch: main (uncommitted from week8-review-fixes; will pile on top)
- Plan: .claude/plans/week8-followup-fixes/plan.md
- Triage: .claude/plans/week8-review-fixes/reviews/week8-review-fixes-triage.md
- Per-agent reviews: .claude/plans/week8-review-fixes/reviews/{elixir,oban,ecto,security,testing,iron-law,verification}-review.md
- Solution docs from prior cycles (still relevant):
  - `.claude/solutions/ecto/per-kind-tenant-filter-after-knn-fail-closed-20260501.md`
  - `.claude/solutions/oban/error-precedence-over-snooze-in-multi-step-perform-20260501.md`
  - `.claude/solutions/ecto/bulk-upsert-context-wrapper-keeps-repo-boundary-20260430.md`
  - `.claude/solutions/oban/snooze-on-rate-limit-not-error-20260430.md`
  - `.claude/solutions/testing-issues/hnsw-pgvector-knn-needs-orthogonal-vectors-20260430.md`
- Next: (to be filled on session end)
