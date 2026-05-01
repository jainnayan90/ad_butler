# Review: week8-followup-fixes

**Round 3 Verdict: PASS** — B1 + D1 both resolved. iron-law-judge confirms 0 violations. Verification gates all green (format, compile, credo --strict, 454/454 tests). One pre-existing flaky test (`findings_live_test.exs:101`) noted in scratchpad — unrelated to this PR.

**Round 2 Verdict (historical): PASS WITH ONE DEBATABLE DESIGN CALL** — B1 resolved post-/phx:review Round 1; D1 (context boundary) still pending user decision.

**Round 1 Verdict (historical): REQUIRES CHANGES** — 1 BLOCKER (real), 1 DEBATABLE design call worth user input.

## Scope reviewed

25 plan tasks across 8 phases. Files changed:

- `lib/ad_butler/embeddings.ex` (+`scrub_for_user/1`, moduledoc chain)
- `lib/ad_butler/embeddings/embedding.ex` (`@timestamps_opts`)
- `lib/ad_butler/analytics.ex` (`Enum.sum_by`, `Enum.count`)
- `lib/ad_butler/analytics/ad_health_score.ex` (`belongs_to :ad`, `foreign_key_constraint`)
- `lib/ad_butler/workers/embeddings_refresh_worker.ex` (`timeout/1`, snooze comment)
- `lib/mix/tasks/ad_butler.seed_help_docs.ex` (`Path.safe_relative/2`)
- `priv/repo/migrations/20260501000002_create_embeddings.exs` (`null: false`)
- `priv/repo/migrations/20260501000003_add_embeddings_hnsw_index.exs` (comment only)
- `test/ad_butler/embeddings_test.exs`, `test/ad_butler/workers/embeddings_refresh_worker_test.exs`, `test/ad_butler/integration/week8_e2e_smoke_test.exs`

Verification gates: `mix format --check-formatted` ✓, `mix compile --warnings-as-errors` ✓, `mix credo --strict` ✓ (908 mods/funs, 0 issues), `mix check.unsafe_callers` ✓, `mix test` 454/454 ✓, integration smoke ✓.

## BLOCKERS

### B1 — RESOLVED (Round 2)

User fixed the snooze comment after Round 1. Re-verified by oban-specialist against `deps/oban/lib/oban/engines/basic.ex:263-272`. Lines 168-176 of `embeddings_refresh_worker.ex` now correctly state that snoozes do NOT consume retry budget under Oban OSS basic engine (`inc: [max_attempts: 1]` compensates).

---

### B1 (Round 1, historical) — Snooze comment was technically incorrect

`lib/ad_butler/workers/embeddings_refresh_worker.ex:161-170`

The PR replaced "Oban auto-bumps max_attempts on snooze" (correct) with "Snoozes DO consume an attempt under standard Oban OSS" (incorrect).

**Verified against `deps/oban/lib/oban/engines/basic.ex:263-272`:**

```elixir
def snooze_job(%Config{} = conf, %Job{id: id}, seconds) when is_integer(seconds) do
  updates = [
    set: [state: "scheduled", scheduled_at: seconds_from_now(seconds)],
    inc: [max_attempts: 1]
  ]
  ...
```

Net: `inc: [max_attempts: 1]` compensates for the attempt counter incremented at job start. Snooze does NOT consume retry budget in Oban OSS basic engine.

**Suggested replacement:**

```elixir
# Match ReqLLM's rate-limit shape (HTTP 429) and the simpler atom returned by
# tests/mocks. Snoozing for 90s keeps the next attempt outside the typical
# 60s rate-limit window so a single retry usually clears.
#
# Under Oban OSS basic engine, snooze_job/3 does `inc: [max_attempts: 1]`
# (deps/oban/lib/oban/engines/basic.ex:263-272) — snoozes do NOT consume
# retry budget. `max_attempts: 3` therefore covers three genuine error
# retries independent of how many times the job is snoozed for rate limits.
```

This is a comment-only change but it's a real BLOCKER because the wrong comment will mislead the next reader debugging max_attempts behaviour.

## DEBATABLE

### D1 — Context boundary: `belongs_to :ad, AdButler.Ads.Ad` introduces cross-context schema dep

`lib/ad_butler/analytics/ad_health_score.ex:26` (P5-T1)

iron-law-judge raised this. CLAUDE.md says "Context boundaries are real: `AdButler.Chat` may call `AdButler.Ads.list_ads/1`; it may never reach into `AdButler.Ads.Query` or build Ecto queries directly." A schema-level `belongs_to` to `AdButler.Ads.Ad` is debatable: standard Phoenix/Ecto idiom, but does compile-time-couple `Analytics` to `Ads`.

The prior `field :ad_id, :binary_id` carried no schema dep. The triage doc that fed this plan explicitly chose `belongs_to` for changeset ergonomics (`foreign_key_constraint(:ad_id)`).

**Options:**
1. **Keep belongs_to** — accept the dep; gain `Repo.preload/3` ergonomics and `foreign_key_constraint/2` on the changeset. Standard Phoenix.
2. **Revert to `field :ad_id, :binary_id`** — keep `foreign_key_constraint(:ad_id)` (works on raw FK fields too); zero compile-time cross-context coupling.

User decision needed. Plan chose (1); judge prefers (2).

## DEFERRED / OUT OF SCOPE

- **Sec W1 (security-analyzer)**: `scrub_for_user/1` chain not structurally enforced. Defer to Week-9 chat-tool PR (no non-test callers today).
- **Elixir consistency (elixir-reviewer)**: broader `length/1` → `Enum.count/1` migration in `analytics.ex` and `embeddings_refresh_worker.ex`. Plan was scoped narrowly. Cosmetic.
- **Testing S1 (testing-reviewer)**: unknown-kind test for `scrub_for_user/1`. Function uses two clauses (`%Embedding{kind: "doc_chunk"}` + catch-all `%Embedding{}`); behaviour is well-defined.

## VERIFIED CLEAN (no action)

- Path.safe_relative/2 usage (security-analyzer S1).
- ad_health_scores `inserted_at` plain field — DB has `default: fragment("NOW()")` per `migrations/20260427000001_create_ad_health_scores.exs:14`.
- Migration amend-in-place (unreleased).
- All test changes (testing-reviewer APPROVED).

## Recommended next step

Fix B1 (5-minute comment edit). Decide D1 (yes/no). Then ship.
