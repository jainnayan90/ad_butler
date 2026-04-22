# Code Review: week-1-security-fixes

## Summary
- **Status**: ⚠️ Changes Requested
- **Issues Found**: 6

---

## Critical Issues

### 1. `auth_controller.ex` line 41-49 — Redundant same-user branch skips `clear_session`

The `if get_session(conn, :user_id) == user.id` branch redirects without clearing the session.
An attacker who has partially hijacked a session (or a developer who calls the callback twice
with the same account in the same browser tab) will **not** get a fresh session token.
The `clear_session()` + `configure_session(renew: true)` path is the correct path for all
logins; the fast-exit branch subverts it.

```elixir
# Current — skips session rotation for already-logged-in user
if get_session(conn, :user_id) == user.id do
  redirect(conn, to: ~p"/dashboard")
else
  conn
  |> clear_session()
  |> configure_session(renew: true)
  |> put_session(:user_id, user.id)
  ...
end

# Suggested — always rotate, then redirect
conn
|> clear_session()
|> configure_session(renew: true)
|> put_session(:user_id, user.id)
|> put_session(:live_socket_id, "users_sessions:#{user.id}")
|> redirect(to: ~p"/dashboard")
```

The extra DB round-trip saved by the short-circuit is negligible; session fixation risk is not.

---

### 2. `plug_attack.ex` lines 9-11 — X-Forwarded-For is attacker-controllable; no format validation

The fix reads `List.first/1` from the comma-split XFF value and uses it directly as the rate-limit
key **without validating it is a real IP address**. A client behind the proxy can send:

```
X-Forwarded-For: aaaaaaaaaaa...aaaa
```

and exhaust the ETS bucket namespace with arbitrary strings, or craft a key collision across
legitimate users. The string is used only as a map key (not executed), so this is a DoS concern
rather than injection, but it defeats rate-limiting entirely.

**Two issues:**

a. No validation that the extracted string is a valid IPv4/IPv6 address.
b. Relying on `List.first/1` after `String.split(",")` takes the *leftmost* (client-supplied)
   value. Behind a single well-configured Fly.io proxy the **rightmost** appended value is the
   one the proxy itself verified. Fly appends, never prepends.

```elixir
# Suggested replacement
client_ip =
  case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
    [forwarded | _] ->
      forwarded
      |> String.split(",")
      |> List.last()          # rightmost = proxy-verified
      |> String.trim()
      |> then(fn ip ->
        case :inet.parse_address(String.to_charlist(ip)) do
          {:ok, _} -> ip
          _ -> conn.remote_ip |> :inet.ntoa() |> to_string()
        end
      end)

    [] ->
      conn.remote_ip |> :inet.ntoa() |> to_string()
  end
```

---

## Warnings

### 3. `auth_controller.ex` lines 44-45 — `clear_session` + `configure_session(renew: true)` is redundant

`clear_session/1` removes all session keys. `configure_session(renew: true)` rotates the session
token but preserves existing keys. Calling both is not wrong (clear wins), but the intent is
confusing. If the goal is to prevent session fixation, `configure_session(renew: true)` alone
is sufficient after `put_session/3` calls. If the goal is to wipe previous session data,
`clear_session/1` alone achieves that. Together they work correctly but signal unclear intent —
add a comment or choose the minimal approach.

### 4. `token_refresh_sweep_worker.ex` line 43 — `:rand.uniform/1` produces `1..N`, never `0`

```elixir
jitter = :rand.uniform(86_400)   # range: 1..86_400
```

`:rand.uniform(N)` returns a value in `1..N`, so the minimum jitter is 1 second, never 0.
This is harmless in practice (1-second minimum jitter is fine) but is a common Erlang footgun.
Document it or use `:rand.uniform(86_400) - 1` if zero is intentional.

### 5. `accounts_test.exs` lines 193-202 — Stub dispatch is path-order-sensitive and fragile

The `Req.Test.stub` callback uses `String.contains?/2` to distinguish token-exchange from
user-info calls. If Meta ever adds a `/me/oauth/access_token`-style endpoint or path changes,
the stub silently returns the wrong fixture. Prefer matching on full path or using two separate
`Req.Test.stub` calls with `Req.Test.expect/3` for ordered expectations.

---

## Suggestions

### 6. `config.exs` line 28 — `live_view_signing_salt` duplicated across two config keys

`live_view: [signing_salt: "27ZZYgxL"]` is set both in the named application config
(`:ad_butler, live_view_signing_salt:`) and directly on the endpoint config
(`AdButlerWeb.Endpoint, live_view: [...]`). The endpoint config is what Phoenix actually reads;
the named key appears unused. Remove the `:live_view_signing_salt` application config key or
document which one is authoritative to avoid a confusing drift if only one is rotated.
