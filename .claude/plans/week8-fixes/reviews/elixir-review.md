# Elixir Review — v0.3 + week8 fixes

⚠️ EXTRACTED FROM AGENT MESSAGE — agent could not write directly (hook-restricted). Findings preserved verbatim.

**Status**: Changes Requested — 1 blocker, 4 warnings, 3 suggestions.

---

## BLOCKER

**1. `lib/ad_butler/embeddings.ex:105` — `nearest/3` has no fallback clause; crashes with `FunctionClauseError` on invalid `kind`.**

The only clause is guarded by `kind in @valid_kinds`. Passing an unknown kind gets an unhandled `FunctionClauseError`. `list_ref_id_hashes/1` at line 124 has the same gap. Both are public API functions. The `@spec` also claims a bare `[Embedding.t()]` return with no error path — Dialyzer `invalid_contract` once a caller pattern-matches on `{:ok, _}`.

Fix: add a fallback clause returning `{:error, {:invalid_kind, kind}}` and update the spec to `{:ok, [Embedding.t()]} | {:error, {:invalid_kind, String.t()}}`. Same for `list_ref_id_hashes/1`.

---

## WARNINGS

**2. `lib/ad_butler/workers/embeddings_refresh_worker.ex:53,63` — `Repo` called directly inside a worker; violates Repo-boundary Iron Law.**

`build_candidates/2` calls `Repo.all(from a in Ad ...)` and `Repo.all(from f in Finding ...)`. Per CLAUDE.md, `Repo` must only be called from context modules. Add `Ads.list_ads_with_creative_names/0` and `Analytics.list_findings_for_embedding/0` context functions and delegate from the worker.

**3. `lib/ad_butler/workers/creative_fatigue_predictor_worker.ex:161` — `if latest_score == nil` should be `is_nil/1`.**

Consistent with how every other nil-check in this codebase uses `is_nil/1` or pattern-matches `nil` in a function head.

**4. `lib/mix/tasks/ad_butler.seed_help_docs.ex:73` — `upsert_all/2` calls `Embeddings.upsert/1` in a loop instead of `Embeddings.bulk_upsert/1`.**

The context already exposes `bulk_upsert/1` (single `Repo.insert_all`). The `Enum.each` loop does N round-trips. Use `Enum.zip_with` to build the rows list and call `bulk_upsert/1` once. For a seed task the trade-off (losing per-file success logging) is acceptable.

**5. `lib/ad_butler/analytics.ex:349,453,668` — `if length(list) < N` on O(n) traversal.**

All three sites call `length/1` to compare against a small constant. Lists are bounded (3–10 rows). Either keep as-is (Credo doesn't flag this size) or switch to `Enum.count/1`. Marked WARNING for consistency; functional impact is minimal.

---

## SUGGESTIONS

**6. `lib/ad_butler/embeddings/service.ex:28` — `:embeddings_model` config key is never set; falls through to hardcoded default on every call.**

`config/config.exs` already sets `config :ad_butler, :llm_models, embedding: "openai:text-embedding-3-small"`. `Service` reads a separate `:embeddings_model` key absent from all config files. Either wire to the existing `:llm_models` key for consistency, or add an explicit `config :ad_butler, :embeddings_model, ...` entry so the intent is clear.

**7. `lib/ad_butler/workers/embeddings_refresh_worker.ex:68` — `Enum.flat_map` with `[item]`/`[]`; prefer a comprehension.**

```elixir
for row <- rows,
    content = content_fn.(row),
    hash = Embeddings.hash_content(content),
    Map.get(existing_hashes, row.id) != hash,
    do: %{ref_id: row.id, content: content, hash: hash}
```

Avoids intermediate single-element list allocations and reads intent clearly.

**8. `lib/ad_butler/postgrex_types.ex` — no `@moduledoc`; needs a comment explaining why.**

`Postgrex.Types.define/3` generates the module body so `@moduledoc` cannot be added the normal way. Add a brief comment explaining this so the CLAUDE.md `@moduledoc`-required rule is acknowledged rather than silently violated.
