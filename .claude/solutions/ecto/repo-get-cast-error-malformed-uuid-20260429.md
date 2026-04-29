---
module: "AdButler.Analytics"
date: "2026-04-29"
problem_type: ecto_error
component: context
symptoms:
  - "Ecto.Query.CastError raised when get_finding/2 called with a non-UUID string"
  - "URL segment or user input passed directly to Repo.get/2 causes unhandled exception"
  - "Function returning {:ok, _} | {:error, :not_found} raises instead of returning tuple"
root_cause: "Ecto.Repo.get/2 raises Ecto.Query.CastError for values that cannot be cast to the primary key type (e.g. :binary_id). The raise bypasses any {:error, :not_found} return path."
severity: medium
tags: [ecto, repo, get, cast-error, uuid, binary-id, rescue, not-found]
---

# Ecto: `Repo.get/2` Raises `CastError` for Malformed UUIDs

## Symptoms

Context function `get_finding(user, id)` pattern-matches `nil -> {:error, :not_found}`
but callers passing `"not-a-uuid"` (raw URL segments, user input) get an unhandled
`Ecto.Query.CastError` raise instead of the expected `{:error, :not_found}` tuple.

## Investigation

`Ecto.Repo.get/2` calls `Ecto.Query.Planner.cast_params/3` before sending SQL. For
`:binary_id` primary keys, invalid strings raise `Ecto.Query.CastError` at the Elixir
layer — no database query is ever made.

The cast error is raised by external code (Ecto/Postgrex), so `rescue` is appropriate
per the "rescue for third-party code that raises" principle.

Test: `Analytics.get_finding(user, "not-a-uuid")` → `Ecto.Query.CastError` before fix,
`{:error, :not_found}` after.

## Root Cause

`Repo.get/2` spec says it can raise — the `:binary_id` cast happens before the query,
so there's no nil return path for unparseable input. Any user-facing context function
accepting an `id` parameter must guard for this.

## Solution

Rescue `Ecto.Query.CastError` at the context boundary and map to `{:error, :not_found}`:

```elixir
@spec get_finding(User.t(), binary()) :: {:ok, Finding.t()} | {:error, :not_found}
def get_finding(%User{} = user, id) do
  case Finding |> scope_findings(user) |> Repo.get(id) do
    nil -> {:error, :not_found}
    finding -> {:ok, finding}
  end
rescue
  Ecto.Query.CastError -> {:error, :not_found}
end
```

Add a test to pin the contract:
```elixir
test "returns {:error, :not_found} for malformed UUID string" do
  user = insert(:user)
  assert {:error, :not_found} = MyContext.get_thing(user, "not-a-uuid")
end
```

Note: `insert_ad_account_for_user(user)` is unnecessary in this test — `CastError` fires
before the scope join runs, so no DB data is needed.

## Prevention

- [ ] Any context function with `{:error, :not_found}` return on a `:binary_id` field must `rescue Ecto.Query.CastError`
- [ ] Add a malformed UUID test case alongside the nonexistent-UUID test case
- [ ] `get_*!/2` (raising) functions do not need this — they already raise on bad input
