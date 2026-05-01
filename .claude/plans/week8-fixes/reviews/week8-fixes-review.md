# Review Summary — week8-fixes (v0.3 + Week 8 fixes)

**Verdict: REQUIRES CHANGES**
**Date:** 2026-04-30
**Agents:** elixir-reviewer · testing-reviewer · oban-specialist · iron-law-judge · security-analyzer

**Counts:** 3 BLOCKER · 9 WARNING · 8 SUGGESTION

The plan delivered Week 8 review fixes against the v0.3 base. /phx:full landed all 34 plan tasks green (439 tests, credo --strict clean, migration roundtrip OK). This review found new issues introduced by the v0.3 surface itself — the Week 8 plan didn't have these in scope. Two BLOCKERs are real bugs (Repo-boundary Iron Law violation, atom-key JSONB fragility). The third BLOCKER is a behavior change (functions that previously returned `[]` now crash) — debatable but worth deciding explicitly.

---

## BLOCKERS

**B1. Repo boundary violation — `Repo.all` inside `EmbeddingsRefreshWorker`**
`lib/ad_butler/workers/embeddings_refresh_worker.ex:53-64`

`build_candidates/2` calls `Repo.all(from a in Ad ...)` and `Repo.all(from f in Finding ...)` directly — workers must not call `Repo`. (Confirmed by both iron-law-judge and elixir-reviewer.)

→ Extract `Ads.unsafe_list_ads_with_creative_names/0` and `Analytics.unsafe_list_all_findings_for_embedding/0`. Worker delegates to those. Remove `Repo`/`Ad`/`Creative`/`Finding` aliases from the worker.

**B2. `nearest/3` + `list_ref_id_hashes/1` lack fallback clauses → `FunctionClauseError` on invalid kind**
`lib/ad_butler/embeddings.ex:60-70, 78-85`

The `kind in @valid_kinds` guard with no fallback crashes on unknown kind. The `@spec` only declares `[Embedding.t()]` (no error path). Previously these returned `[]` for non-matching kinds via the SQL `where: e.kind == ^kind`. New behavior is a hard crash.

→ Either (a) add a fallback clause returning `{:error, {:invalid_kind, kind}}` and update the spec to a tagged tuple, OR (b) explicitly document "fail-fast on invalid kind" as the intended contract and update the spec to `no_return()` for that case. Decide intentionally.

**B3. `build_evidence/1` atom-key fragility — silently drops `predicted`/`forecast_window_end` post-Postgres**
`lib/ad_butler/workers/creative_fatigue_predictor_worker.ex:407-418, 484-493`

`build_factors_map/1` writes inner `:values` map with atom keys. `build_evidence/1` and `format_predictive_clause/1` pattern-match those atom keys — works in-process, but a future caller reconstructing `factors` from persisted JSONB (string keys) hits the `_` branch silently and strips top-level evidence fields.

→ Stringify the inner values map immediately in `build_factors_map/1`, then update `build_evidence/1` and `format_predictive_clause/1` to read string keys.

---

## WARNINGS

**W1. Seed task uses single-row `Embeddings.upsert/1` loop instead of `bulk_upsert/1`**
`lib/mix/tasks/ad_butler.seed_help_docs.ex:72-89` (iron-law-judge + elixir-reviewer)

The N+1 fix that landed for the worker was not propagated to the seed task. Replace the `Enum.each` loop with one `bulk_upsert/1` call.

**W2. Bare `{:ok, count} = Embeddings.bulk_upsert(rows)` match — opaque crash if contract widens**
`lib/ad_butler/workers/embeddings_refresh_worker.ex:179` (oban-specialist)

Replace with a `case` that handles both `{:ok, _}` and `{:error, _}` cleanly so Oban gets a proper error tuple instead of a `MatchError`.

**W3. Rate-limit snooze on "ad" silently skips "finding" for that tick**
`lib/ad_butler/workers/embeddings_refresh_worker.ex:41-43` (oban-specialist)

`with :ok <- refresh_kind("ad") do refresh_kind("finding") end` short-circuits when ads return `{:snooze, 90}`. Findings get delayed by every snooze cycle. Reduce both results independently and snooze if EITHER kind needs to.

**W4. Tests couple to internal `EmbeddingsRefreshWorker.ad_content/1` helper for hash computation**
`test/ad_butler/workers/embeddings_refresh_worker_test.exs:74,96,127` (testing-reviewer)

