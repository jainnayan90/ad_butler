# Code Review: Week 1 Days 2-5 — OAuth + Meta Client + Token Refresh

## Summary
- **Status**: ⚠️ Changes Requested
- **Issues Found**: 8 (2 critical, 4 warnings, 2 suggestions)

---

## Critical Issues

### 1. `token_refresh_worker.ex:16` — Hard crash masks idempotency

```elixir
# Current
{:ok, _} =
  Accounts.update_meta_connection(connection, %{...})
```

If `update_meta_connection/2` returns `{:error, changeset}`, the worker crashes with a `MatchError`. Oban retries, but `schedule_next_refresh` is never called and nothing is logged. Match explicitly:

```elixir
case Accounts.update_meta_connection(connection, %{access_token: token, token_expires_at: expiry}) do
  {:ok, _} ->
    schedule_next_refresh(connection.id, expires_in)
    Logger.info("Token refresh success", meta_connection_id: id)
    :ok
  {:error, changeset} ->
    Logger.error("Token update failed", meta_connection_id: id, reason: inspect(changeset))
    {:error, :update_failed}
end
```

### 2. `auth_controller.ex:47` — Hardcoded 60-day expiry is a magic number

`60 * 24 * 60 * 60` should be a named module attribute `@meta_long_lived_token_ttl_seconds` so it is searchable and self-documenting.

---

## Warnings

### 3. `meta/client.ex:154` — `elem_or_nil/2` helper is unnecessary

Replace with a pattern match inline — more idiomatic and removes a private helper:

```elixir
# Instead of:
List.keyfind(headers, "x-business-use-case-usage", 0) |> elem_or_nil(1)

# Use:
case List.keyfind(headers, "x-business-use-case-usage", 0) do
  {_, value} -> value
  nil -> nil
end
```

### 4. `meta/client.ex:161-173` — Duplicate `with` branches in `parse_rate_limit_header/2`

The `[json | _]` and `is_binary(json)` branches are identical after unwrapping. Collapse them:

```elixir
raw_value = case raw do
  [json | _] -> json
  json when is_binary(json) -> json
  _ -> nil
end

with binary when is_binary(binary) <- raw_value,
     {:ok, decoded} <- Jason.decode(binary),
     [{_key, [%{"call_count" => cc, "cpu_time" => cpu, "total_time" => total}]}] <- Enum.take(decoded, 1) do
  :ets.insert(@rate_limit_table, {ad_account_id, {cc, cpu, total, DateTime.utc_now()}})
end
```

### 5. `auth_controller.ex:111` — Fabricated `@facebook.com` email is dangerous

```elixir
email: body["email"] || "#{id}@facebook.com"
```

This synthesized address passes `validate_format(:email, ~r/@/)` silently and could collide with a real user. Either require the email permission and return an error when absent, or store `nil` and make `email` optional in the changeset.

### 6. `accounts.ex:29-33` — Prefer struct literal over `Map.put` for association

```elixir
# Current
MetaConnection.changeset(Map.put(attrs, :user_id, user.id))

# Suggested — explicit struct, clearer intent
%MetaConnection{user_id: user.id}
|> MetaConnection.changeset(attrs)
|> Repo.insert()
```

---

## Suggestions

### 7. `req_options/0` duplicated between `Client` and `AuthController`

Both define the identical private helper. Move all `Req` calls (including token exchange and user-info fetch) into `AdButler.Meta.Client` or a new `AdButler.Meta.HTTP` module, keeping the controller free of raw HTTP calls and eliminating the duplication.

### 8. `token_refresh_worker.ex:34` — Atom keys in `schedule_refresh/2` vs string keys in `perform/1`

`%{meta_connection_id: id}` becomes `%{"meta_connection_id" => id}` after Oban's JSON round-trip. This works correctly, but the mismatch is confusing. Use string keys in the literal to match `perform/1`'s pattern and make the intent explicit.
