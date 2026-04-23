---
module: "AdButler.Workers.SyncAllConnectionsWorker"
date: "2026-04-22"
problem_type: oban_behavior
component: oban_worker
symptoms:
  - "CaseClauseError: no case clause matching []  when Oban.insert_all is called with empty list"
  - "CaseClauseError: no case clause matching [%Oban.Job{...}] when jobs are inserted"
  - "Dialyzer pattern_match warning on {:error, reason} arm after Oban.insert_all"
root_cause: "Oban.insert_all/1 in Oban 2.21+ always returns a list of Oban.Job structs, never {:ok, _} or {:error, reason}. On failure it raises rather than returning an error tuple."
severity: medium
tags: [oban, insert_all, return-type, dialyzer, pattern-match, case-clause-error]
---

# Oban: insert_all/1 Returns a List, Not a Tagged Tuple

## Symptoms

Plan suggested wrapping `Oban.insert_all(jobs)` with:

```elixir
case Oban.insert_all(jobs) do
  {:ok, _} -> :ok
  {:error, reason} -> {:error, reason}
end
```

This causes `CaseClauseError` immediately:
- With empty list: `no case clause matching: []`
- With jobs: `no case clause matching: [%Oban.Job{...}]`

Adding `[] -> :ok` fixes the empty case but not non-empty. Adding
`inserted when is_list(inserted) -> :ok` works at runtime but Dialyzer
flags `{:error, reason}` as a `pattern_match` warning (unreachable dead code).

## Investigation

1. Checked `deps/oban/lib/oban.ex` — `insert_all/1` calls `Repo.insert_all` and
   returns the result list directly. No tagged tuple wrapping.
2. On DB failure: raises an exception rather than returning `{:error, reason}`.
   Oban catches the raise at the queue executor level and marks the job retryable.
3. Invalid changesets: silently included in the returned list as `nil` entries
   (changeset errors do not raise, they produce nil in the list).

## Root Cause

The Oban docs and common mental model from `Ecto.Repo.insert/1` suggest tagged
tuples. `Oban.insert_all/1` follows `Ecto.Repo.insert_all/3` semantics instead —
returns `{count, [records]}` or just a list of job structs depending on version.
In Oban 2.21.1, it returns `[%Oban.Job{} | nil]` directly.

## Solution

Don't wrap `Oban.insert_all` in a case — just call it and return `:ok`:

```elixir
# Correct
def perform(_job) do
  jobs =
    Accounts.list_all_active_meta_connections()
    |> Enum.map(&FetchAdAccountsWorker.new(%{"meta_connection_id" => &1.id}))

  Oban.insert_all(jobs)
  :ok
end
```

If you need to detect partial failures (nil entries for invalid changesets):

```elixir
inserted = Oban.insert_all(jobs)
failed = Enum.count(inserted, &is_nil/1)
if failed > 0, do: Logger.warning("Some jobs failed to insert", count: failed)
:ok
```

### Files Changed

- `lib/ad_butler/workers/sync_all_connections_worker.ex` — Removed case, bare insert + :ok

## Prevention

- [ ] `Oban.insert_all/1` always returns a list — never pattern-match on `{:ok, _}` or `{:error, _}`
- [ ] DB failures from `insert_all` raise exceptions, not return error tuples; Oban's executor catches them
- [ ] Empty list `[]` is a valid return — `Oban.insert_all([])` short-circuits and returns `[]`
- [ ] Use `is_nil` filter on the returned list to detect invalid changeset entries if needed

## Related

- `oban-schedule-failure-should-not-retry-already-completed-work-20260421.md` — related Oban return-value patterns
