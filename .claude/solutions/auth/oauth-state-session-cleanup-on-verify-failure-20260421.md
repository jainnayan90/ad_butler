---
module: "AdButlerWeb.AuthController"
date: "2026-04-21"
problem_type: security_gap
component: oauth_session
symptoms:
  - "OAuth state nonce remains in session after verify_state/2 rejects it"
  - "Failed OAuth attempt leaves :oauth_state in session, allowing replay in the same session window"
  - "verify_state/2 returns {:error, :invalid_state} (2-tuple) but callback/2 else clause holds the original conn"
root_cause: "verify_state/2 failure paths did not delete the OAuth state from the session, and the failure return did not propagate the mutated conn to the callback caller"
severity: medium
tags: [oauth, session, security, csrf, state-token, phoenix, controller]
---

# OAuth State Nonce Must Be Deleted from Session on All verify_state Failure Paths

## Symptoms

After a failed OAuth callback (expired state, state mismatch, or missing session), the
`:oauth_state` key remains in the session. A second attempt within the same browser
session could theoretically replay the same nonce window, or the stale entry clutters
the session unnecessarily.

## Investigation

1. **Read `verify_state/2`** — on success, returns `{:ok, conn}` with session unchanged
   (the happy path calls `clear_session()` which wipes everything). On failure, returned
   `{:error, :invalid_state}` — a 2-tuple with no conn reference.
2. **Read `callback/2` else clause** — matched `{:error, :invalid_state}` and redirected
   using the *outer* `conn`, which still had `:oauth_state` in the session.
3. **Root cause**: failure paths returned a bare atom tuple; the session was never mutated
   on failure. The caller held the original conn with stale session data.

## Root Cause

The original `verify_state/2` return shape was:

```elixir
{:ok, conn}            # success — conn unchanged, clear_session handles cleanup
{:error, :invalid_state}  # failure — no conn, caller can't clean up
```

The `callback/2` else clause for `:invalid_state` redirected using the outer `conn` binding,
which still contained `:oauth_state` in the session.

## Solution

Change all failure paths in `verify_state/2` to return a 3-tuple carrying the cleaned conn:

```elixir
defp verify_state(conn, state) do
  case get_session(conn, :oauth_state) do
    nil ->
      {:error, :invalid_state, delete_session(conn, :oauth_state)}

    {stored_state, issued_at} ->
      cond do
        System.system_time(:second) - issued_at > @state_ttl_seconds ->
          {:error, :invalid_state, delete_session(conn, :oauth_state)}

        not Plug.Crypto.secure_compare(stored_state, state) ->
          {:error, :invalid_state, delete_session(conn, :oauth_state)}

        true ->
          {:ok, conn}
      end

    _ ->
      {:error, :invalid_state, delete_session(conn, :oauth_state)}
  end
end
```

Update the `callback/2` else clause to match and use the cleaned conn:

```elixir
else
  {:error, :invalid_state, conn} ->   # conn now has :oauth_state deleted
    conn
    |> put_flash(:error, "Invalid OAuth state. Please try again.")
    |> redirect(to: ~p"/")
```

Also rename the `with` success binding to avoid shadowing the outer `conn`:

```elixir
with {:ok, verified_conn} <- verify_state(conn, state),
     {:ok, user, _conn_record} <- Accounts.authenticate_via_meta(code) do
  verified_conn
  |> clear_session()
  ...
```

### Files Changed

- `lib/ad_butler_web/controllers/auth_controller.ex` — All 4 verify_state failure paths + callback/2 else clause + conn → verified_conn rename

## Prevention

- [ ] When a private function can fail and the caller needs the mutated conn, always return the conn in the failure tuple
- [ ] The pattern `{:error, reason, conn}` as a failure shape is idiomatic when session cleanup must happen on failure
- [ ] Test ALL verify_state branches — nil session, expired, mismatched, and catch-all — each is a distinct code path
- [ ] Success-path `clear_session()` is not a substitute for failure-path cleanup: different code paths execute different conn transformations
