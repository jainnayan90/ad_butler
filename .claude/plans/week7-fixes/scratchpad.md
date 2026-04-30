# Scratchpad: week7-fixes

## Dead Ends (DO NOT RETRY)

- DO NOT try to merge `quality_ranking_history` JSONB append into the `bulk_upsert_ads` `on_conflict` clause. Postgres `ON CONFLICT DO UPDATE` evaluates one expression per row but cannot read the existing row's JSONB array and concat in a single literal. The W7D3-T2 plan attempted this and abandoned it for the read-modify-write split — see plan note "outside the upsert because Postgres ON CONFLICT can't atomically tail an array".
  - **The fix in B1 keeps that split** (read existing in one query, compute in app), but replaces the per-ad UPDATE loop with a single bulk `insert_all` using `on_conflict: {:replace, [:quality_ranking_history]}, conflict_target: [:id]`. The read query already exists in `load_existing_history/1` — only the write side is the N+1 violator.

## Decisions

- **B2 fix shape: emit fatigue_score for every audited ad** (not transaction-wrap, not pre-write). Score upsert is idempotent; emitting it always means retries don't lose data even if dedup hides the finding. Mirrors BudgetLeakAuditorWorker's "always write health score per ad" approach.
- **W6 kill-switch lands in `config/runtime.exs`** (read `System.get_env("FATIGUE_ENABLED", "true") == "true"`). Mention in `.env.example`. Update moduledoc to match.
- **S13 `six_hour_bucket/0` extraction target: `lib/ad_butler/workers/audit_helpers.ex`** with `@moduledoc false`. Both audit workers call it. No public surface; internal only.

## Open Questions

(none)

## Handoff

- Branch: main (uncommitted W7 work + new fixes will stack on top)
- Plan: .claude/plans/week7-fixes/plan.md
- Source review: .claude/plans/v0.3-creative-fatigue-chat-mvp/reviews/week7-review.md
- Triage: .claude/plans/v0.3-creative-fatigue-chat-mvp/reviews/week7-triage.md

## API Failure — 2026-04-30 13:53

Turn ended due to API error. Check progress.md for last completed task.
Resume with: /phx:work --continue
