---
module: "AdButler.Accounts"
date: "2026-04-21"
problem_type: data_integrity
component: ecto_query
symptoms:
  - "A user-revoked Meta connection becomes active again after the user re-authenticates via OAuth"
  - "on_conflict replace list includes :status, silently overwriting 'revoked' with 'active'"
root_cause: "on_conflict: {:replace, [..., :status, ...]} resets connection status to the changeset default ('active') on every OAuth upsert, bypassing explicit revocation"
severity: high
tags: [ecto, on_conflict, upsert, oauth, revocation, meta_connection, security]
---

# on_conflict Replacing :status Silently Re-activates Revoked Connections

## Symptoms

A Meta connection previously marked `status: "revoked"` (e.g., user explicitly disconnected,
or the token refresh worker detected a revoked token) is silently reactivated when the same
user goes through the OAuth flow again.

The `create_meta_connection/2` function uses `on_conflict: {:replace, [..., :status, ...]}`.
On conflict, Ecto replaces `:status` with the changeset's default value (`"active"`), erasing
the intentional `"revoked"` state stored in the database.

## Investigation

1. **Read `create_meta_connection/2`** — `on_conflict: {:replace, [:access_token, :token_expires_at, :scopes, :status, :updated_at]}` includes `:status`.
2. **Trace the OAuth flow** — `authenticate_via_meta/1` calls `create_meta_connection/2` on every successful OAuth. The changeset always starts with a default status.
3. **Check the changeset** — `MetaConnection.changeset/2` sets `status` to `"active"` by default when not explicitly provided.
4. **Root cause confirmed**: `:status` in the replace list means any revocation is undone on re-auth.

## Root Cause

`on_conflict: {:replace, fields}` runs an `UPDATE SET field = EXCLUDED.field` for every
field in the list. When `:status` is included, the DB overwrites whatever status the existing
row has with the value from the new insert (always `"active"` in the OAuth flow).

```elixir
# Problematic — :status in replace list undoes revocation on re-auth
on_conflict: {:replace, [:access_token, :token_expires_at, :scopes, :status, :updated_at]},
```

## Solution

Remove `:status` from the `on_conflict` replace list. The `TokenRefreshWorker` explicitly sets
`status: "revoked"` via `update_meta_connection/2` — that path should never be undone by
a plain OAuth upsert.

```elixir
# Fixed — :status is NOT in the replace list; revocation survives re-auth
on_conflict: {:replace, [:access_token, :token_expires_at, :scopes, :updated_at]},
conflict_target: [:user_id, :meta_user_id],
returning: true
```

### Files Changed

- `lib/ad_butler/accounts.ex:67` — Removed `:status` from `on_conflict` replace list

## Consequences of this Design

A user whose connection was revoked **cannot** reactivate it simply by re-logging in —
they will get a new token inserted (or the old one updated without status change) but
their connection remains in whatever state it was. If re-activation on re-auth IS desired,
it must be an explicit step (e.g., `on_conflict: {:replace, [..., :status, ...]}`
combined with a deliberate `status: "active"` in the attrs map).

## Prevention

- [ ] Review every `on_conflict: {:replace, [...]}` list — ask "should this field be reset on conflict?"
- [ ] Status fields that represent lifecycle transitions (active/revoked/suspended) should almost never be in a generic upsert replace list
- [ ] When using `on_conflict`, document which fields are intentionally reset and which must be preserved
