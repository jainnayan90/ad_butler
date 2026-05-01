# Plan: Week 8 follow-up fixes (post-/phx:review triage)

**Source**: [.claude/plans/week8-review-fixes/reviews/week8-review-fixes-triage.md](../week8-review-fixes/reviews/week8-review-fixes-triage.md)
**Scope**: 15 findings (1 BLOCKER, 4 WARNINGs, 2 pre-existing, 8 SUGGESTIONs).
**Verification**: `mix compile --warnings-as-errors` per task; `mix test <affected>` per phase; `mix credo --strict` + full `mix test` at the end.

## Goal

Resolve every finding from the triage in a single follow-up PR so the v0.3 + Week 8 + Week 8 review-fixes work is mergeable. No new functionality. No deferrals.

## What Exists

- All 28 tasks from `.claude/plans/week8-review-fixes/plan.md` are complete; tests green.
- Triage doc lists every finding with file:line refs, severity, and chosen approach.
- DB-level FK on `ad_health_scores.ad_id` already exists in
  [20260427000001_create_ad_health_scores.exs:7](priv/repo/migrations/20260427000001_create_ad_health_scores.exs#L7) — Ecto W1 fix is **schema-side only** (no new migration).

## Phases

### Phase 1 — BLOCKER (migration tweak)

- [x] [P1-T1][ecto] **B1** — Add `null: false` to `:embedding` column in [priv/repo/migrations/20260501000002_create_embeddings.exs:14](priv/repo/migrations/20260501000002_create_embeddings.exs#L14). Migration is unreleased — amend in place. Verify: `mix ecto.reset` (or drop+migrate) succeeds in test env.

### Phase 2 — Sec WARN-1: scrub_for_user/1 helper

- [x] [P2-T1][ecto] **Sec WARN-1 (part 1)** — Add `Embeddings.scrub_for_user/1` to [lib/ad_butler/embeddings.ex](lib/ad_butler/embeddings.ex) (place near `tenant_filter_results/2`):
  ```elixir
  @doc """
  Returns `rows` with `content_excerpt` set to `nil` for every row whose
  `kind` is NOT `"doc_chunk"`. Use immediately before rendering similarity
  results to user-facing surfaces — `content_excerpt` for ad/finding kinds
  may carry advertiser-typed PII (see `Embedding.@moduledoc`).

  Idempotent. Caller composition: `nearest/3 |> tenant_filter_results/2 |> scrub_for_user/1`.
  """
  @spec scrub_for_user([Embedding.t()]) :: [Embedding.t()]
  def scrub_for_user(rows) when is_list(rows) do
    Enum.map(rows, fn
      %Embedding{kind: "doc_chunk"} = row -> row
      %Embedding{} = row -> %{row | content_excerpt: nil}
    end)
  end
  ```
- [x] [P2-T2][test] **Sec WARN-1 (part 2)** — Add `describe "scrub_for_user/1"` block to [test/ad_butler/embeddings_test.exs](test/ad_butler/embeddings_test.exs):
  - ad-kind row → `content_excerpt` becomes nil
  - finding-kind row → `content_excerpt` becomes nil
  - doc_chunk row → `content_excerpt` preserved
  - empty list → `[]`
  - mixed list → preserves order, scrubs ad/finding only
- [x] [P2-T3][ecto] **Sec WARN-1 (part 3)** — Update `Embeddings` `@moduledoc` to direct callers to the chain `nearest/3 → tenant_filter_results/2 → scrub_for_user/1` for any user-facing surface. Reference the chain from `nearest/3`'s `@doc` as well.

### Phase 3 — Testing W2: decouple hash tests from `ad_content/1`

- [x] [P3-T1][test] **Testing W2** — In [test/ad_butler/workers/embeddings_refresh_worker_test.exs](test/ad_butler/workers/embeddings_refresh_worker_test.exs), replace the three call sites at lines 74, 96, and 127 (`EmbeddingsRefreshWorker.ad_content(...)`) with raw string literals. Format is `"#{ad.name} | "` (creative_name nil → trailing empty after the separator). The `describe "ad_content/1"` block at lines 202–225 already locks the format string, so a future format change will fail those tests independently.

### Phase 4 — Testing W1: strengthen smoke-test drain assertion

- [x] [P4-T1][test] **Testing W1** — In [test/ad_butler/integration/week8_e2e_smoke_test.exs:88](test/ad_butler/integration/week8_e2e_smoke_test.exs#L88), change `assert %{failure: 0} = Oban.drain_queue(queue: :fatigue_audit)` to:
  ```elixir
  assert %{success: success, failure: 0} = Oban.drain_queue(queue: :fatigue_audit)
  assert success >= 1, "expected the predictor job for our ad_account to drain successfully"
  ```
  Keeps the loose-success-count tradeoff but enforces a non-zero floor.

### Phase 5 — Ecto W1 (PRE-EXISTING): AdHealthScore.belongs_to

- [x] [P5-T1][ecto] **Ecto W1 (part 1)** — In [lib/ad_butler/analytics/ad_health_score.ex:26](lib/ad_butler/analytics/ad_health_score.ex#L26), replace `field :ad_id, :binary_id` with:
  ```elixir
  belongs_to :ad, AdButler.Ads.Ad
  ```
  Verify foreign_key column type matches (`@foreign_key_type :binary_id` should already be set at the schema head).
- [x] [P5-T2][ecto] **Ecto W1 (part 2)** — Add `foreign_key_constraint(:ad_id)` to the changeset in `ad_health_score.ex` so a deleted ad surfaces as a clean `{:error, changeset}` instead of a `Ecto.ConstraintError`.
- [x] [P5-T3][test] **Ecto W1 (part 3)** — Verify all existing test sites still pass — most use `ad_id: ad.id` overrides which work for both `field` and `belongs_to`. If any test uses `%AdHealthScore{ad: nil}` introspection, update accordingly. Run [test/ad_butler/analytics_test.exs](test/ad_butler/analytics_test.exs) + any `ad_health_score`-touching test.

### Phase 6 — Pre-existing items

- [x] [P6-T1][oban] **Snooze comment fix** — In [lib/ad_butler/workers/embeddings_refresh_worker.ex:158-165](lib/ad_butler/workers/embeddings_refresh_worker.ex#L158-L165), replace the inaccurate "Oban auto-bumps max_attempts on snooze" claim with:
  ```
  # Snoozing for 90s keeps the next attempt outside the typical 60s
  # rate-limit window so a single retry usually clears. Snoozes DO consume
  # an attempt under standard Oban OSS — `max_attempts: 3` covers one
  # initial run + two retries, including snoozes. If we routinely hit two
  # snoozes per run, raise max_attempts or move to Oban Pro Smart Engine.
  ```
- [x] [P6-T2][oban] **Worker timeout** — Add `def timeout(_job), do: :timer.minutes(5)` to [lib/ad_butler/workers/embeddings_refresh_worker.ex](lib/ad_butler/workers/embeddings_refresh_worker.ex) (place after `perform/1`). Document inline: "5 min cap on a worker that does sequential Repo + HTTP work; lifeline rescue still catches at 30 min as a backstop."

### Phase 7 — Suggestions (cosmetic / consistency)

- [x] [P7-T1][ecto] **Sec SUG-1** — In [lib/mix/tasks/ad_butler.seed_help_docs.ex:48-63](lib/mix/tasks/ad_butler.seed_help_docs.ex#L48-L63), wrap each `Path.wildcard/1` result with `Path.safe_relative/2` against `Application.app_dir(:ad_butler, "priv/embeddings/help")`. Drop entries that fail the safe-relative check with a `Mix.shell().error/1` warning. Defends against future symlinks.
- [x] [P7-T2][ecto] **Sec SUG-2** — In [lib/ad_butler/embeddings.ex:179](lib/ad_butler/embeddings.ex#L179), add a one-line comment near the doc_chunk split: `# safe: doc_chunk is admin-curated only — see lib/mix/tasks/ad_butler.seed_help_docs.ex`.
- [x] [P7-T3][ecto] **Ecto S1** — In [lib/ad_butler/embeddings/embedding.ex](lib/ad_butler/embeddings/embedding.ex), add `@timestamps_opts [type: :utc_datetime_usec]` at the module level (above the `schema "embeddings"` line, after `@foreign_key_type`). Drop the inline `type: :utc_datetime_usec` from the `timestamps/1` call. Matches the convention in every other schema.
- [x] [P7-T4][ecto] **Ecto S2** — In [priv/repo/migrations/20260501000003_add_embeddings_hnsw_index.exs](priv/repo/migrations/20260501000003_add_embeddings_hnsw_index.exs), add an inline comment near the `down`/drop block clarifying that `DROP INDEX CONCURRENTLY` also requires `@disable_ddl_transaction true` (which is already set at the top — just signal to future copy/paste).
- [x] [P7-T5] **Elixir S1** — In [lib/ad_butler/analytics.ex](lib/ad_butler/analytics.ex), replace `Enum.sum(Enum.map(list, & &1.field))` with `Enum.sum_by(list, & &1.field)` at lines 374-375, 693-694, 824-825 (Elixir 1.18+).
- [x] [P7-T6] **Elixir S2** — In [lib/ad_butler/analytics.ex](lib/ad_butler/analytics.ex), replace `length(qualifying)` (in threshold guards) with `Enum.count(qualifying)` at lines 371, 475, 690. Cosmetic — signals intent on bounded lists.
- [x] [P7-T7][test] **Testing S1** — In [test/ad_butler/workers/embeddings_refresh_worker_test.exs:135](test/ad_butler/workers/embeddings_refresh_worker_test.exs#L135), rename describe `"perform/1 — tenant isolation"` → `"perform/1 — cross-tenant embedding (by design)"` so a future reader doesn't conclude a tenant scope filter is missing.
- [x] [P7-T8][test] **Testing S3** — In [test/ad_butler/embeddings_test.exs:103-130](test/ad_butler/embeddings_test.exs#L103-L130), either switch the first `nearest/3` ordering test from `shifted_vector` (offsets 1 vs 50) to `partial_ones` (matches the wider-gap strategy in the existing solution doc), OR add an inline comment acknowledging the HNSW approximation risk.

### Phase 8 — Final verification

- [x] [VF-T1] `mix compile --warnings-as-errors` clean
- [x] [VF-T2] `mix format --check-formatted` clean
- [x] [VF-T3] `mix credo --strict` clean
- [x] [VF-T4] `mix check.unsafe_callers` clean
- [x] [VF-T5] `mix test` — 449+ tests pass (P2-T2 adds 5 scrub_for_user tests → 454+)
- [x] [VF-T6] `mix test --only integration test/ad_butler/integration/week8_e2e_smoke_test.exs` clean

## Risks

- **P5 schema change**: switching `field :ad_id` → `belongs_to :ad` changes the struct shape. Any code that reads `score.ad_id` continues to work (belongs_to still exposes the FK column), but anything that pattern-matches on the struct's exact field set breaks. Pre-implementation grep: `grep -rn "%AdHealthScore{" lib test` to enumerate sites.
- **P1-T1 migration tweak**: requires test-DB reset (`mix ecto.reset` or `mix ecto.drop && mix ecto.create && mix ecto.migrate`) since the table was created in a prior run without the constraint. Document the reset step in the Phase 1 commit message.
- **P3-T1 hash literal coupling**: the raw literal `"#{ad.name} | "` only works while `ad_content/1` returns this exact format. The `describe "ad_content/1"` block at lines 202-225 will catch format drift independently — that's the design intent.
- **P7-T1 (`Path.safe_relative/2`)**: Elixir 1.14+. Verify `mix.exs` `elixir: "~> 1.14"` or higher. Project is on 1.18 per verification report — safe.

## Files Modified Summary

| File | Phase tasks |
|---|---|
| `priv/repo/migrations/20260501000002_create_embeddings.exs` | P1-T1 |
| `lib/ad_butler/embeddings.ex` | P2-T1, P2-T3, P7-T2 |
| `test/ad_butler/embeddings_test.exs` | P2-T2, P7-T8 |
| `test/ad_butler/workers/embeddings_refresh_worker_test.exs` | P3-T1, P7-T7 |
| `test/ad_butler/integration/week8_e2e_smoke_test.exs` | P4-T1 |
| `lib/ad_butler/analytics/ad_health_score.ex` | P5-T1, P5-T2 |
| `test/ad_butler/analytics_test.exs` (and other ad_health_score tests) | P5-T3 |
| `lib/ad_butler/workers/embeddings_refresh_worker.ex` | P6-T1, P6-T2 |
| `lib/mix/tasks/ad_butler.seed_help_docs.ex` | P7-T1 |
| `lib/ad_butler/embeddings/embedding.ex` | P7-T3 |
| `priv/repo/migrations/20260501000003_add_embeddings_hnsw_index.exs` | P7-T4 |
| `lib/ad_butler/analytics.ex` | P7-T5, P7-T6 |
