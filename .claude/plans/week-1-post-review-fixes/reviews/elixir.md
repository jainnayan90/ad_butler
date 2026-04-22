# Code Review: week-1-post-review-fixes

## Summary
- **Status**: Changes Requested
- **Issues Found**: 7

---

## Critical

### 1. `token_refresh_worker.ex:61-78` — Inner case result discarded silently
The `{:error, err}` branch of the inner `update_meta_connection` case returns `Logger.warning/2` (`:ok`), and execution falls through unconditionally to `{:cancel, Atom.to_string(reason)}`. Functionally correct but misleading — Credo will flag unused return. Use `_ = case ...` or restructure with a helper.

### 2. `auth_controller.ex:10` — Hard-coded 60-day TTL ignores actual `expires_in` from Meta
```elixir
@meta_long_lived_token_ttl_seconds 60 * 24 * 60 * 60
```
The token exchange response contains an `expires_in` field (the worker reads it on refresh). The controller ignores this and stores a hard-coded 60-day expiry. `token_expires_at` will be wrong for initial connections, causing `schedule_next_refresh` to use stale data on the first job run. Use `expires_in` from the exchange response.

### 3. `auth_controller.ex:43-44` — Business logic leaks into controller
Controllers must stay thin. OAuth token exchange and user info fetching are business operations that belong in `AdButler.Accounts`, not in the controller. Should call something like `Accounts.authenticate_via_meta/2`.

---

## Warnings

### 4. `auth_controller.ex:87` — `if` with `&&` conflates two distinct failure conditions
Two separate conditions (expired vs. mismatched state) are collapsed into one branch, making it impossible to log or handle them differently. Prefer `cond` with separate clauses; also avoids the `&&` short-circuit that Credo discourages.

### 5. `auth_controller.ex:39-40,44` — Inconsistent credential loading
Controller reads `meta_app_id`/`meta_app_secret` and passes to `Client.exchange_code/3`, but `Client.refresh_token/1` reads the same values internally. `exchange_code` should read credentials internally, matching the `refresh_token` pattern.

### 6. `router.ex:45-53` — `require_authenticated_user` as private router function, doesn't assign `current_user`
Private plugs in the router can't be tested in isolation and won't scale. Standard Phoenix pattern is a module plug (e.g., `AdButlerWeb.Plugs.RequireAuthenticated`) that also assigns `conn.assigns.current_user`. Every authenticated LiveView `handle_event` will need `current_user` — not having it on assigns means each handler must re-fetch from session.

### 7. `token_refresh_worker.ex:98-104` — Schedule failure swallowed; token silently stops refreshing
```elixir
{:error, reason} -> Logger.error("Failed to schedule next refresh", ...)
# returns :ok — no propagation
```
A scheduling failure means the token will never refresh again. Consider returning `{:error, :schedule_failed}` so Oban retries or alerts.

---

## Suggestions

- **S1.** `accounts.ex:53` — `status` compared as string in query. An `Ecto.Enum` type would be type-safe and self-documenting.
- **S2.** `auth_controller_test.exs` — Add comment explaining why `async: false` is required.
- **S3.** `meta/client.ex:202-235` — Add `# Req <2.0 returns list, >=2.0 returns map` note explaining the `cond` over header formats.
