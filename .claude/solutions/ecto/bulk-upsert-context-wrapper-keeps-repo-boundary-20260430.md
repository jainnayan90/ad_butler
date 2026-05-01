---
title: "Wrap Repo.insert_all in a context helper to fix worker N+1 without violating the Repo boundary"
module: "AdButler.Embeddings"
date: "2026-04-30"
problem_type: refactor
component: ecto_query
symptoms:
  - "Worker calls `Enum.each(rows, &Context.upsert/1)` and emits one `Repo.insert/2` per row (up to 100 round-trips per cron tick)"
  - "Iron Law violation: collapsing the N+1 to a single `Repo.insert_all/3` would put a `Repo` call inside the worker"
  - "Per-row error handling logs and discards `{:error, changeset}` — silent partial failures"
---

## Root cause

The straightforward N+1 fix — call `Repo.insert_all/3` from the worker — moves the Repo boundary outside the context, breaking the AdButler convention that only context modules talk to `Repo`. Workers logging per-row failures hide partial writes from Oban (the job returns `:ok` even when 80 of 100 rows failed).

## Fix

Add a single-purpose context helper alongside the existing single-row `upsert/1`:

```elixir
# lib/ad_butler/embeddings.ex
@spec bulk_upsert([map()]) :: {:ok, non_neg_integer()}
def bulk_upsert([]), do: {:ok, 0}

def bulk_upsert(rows) when is_list(rows) do
  now = DateTime.utc_now()
  rows_with_timestamps = Enum.map(rows, &Map.merge(%{inserted_at: now, updated_at: now}, &1))

  {count, _} =
    Repo.insert_all(
      Embedding,
      rows_with_timestamps,
      on_conflict: {:replace, [:embedding, :content_hash, :content_excerpt, :metadata, :updated_at]},
      conflict_target: [:kind, :ref_id]
    )

  {:ok, count}
end
```

Worker compares returned count against `length(rows)` and returns `{:error, :partial_upsert_failure}` on mismatch so Oban retries:

```elixir
defp upsert_batch(kind, candidates, vectors) do
  rows = Enum.zip_with(candidates, vectors, fn c, v -> %{kind: kind, ref_id: c.ref_id, ...} end)

  {:ok, count} = Embeddings.bulk_upsert(rows)
  expected = length(rows)

  if count == expected do
    :ok
  else
    Logger.error("embeddings_refresh: partial upsert", kind: kind, count: expected, failure_count: expected - count)
    {:error, :partial_upsert_failure}
  end
end
```

## Why it works

- **Repo boundary intact**: every `Repo.insert_all/3` lives inside `AdButler.Embeddings`. Workers, controllers, LiveViews stay Repo-free.
- **Validation tradeoff**: `Repo.insert_all/3` doesn't run changesets — moduledoc on `bulk_upsert/1` documents that the DB CHECK enforces `kind` and the only `content_hash` producer is the deterministic `hash_content/1`. Use single-row `upsert/1` when you need the changeset path.
- **Schema vs raw table**: passing the schema module (`Embedding`) — not the table name (`"embeddings"`) — makes Ecto run the type's `dump` callback (e.g. `Pgvector.Ecto.Vector`).
- **Timestamps**: `Repo.insert_all/3` does NOT auto-populate `inserted_at`/`updated_at` even with a schema. The helper merges them in.

## Generalization

For every existing pattern of `Enum.each(rows, &Context.upsert/1)` in a worker, the conversion is:

1. Add `bulk_upsert/1` (or `bulk_*` named for the operation) to the context.
2. Worker zips inputs into row maps once, then calls the bulk helper.
3. Worker compares returned count against expected and propagates `{:error, :partial_*_failure}` for any deficit so Oban retries.

The Repo-only-from-context Iron Law is preserved without sacrificing the bulk-write performance win.

## Reference

- v0.3 / week 8 fix B1 in `.claude/plans/week8-fixes/plan.md` (P2-T1).
- See `lib/ad_butler/workers/embeddings_refresh_worker.ex:upsert_batch/3` and `lib/ad_butler/embeddings.ex:bulk_upsert/1`.