Either add a dedicated unit test for `ad_content/1` (anchor its contract) or compute the hash from raw ad attributes instead.

**W5. `week8_e2e_smoke_test` `@moduledoc` claims `FatigueNightlyRefitWorker → CreativeFatiguePredictorWorker` enqueue chain, but test calls predictor directly**
`test/ad_butler/integration/week8_e2e_smoke_test.exs:3-14, 73` (testing-reviewer)

→ Either update the moduledoc to match what's actually tested, OR add `perform_job(FatigueNightlyRefitWorker, %{})` + `assert_enqueued worker: CreativeFatiguePredictorWorker` and drain from there.

**W6. `nearest/3` cross-tenant — release gate for W9** (PERSISTENT for upcoming W9 PR)
`lib/ad_butler/embeddings.ex:104-116` (security-analyzer)

The first W9 chat tool that calls `Embeddings.nearest/3` MUST resolve `ref_id`s through tenant-scoped contexts and drop `:not_found` rows before rendering. Suggest a `Chat.tenant_filter_embedding_results/2` helper to centralize this. (Already documented in moduledoc; adding tooling makes "forget to filter" impossible.)

**W7. `content_excerpt` latent advertiser-PII** (forward-looking)
`lib/ad_butler/embeddings/embedding.ex:17-19` + worker (security-analyzer)

`<ad.name> | <creative.name>` (first 200 chars) can contain customer names / internal codenames typed by advertisers. Schema docstring forbids "user-typed PII" but doesn't acknowledge advertiser-typed strings. Today no user-facing path reads excerpts cross-tenant — latent until W9.

→ When W9 renders kNN results, drop `content_excerpt` for non-`doc_chunk` rows. Tighten the schema docstring.

**W8. `if latest_score == nil` should be `is_nil/1`**
`lib/ad_butler/workers/creative_fatigue_predictor_worker.ex:161` (elixir-reviewer)

Codebase convention is `is_nil/1` or pattern matching `nil` in heads.

**W9. Float `==` on `get_7d_frequency/1` return** (PERSISTENT — re-raised from /phx:full review)
`test/ad_butler/analytics_insights_test.exs:99,113` (testing-reviewer)

`assert ... == 4.0` against a float from `AVG()` over `Decimal`. Today's deterministic int-average lands exactly on 4.0, but `assert_in_delta result, 4.0, 0.0001` is safer and documents intent.

---

## SUGGESTIONS

- `lib/ad_butler/embeddings/service.ex:28` — `:embeddings_model` config key is never set; falls through to hardcoded default. Wire to existing `:llm_models` key or add explicit config.
- `lib/ad_butler/workers/embeddings_refresh_worker.ex:68` — `Enum.flat_map` with `[item]/[]` → use a `for` comprehension.
- `lib/ad_butler/postgrex_types.ex` — no `@moduledoc` because `Postgrex.Types.define/3` generates the body. Add a comment acknowledging this.
- `lib/ad_butler/workers/embeddings_refresh_worker.ex:21-24` — no `timeout/1` callback. Add `def timeout(_job), do: :timer.minutes(5)`.
- `test/ad_butler/workers/embeddings_refresh_worker_test.exs:135` — rename `"perform/1 — tenant isolation"` → `"perform/1 — cross-tenant embedding (by design)"` to clarify intent.
- `test/ad_butler/analytics_insights_test.exs:18` — describe heading `"compute_ctr_slope/2 / get_7d_frequency/1"` should be just `"compute_ctr_slope/2"` (the second function has its own describe block).
- `lib/mix/tasks/ad_butler.seed_help_docs.ex:47-63` — wrap `Path.wildcard` with `Path.safe_relative/2` for symlink defense in depth.
- `lib/ad_butler/workers/creative_fatigue_predictor_worker.ex:489-494` — add inline comment `# safe: Finding schema has no token/PII fields` so future schema additions force a re-audit.
- `lib/ad_butler/analytics.ex` — `if length(list) < N` on small lists is technically O(n). Lists are bounded (3-14 items), demoted to SUGGESTION.

---

## Manual checks the user should run

- `mix sobelow --exit medium`
- `mix deps.audit`
- `mix hex.audit`

---

## Per-agent reports

- [elixir-review.md](elixir-review.md)
- [testing-review.md](testing-review.md)
- [oban-review.md](oban-review.md)
- [iron-law-review.md](iron-law-review.md)
- [security-review.md](security-review.md)
