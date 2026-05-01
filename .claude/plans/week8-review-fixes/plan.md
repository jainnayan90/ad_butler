# Plan: Week 8 review fix-up (post-/phx:review)

**Source**: [.claude/plans/week8-fixes/reviews/week8-fixes-triage.md](.claude/plans/week8-fixes/reviews/week8-fixes-triage.md)
**Scope**: 12 findings (3 BLOCKERs, 9 WARNINGs) from the post-week8-fixes review.
**Verification**: `mix compile --warnings-as-errors` per task; `mix test <affected>` per phase; `mix credo --strict` + full `mix test` at the end.

## Goal

Resolve every triaged finding from the /phx:review pass so the v0.3 + Week 8 work is mergeable. No new functionality. No deferrals.

## What Exists

- Week 8 fix-up plan landed (439 tests green; credo clean) — see `.claude/plans/week8-fixes/`.
- Per-agent reviews captured in `.claude/plans/week8-fixes/reviews/`.
- Triage doc lists the 12 to-fix items with file:line refs and chosen approaches (see "User context captured" in triage).
- Existing call sites of `Embeddings.nearest/3` / `list_ref_id_hashes/1` that B2 will need to update:
  - `lib/ad_butler/workers/embeddings_refresh_worker.ex:47` — `existing_hashes = Embeddings.list_ref_id_hashes(kind)`
  - `test/ad_butler/embeddings_test.exs:127, 153, 169, 202, 224`
  - `test/ad_butler/workers/embeddings_refresh_worker_test.exs:153`

## Phases

### Phase 1 — Embeddings API contract changes (B2 + W7)

Touches the public `Embeddings` API + every existing caller. Land first because subsequent phases depend on the new return shape.

