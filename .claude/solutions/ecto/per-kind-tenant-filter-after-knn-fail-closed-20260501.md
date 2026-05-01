---
title: "Per-kind tenant filter after cross-tenant kNN — fail-closed on unknown kinds"
module: "AdButler.Embeddings"
date: "2026-05-01"
problem_type: security
component: ecto_query
symptoms:
  - "Embedding rows are stored cross-tenant by design — `kind in {ad, finding, doc_chunk}` with `ref_id` pointing at the source row"
  - "First user-facing caller of `nearest/3` would expose other tenants' ad/finding `ref_id`s without explicit filtering"
  - "Naive split into `{ad_rows, rest}` + `{finding_rows, doc_rows}` lumps every UNKNOWN kind into `doc_rows` (the global pass-through bucket)"
---

## Root cause

`AdButler.Embeddings.nearest/3` returns rows across all kinds in one query (HNSW
on a single multi-kind table). Tenant scoping cannot live at the query layer —
the embedding's `ref_id` is opaque to the embeddings table. So callers must
filter by ownership *after* the kNN.

The first cut split rows into `{ad, rest}` then `{finding, doc_chunk}`. The
second split put EVERY non-finding kind into the doc_chunk bucket — including
hypothetical future kinds. doc_chunk is the only kind treated as global
(admin-curated). A future migration that adds e.g. `chat_message` to
`Embedding.@kinds` (and the DB CHECK) would silently leak across tenants until
someone remembered to update the filter.

## Fix

Three-way split with an explicit `unknown_rows` bucket. Raise on unknown kinds
— fail-closed beats fail-open every time for tenant boundaries.

```elixir
# lib/ad_butler/embeddings.ex
def tenant_filter_results(rows, %User{} = user) when is_list(rows) do
  {ad_rows, rest} = Enum.split_with(rows, &(&1.kind == "ad"))
  {finding_rows, rest} = Enum.split_with(rest, &(&1.kind == "finding"))
  {doc_rows, unknown_rows} = Enum.split_with(rest, &(&1.kind == "doc_chunk"))

  if unknown_rows != [] do
    raise "Embeddings.tenant_filter_results/2: refusing to filter unknown kinds " <>
            inspect(Enum.map(unknown_rows, & &1.kind) |> Enum.uniq()) <>
            " — fail-closed to avoid cross-tenant leak. Add explicit handling."
  end

  kept_ads = filter_by_ownership(ad_rows, fn -> Ads.list_ad_ids_for_user(user) end)
  kept_findings =
    filter_by_ownership(finding_rows, fn -> Analytics.list_finding_ids_for_user(user) end)

  kept_ads ++ kept_findings ++ doc_rows
end

defp filter_by_ownership([], _id_fun), do: []
defp filter_by_ownership(rows, id_fun) do
  owned = id_fun.() |> MapSet.new()
  Enum.filter(rows, &MapSet.member?(owned, &1.ref_id))
end
```

The `id_fun` is a thunk so we don't pay for the ownership query when the input
list contains no rows of that kind.

## Companion changes

- Pin the kind allowlist on the schema's source-of-truth:
  `@valid_kinds Embedding.kinds()` (don't repeat `~w(ad finding doc_chunk)`).
- Update `nearest/3` and `list_ref_id_hashes/1` to return tagged tuples with
  an `{:error, {:invalid_kind, kind}}` fallback clause for binaries outside
  the allowlist, so callers can't silently match on `FunctionClauseError`.
- Document the PII rule on the `Embedding` schema: `content_excerpt` for
  `kind ∈ {ad, finding}` is advertiser-typed and may carry third-party PII —
  must be dropped before user-facing render.

## Tests

Two-tenant cross-isolation test per kind:

```elixir
# test/ad_butler/embeddings_test.exs
test "drops ad rows whose ref_id belongs to another tenant" do
  mc_a = insert(:meta_connection)
  mc_b = insert(:meta_connection)
  ad_a = insert(:ad, ad_account: insert(:ad_account, meta_connection: mc_a), ...)
  ad_b = insert(:ad, ad_account: insert(:ad_account, meta_connection: mc_b), ...)

  {:ok, e_a} = Embeddings.upsert(%{kind: "ad", ref_id: ad_a.id, ...})
  {:ok, e_b} = Embeddings.upsert(%{kind: "ad", ref_id: ad_b.id, ...})

  assert Embeddings.tenant_filter_results([e_a, e_b], mc_a.user) |> Enum.map(& &1.id) == [e_a.id]
  assert Embeddings.tenant_filter_results([e_a, e_b], mc_b.user) |> Enum.map(& &1.id) == [e_b.id]
end
```

doc_chunk gets a pass-through assertion (admin-curated, no per-user binding).

## When this applies

Any kNN/ANN result set returned from a cross-tenant store. If you see a
LEFT-JOIN-scoped index and a guard like `where: e.kind == ^kind`, you do NOT
have tenant scoping — the `ref_id` filter is purely structural. Apply this
pattern at every user-facing surface.

## See also

- `.claude/solutions/ecto/bulk-upsert-context-wrapper-keeps-repo-boundary-20260430.md`
  for the companion bulk-upsert helper
- CLAUDE.md `Contexts and the Repo Boundary` rule
