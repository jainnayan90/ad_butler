# Week-1 Pass-3 Fixes — Scratchpad

## Key Decisions

### B1 — Token leak via error logging
Worker catch-all at token_refresh_worker.ex:97-99 logs `reason: reason` verbatim. The risk is
transport error structs from Mint/Req when the GET refresh call fails (URL contains access_token
in query params). Fix: apply same `log_safe_reason/1` atom-safe pattern from auth_controller, but
inline in the worker (no shared module needed — the pattern is trivial).

In meta/client.ex: exchange_code/1 already returns `{:error, {:token_exchange_failed, body}}` —
body won't contain access_token (it's the error response body). The refresh_token/1 transport error
case returns `{:error, reason}` where reason is a Mint struct — doesn't contain the URL. The
access_token is in the GET params, but Mint transport errors don't embed request URLs.
Decision: safest fix is to sanitize in the worker logger, not the client. The `{:error, reason}`
from client functions is already reasonably safe, but we should log only a safe string.

### B2 — schedule_refresh/2 signature
`schedule_next_refresh/2` is private and already has the full connection object. To change
`schedule_refresh/2` to take `%MetaConnection{}`, we need to:
1. Thread `connection` through `do_refresh/2` → `schedule_next_refresh/2` → `schedule_refresh/2`
2. Currently `do_refresh(connection, id)` — it already has the connection
3. `schedule_next_refresh` is called with `schedule_next_refresh(connection.id, expires_in)` — change to `schedule_next_refresh(connection, expires_in)`
4. Inside `schedule_next_refresh`, call `schedule_refresh(connection, days)` where connection.id is the UUID

The sweep worker calls `TokenRefreshWorker.new/1` directly (not schedule_refresh), so it's not affected.
`perform/1` loads the connection from the DB by ID — stays the same.

### W1 — secure cookie compile-time fix
endpoint.ex uses `Mix.env() == :prod` in `@session_options` module attribute — compile-time.
`Application.compile_env(:ad_butler, :session_secure_cookie, true)` is the right fix.
The default `true` means prod (no explicit config needed). dev.exs and test.exs both need `false`.
The other `Mix.env() == :dev` in endpoint.ex (Tidewave plug) is a compile-time conditional for
plug inclusion, not a runtime value — that's correct usage, leave it alone.

### W2 — OAuth state cleanup on failure
Current: `verify_state/2` returns `{:ok, conn}` on success, `{:error, :invalid_state}` on failure.
Fix: return `{:error, :invalid_state, conn_with_state_deleted}` on failure paths. Update the
`else` clause in `callback/2` to pattern-match the 3-tuple.
On success, `clear_session()` in the happy path wipes everything anyway — no change needed there.

### S4 — Cloak key byte length
Dev key: "YWRfYnV0bGVyX2Rldl9rZXlfZm9yX2xvY2Fs" → "ad_butler_dev_key_for_local" = 27 bytes.
AES-256-GCM requires exactly 32 bytes. THIS IS A BUG — dev server would crash at vault init
(or Cloak may silently pad/fail). Test key "YWRfYnV0bGVyX3Rlc3Rfa2V5X2Zvcl90ZXN0aW5nISE="
→ "ad_butler_test_key_for_testing!!" = 32 bytes — OK.
Fix: regenerate dev key with `:crypto.strong_rand_bytes(32) |> Base.encode64()`.

### S5 — get_me/1 duplicate fields
`get_me/1` returns map with both `id:` and `meta_user_id:` set to the same value.
`accounts.ex:17` reads `user_info[:id]` for `meta_user_id`. Fix: remove `id:` key from get_me
return map, update accounts.ex to read `user_info[:meta_user_id]`.
Check: `create_or_update_user` uses `user_info[:name]` and `user_info[:email]` — those are unaffected.

### CSP fix (W3 + W4)
Combining into one task since they're in the same line of router.ex.
New CSP:
```
default-src 'self'; script-src 'self'; style-src 'self'; style-src-attr 'unsafe-inline';
img-src 'self' data:; font-src 'self'; frame-ancestors 'none'; form-action 'self';
base-uri 'self'; object-src 'none'
```
Note: Phoenix LiveView uses inline style attributes for some features — style-src-attr allows those.