- [x] [P1-T1][ecto] **B2 (part 1)** — Add a fallback clause to [embeddings.ex:60-70](lib/ad_butler/embeddings.ex#L60-L70) `nearest/3` returning `{:error, {:invalid_kind, kind}}`. Wrap the existing happy path's return in `{:ok, list}`. Update `@spec` to `{:ok, [Embedding.t()]} | {:error, {:invalid_kind, String.t()}}`. Mirror to `list_ref_id_hashes/1` ([embeddings.ex:78-85](lib/ad_butler/embeddings.ex#L78-L85)) — `{:ok, %{binary() => String.t()}} | {:error, {:invalid_kind, String.t()}}`.
- [x] [P1-T2][oban] **B2 (part 2)** — Update `EmbeddingsRefreshWorker.refresh_kind/1` ([embeddings_refresh_worker.ex:46-50](lib/ad_butler/workers/embeddings_refresh_worker.ex#L46-L50)) to pattern-match `{:ok, existing_hashes}` from `list_ref_id_hashes/1`. The kind is internal-controlled (`"ad"` / `"finding"`), so the `{:error, _}` branch can `raise "BUG: invalid kind \#{kind}"` since reaching it is a programming error.
- [x] [P1-T3][test] **B2 (part 3)** — Update test call sites:
  - [embeddings_test.exs:127, 169](test/ad_butler/embeddings_test.exs#L127): `assert {:ok, results} = Embeddings.nearest(...)` then assert on `results`.
  - [embeddings_test.exs:153](test/ad_butler/embeddings_test.exs#L153): `assert {:ok, [%Embedding{} = result]} = Embeddings.nearest(...)`.
  - [embeddings_test.exs:202, 224](test/ad_butler/embeddings_test.exs#L202): `assert {:ok, result} = Embeddings.list_ref_id_hashes(...)`.
  - [embeddings_refresh_worker_test.exs:153](test/ad_butler/workers/embeddings_refresh_worker_test.exs#L153): same.
  - Add ONE new test asserting `nearest("campaign", _, _)` returns `{:error, {:invalid_kind, "campaign"}}` — anchors the new fallback.
- [x] [P1-T4][ecto] **W7** — Tighten the [embedding.ex](lib/ad_butler/embeddings/embedding.ex) `@moduledoc` (lines 1-19) to acknowledge advertiser-typed strings (ad/creative names) can carry third-party PII and document the rule that `content_excerpt` MUST be dropped for `kind` ∈ `{"ad", "finding"}` before user-facing render. `kind="doc_chunk"` is exempt (admin-curated).

### Phase 2 — Repo-boundary extraction (B1)

- [x] [P2-T1][ecto] **B1 (part 1)** — Add `Ads.unsafe_list_ads_with_creative_names/0` to [lib/ad_butler/ads.ex](lib/ad_butler/ads.ex) returning `[%{id: binary, name: String.t() | nil, creative_name: String.t() | nil}]`. Same `LEFT JOIN` shape the worker currently uses. `unsafe_` prefix because it skips tenant scope (worker reads ALL ads).
- [x] [P2-T2][ecto] **B1 (part 2)** — Add `Analytics.unsafe_list_all_findings_for_embedding/0` to [lib/ad_butler/analytics.ex](lib/ad_butler/analytics.ex) returning `[%{id: binary, title: String.t(), body: String.t() | nil}]`. Reads ALL findings (worker is intentionally cross-tenant).
- [x] [P2-T3][oban] **B1 (part 3)** — Update [embeddings_refresh_worker.ex:52-65](lib/ad_butler/workers/embeddings_refresh_worker.ex#L52-L65) `build_candidates/2` to call the new context functions. Drop `Repo`, `Ad`, `Creative`, `Finding` aliases — also drop `import Ecto.Query`. Worker should have no Ecto/Repo imports after this.

### Phase 3 — Predictor evidence stringification (B3)

- [x] [P3-T1][oban] **B3 (part 1)** — In `CreativeFatiguePredictorWorker.build_factors_map/1` ([creative_fatigue_predictor_worker.ex:407-418](lib/ad_butler/workers/creative_fatigue_predictor_worker.ex#L407-L418)), stringify the inner `:values` map at construction time:
  ```elixir
  defp build_factors_map(triggered) do
    Map.new(triggered, fn {kind, factors} ->
      stringified = Map.new(factors, fn {k, v} -> {to_string(k), v} end)
      {kind, %{"weight" => Map.get(@weights, kind, 0), "values" => stringified}}
    end)
  end
  ```
- [x] [P3-T2][oban] **B3 (part 2)** — Update `build_evidence/1` pattern from `%{"values" => %{forecast_window_end: end_date}}` to `%{"values" => %{"forecast_window_end" => end_date}}`. [creative_fatigue_predictor_worker.ex:484-493](lib/ad_butler/workers/creative_fatigue_predictor_worker.ex#L484-L493).
- [x] [P3-T3][oban] **B3 (part 3)** — Update `format_predictive_clause/1` to read string keys (`Map.get(values, "projected_ctr_3d")`, etc.). [creative_fatigue_predictor_worker.ex:537-544](lib/ad_butler/workers/creative_fatigue_predictor_worker.ex#L537-L544).
- [x] [P3-T4][oban] **B3 (part 4)** — Delete the comment block at lines 482-486 (the "atom keys before Postgres" caveat) — it no longer applies after stringification.
- [x] [P3-T5][test] **B3 (part 5)** — Update [creative_fatigue_predictor_worker_test.exs](test/ad_butler/workers/creative_fatigue_predictor_worker_test.exs) — find any test that constructs factors maps with atom keys and switch them to strings. Likely the W7D5 / W8D2 tests around finding evidence assertion.

### Phase 4 — Worker correctness fixes (W2 + W3)

- [x] [P4-T1][oban] **W2** — Replace bare `{:ok, count} = Embeddings.bulk_upsert(rows)` at [embeddings_refresh_worker.ex:179-192](lib/ad_butler/workers/embeddings_refresh_worker.ex#L179-L192) with a `case` that handles both `{:ok, _}` and `{:error, _}` cleanly — propagate errors as `{:error, reason}` for Oban retry rather than crashing on `MatchError`.
- [x] [P4-T2][oban] **W3** — Refactor [embeddings_refresh_worker.ex:38-43](lib/ad_butler/workers/embeddings_refresh_worker.ex#L38-L43) `perform/1` to run both kinds independently and reduce results:
  ```elixir
  def perform(_job) do
    ad_result      = refresh_kind("ad")
    finding_result = refresh_kind("finding")

    case {ad_result, finding_result} do
      {:ok, :ok}        -> :ok
      {{:snooze, s}, _} -> {:snooze, s}
      {_, {:snooze, s}} -> {:snooze, s}
      {{:error, r}, _}  -> {:error, r}
      {_, {:error, r}}  -> {:error, r}
    end
  end
  ```

### Phase 5 — Mix task bulk_upsert (W1)

- [x] [P5-T1][ecto] **W1** — Replace the `Enum.each` loop in `upsert_all/2` ([seed_help_docs.ex:72-89](lib/mix/tasks/ad_butler.seed_help_docs.ex#L72-L89)) with a single `Embeddings.bulk_upsert/1` call. Build rows via `Enum.zip_with(docs, vectors, fn d, v -> %{kind: "doc_chunk", ref_id: d.ref_id, embedding: v, content_hash: d.hash, content_excerpt: String.slice(d.content, 0, 200), metadata: %{"filename" => d.filename}} end)`. Compare returned count against `length(docs)`; report mismatch via `Mix.shell().error/1` and exit non-zero.

### Phase 6 — Tenant filter helper (W6)

- [x] [P6-T1][ecto] **W6** — Add `AdButler.Embeddings.tenant_filter_results/2` taking `[Embedding.t()]` + `%User{}` and returning the subset whose `ref_id` belongs to the user. Per-kind logic:
  - `kind == "doc_chunk"` → pass-through (admin-curated, global).
  - `kind == "ad"` → filter via `MapSet.member?(user_ad_ids, embedding.ref_id)` where `user_ad_ids = Ads.list_ad_ids_for_user(user) |> MapSet.new()`. Add `Ads.list_ad_ids_for_user/1` if it doesn't exist (use `list_ad_account_ids_for_user/1` + a `where: ad.ad_account_id in ^aa_ids` query).
  - `kind == "finding"` → filter via `Analytics.list_finding_ids_for_user/1` (add if missing — same pattern as findings paginate scope but `select: f.id` only).
- [x] [P6-T2][test] **W6 (test)** — Add a `describe "tenant_filter_results/2"` block to [embeddings_test.exs](test/ad_butler/embeddings_test.exs) with two-tenant tests for each kind.
- [x] [P6-T3][ecto] **W6 (doc)** — Update `Embeddings` `@moduledoc` (and `nearest/3` `@doc`) to direct callers to `tenant_filter_results/2` before exposing kNN results to user-facing surfaces.

### Phase 7 — Tests (W4 + W5 + W9)

- [x] [P7-T1][test] **W4** — Add a `describe "ad_content/1"` block to [embeddings_refresh_worker_test.exs](test/ad_butler/workers/embeddings_refresh_worker_test.exs) anchoring the contract: `nil`/`""` for either field, both populated, only name, only creative_name. Existing tests calling `ad_content/1` for hash computation can stay.
- [x] [P7-T2][test] **W5** — Update [week8_e2e_smoke_test.exs](test/ad_butler/integration/week8_e2e_smoke_test.exs) to actually exercise the `FatigueNightlyRefitWorker` → `CreativeFatiguePredictorWorker` enqueue chain. Drive `perform_job(FatigueNightlyRefitWorker, %{})` first, `assert_enqueued worker: CreativeFatiguePredictorWorker, args: %{"ad_account_id" => ad_account.id}`, then `Oban.drain_queue(queue: :fatigue_audit)`. Remove the direct `perform_job(CreativeFatiguePredictorWorker, ...)` call — the chain replaces it.
- [x] [P7-T3][test] **W9** — Replace `assert ... == 4.0` at [analytics_insights_test.exs:99, 113](test/ad_butler/analytics_insights_test.exs#L99) with `assert_in_delta result, 4.0, 0.0001`.

### Phase 8 — Style polish (W8)

- [x] [P8-T1][oban] **W8** — Replace `if latest_score == nil do` with `if is_nil(latest_score) do` at [creative_fatigue_predictor_worker.ex:161](lib/ad_butler/workers/creative_fatigue_predictor_worker.ex#L161).

## Final Verification

- [x] [VF-T1] `mix compile --warnings-as-errors` clean
- [x] [VF-T2] `mix format --check-formatted` clean
- [x] [VF-T3] `mix credo --strict` clean
- [x] [VF-T4] `mix check.unsafe_callers` clean
- [x] [VF-T5] `mix test` 100% green (440+ tests after W4 adds ad_content unit tests + B2 invalid-kind test + W6 tenant-filter tests)
- [x] [VF-T6] `mix test --only integration test/ad_butler/integration/week8_e2e_smoke_test.exs` clean (W5's chain change should not break)

## Risks

- **B2's tagged-tuple return** is a contract change for every existing caller. P1-T3 enumerates all known sites; double-check via `grep -rn "Embeddings.nearest\|Embeddings.list_ref_id_hashes" lib test` after Phase 1 so nothing slips through.
- **B3's stringification** must not alter the `evidence` JSONB shape that already-persisted findings hold. Existing rows have `evidence.predicted_fatigue.values` with string keys (post-Postgres round-trip), so reads from the DB still work. Only the in-memory write path changes — verify with the existing W8D2 / W7D5 finding-rendering tests.
- **B3 P3-T5**: hunt for any test fixture that hand-builds a `factors` or `evidence` map with atom keys and update them — likely 1-3 sites in the predictor worker test.
- **W6 tenant filter**: the helper lives in `Embeddings` for now since `Chat` context doesn't exist yet. When W9 creates the Chat context, migrate this helper there. Add a TODO inline.
- **W3 (perform/1 reduce)**: snooze precedence — if both kinds returned `{:snooze, _}`, we surface ad's snooze first. That's fine semantically (Oban schedules the next attempt); double-check there's no test asserting ordering.

## Files Modified Summary

| File | Phase tasks |
|---|---|
| `lib/ad_butler/embeddings.ex` | P1-T1, P6-T1, P6-T3 |
| `lib/ad_butler/embeddings/embedding.ex` | P1-T4 |
| `lib/ad_butler/workers/embeddings_refresh_worker.ex` | P1-T2, P2-T3, P4-T1, P4-T2 |
| `lib/ad_butler/workers/creative_fatigue_predictor_worker.ex` | P3-T1..T4, P8-T1 |
| `lib/ad_butler/ads.ex` | P2-T1, P6-T1 (list_ad_ids_for_user) |
| `lib/ad_butler/analytics.ex` | P2-T2, P6-T1 (list_finding_ids_for_user) |
| `lib/mix/tasks/ad_butler.seed_help_docs.ex` | P5-T1 |
| `test/ad_butler/embeddings_test.exs` | P1-T3, P6-T2 |
| `test/ad_butler/workers/embeddings_refresh_worker_test.exs` | P1-T3, P7-T1 |
| `test/ad_butler/workers/creative_fatigue_predictor_worker_test.exs` | P3-T5 |
| `test/ad_butler/integration/week8_e2e_smoke_test.exs` | P7-T2 |
| `test/ad_butler/analytics_insights_test.exs` | P7-T3 |
