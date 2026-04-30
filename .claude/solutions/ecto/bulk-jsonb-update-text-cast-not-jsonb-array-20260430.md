---
module: "AdButler.Ads"
date: "2026-04-30"
problem_type: database_issue
component: ecto_query
symptoms:
  - "Bulk UPDATE of a `:map` column via `unnest($1::uuid[], $2::jsonb[])` stores values as JSONB scalar strings instead of JSONB objects"
  - "Reading the column raises `ArgumentError: cannot load \"{...escaped...}\" as type :map for field :col`"
  - "Postgrex.EncodeError: Postgrex expected a binary of 16 bytes, got \"<uuid-string>\" — when passing string UUIDs to `uuid[]` parameter"
  - "`Repo.insert_all/3` with `on_conflict: {:replace, [:col]}` fails NOT NULL on other required columns"
root_cause: "Two unrelated Postgrex array-encoding gotchas surface together when bulk-updating a JSONB column with one round-trip. (1) Pre-`Jason.encode!`'d strings passed as `jsonb[]` get encoded a second time and stored as JSONB scalar strings — the cast in the SQL must be `text[]::jsonb[]`, not `jsonb[]` directly. (2) `uuid[]` parameters require 16-byte binaries (via `Ecto.UUID.dump!/1`), not UUID-formatted strings. (3) `insert_all` with `on_conflict` is the wrong tool entirely because Postgres validates NOT NULL on the proposed insert row before resolving the conflict, so missing required columns fail."
severity: high
tags: [ecto, postgrex, jsonb, bulk-update, unnest, n+1, on-conflict]
---

# Bulk JSONB UPDATE: Cast `text[]::jsonb[]`, Not `jsonb[]`

## Symptoms

Replacing an N+1 `Repo.update_all`-per-row loop with a single bulk UPDATE
that uses `unnest()` on parallel arrays. Three failure modes appear in
sequence:

1. **NOT NULL violation** when reaching for `Repo.insert_all/3` with
   `on_conflict: {:replace, [:my_column]}, conflict_target: [:id]` — the
   proposed insert row needs values for every NOT NULL column, even when
   the conflict path will replace just one of them.
2. **Postgrex encode error** when passing the SQL string UUID to a `uuid[]`
   array parameter:
   ```
   ** (DBConnection.EncodeError) Postgrex expected a binary of 16 bytes,
       got "3306e1e1-697d-49c8-a99b-a64552c0b86e"
   ```
3. **JSONB scalar string** stored instead of a JSONB object when passing
   `Jason.encode!`'d strings as `jsonb[]`:
   ```
   ** (ArgumentError) cannot load `"{\"snapshots\":[...]}"` as type :map
       for field :quality_ranking_history
   ```

## Investigation

1. **Postgres ON CONFLICT requires a valid row.** The Ecto `insert_all`
   path looks attractive but Postgres evaluates NOT NULL on the proposed
   row at INSERT time, before deciding the conflict. So `insert_all`
   needs every required column populated — even though the conflict
   resolution will replace only one of them. Workable but wasteful.
2. **`uuid[]` parameter encoding.** Postgrex's UUID extension encodes
   16-byte binaries to PostgreSQL `uuid` when the array parameter type is
   `::uuid[]`. Passing the string form raises an encode error. Solution:
   `Ecto.UUID.dump!(id)` per element.
3. **`jsonb[]` parameter double-encoding.** Postgrex's JSONB extension
   auto-encodes Elixir maps to JSONB. If you pass a *string* (e.g.
   `Jason.encode!(map)`) into a `jsonb[]` parameter, Postgrex encodes the
   string itself as a JSONB scalar — so the column stores
   `"{\"snapshots\":...}"` (a quoted JSON string), not a JSONB object.
   Two fixes work:
   - Pass raw maps and let Postgrex encode them (no `Jason.encode!`), OR
   - Pass `text[]` and cast to `jsonb[]` inside the SQL: `$2::text[]::jsonb[]`
   The text-cast variant is preferred because (a) the JSON encoding is
   explicit at the call site, (b) the parsing is forced by Postgres, not
   the encoder.

## Root Cause

`unnest($1::uuid[], $2::jsonb[])` looks like the right shape but Postgrex
binds it via its native UUID and JSONB extensions:

- The UUID encoder expects a 16-byte binary, not a UUID-formatted string.
- The JSONB encoder will wrap any `is_binary/1` value as a JSONB scalar
  string. Pre-encoding via `Jason.encode!` makes that wrapping visible.

Cast through `text[]` for the JSONB column, and `Ecto.UUID.dump!/1` per
UUID, to produce parameters that match Postgrex's encoders precisely.

## Solution

```elixir
defp bulk_write_quality_ranking_history(pairs, existing) do
  {id_bins, history_texts} =
    Enum.reduce(pairs, {[], []}, fn {ad_id, snapshot}, {ids, texts} ->
      history = Map.get(existing, ad_id) || %{"snapshots" => []}

      new_snapshots =
        history
        |> Map.get("snapshots", [])
        |> Kernel.++([snapshot])
        |> Enum.take(-@history_cap)

      {[Ecto.UUID.dump!(ad_id) | ids],
       [Jason.encode!(%{"snapshots" => new_snapshots}) | texts]}
    end)

  # Pre-encoded JSON as `text[]`, cast to `jsonb[]` inside the statement.
  # Going via `text` avoids Postgrex's jsonb encoder re-encoding the
  # already-encoded string as a JSONB scalar.
  sql = """
  UPDATE ads SET
    quality_ranking_history = data.history,
    updated_at = NOW()
  FROM unnest($1::uuid[], $2::text[]::jsonb[]) AS data(id, history)
  WHERE ads.id = data.id
  """

  SQL.query!(Repo, sql, [id_bins, history_texts])
end
```

### Files Changed

- `lib/ad_butler/ads.ex` — `bulk_write_quality_ranking_history/2`
  replaces a per-row `Repo.update_all` loop in `append_quality_ranking_snapshots/2`
- `test/ad_butler/ads_test.exs` — 3 tests (30-row bulk, 14-cap with prior
  history, all-nil-rankings skip)

## Prevention

- [ ] When passing pre-`Jason.encode!`'d strings to a Postgres JSONB
      parameter, cast `text[]::jsonb[]` (or `text::jsonb` for scalars). Do
      NOT use `jsonb[]` directly — Postgrex's JSONB extension will
      double-encode.
- [ ] When passing UUID strings to a `uuid[]` parameter, dump first:
      `Enum.map(ids, &Ecto.UUID.dump!/1)`.
- [ ] `Repo.insert_all/3` with `on_conflict` is NOT a substitute for a
      bulk UPDATE when the rows already exist — Postgres still checks NOT
      NULL on the proposed insert row before resolving the conflict.
      Use `Ecto.Adapters.SQL.query!/3` with `UPDATE ... FROM unnest(...)`
      instead. Repo-boundary stays clean as long as the call lives inside
      a context module.
- [ ] Use `iex -S mix` to pre-test the SQL with a small fixture before
      shipping. The encode errors are cryptic and easy to spend an hour
      on.

## Related

- `solutions/ecto/partial-unique-index-breaks-on-conflict-20260425.md`
- `solutions/ecto/bulk-validate-must-run-after-fk-injection-20260422.md`
- PostgreSQL docs: [unnest](https://www.postgresql.org/docs/current/functions-array.html), [INSERT ON CONFLICT](https://www.postgresql.org/docs/current/sql-insert.html#SQL-ON-CONFLICT)
- Postgrex docs: [type extensions for jsonb / uuid](https://hexdocs.pm/postgrex/Postgrex.html#extensions)
