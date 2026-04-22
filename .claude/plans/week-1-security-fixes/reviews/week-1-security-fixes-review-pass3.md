# Week-1 Security Fixes — Review Pass 3

**Verdict: REQUIRES CHANGES**

All prior findings from passes 1 and 2 are confirmed resolved. Pass 3 surfaced 2 blockers, 5 warnings, and 6 suggestions.

---

## BLOCKERS (2)

### B1 — Access token leak via verbatim error logging
Files: `lib/ad_butler/workers/token_refresh_worker.ex:98`, `lib/ad_butler/meta/client.ex:147-148`

The catch-all error branch in `token_refresh_worker.ex` logs `reason: reason` verbatim. When the Meta `refresh_token` GET call fails, the error struct from Req/Mint can include the full URL with `access_token=...` in the query string. `:filter_parameters` only scrubs Plug conn params, not outbound HTTP error structs.

Fix: Apply `log_safe_reason/1` (already in auth_controller) in the worker. Strip `access_token` from error bodies in `meta/client.ex` before returning them.

### B2 — `schedule_refresh/2` accepts raw ID with no authorization scope
File: `lib/ad_butler/workers/token_refresh_worker.ex:30-35`

Public function takes any `meta_connection_id` string with no `UUID.cast/1` guard and no user scope. Future callers (controllers, LiveViews) can trigger token refresh for arbitrary connections.

Fix: Change signature to `schedule_refresh(%MetaConnection{} = conn, days)` so callers must load-and-authorize first.

---

## WARNINGS (5)

### W1 — `secure:` cookie uses compile-time `Mix.env()` [BOTH agents]
File: `lib/ad_butler_web/endpoint.ex:14`

`secure: Mix.env() == :prod` baked into `@session_options` at compile time. A release built with non-prod `MIX_ENV` ships without `Secure` flag on session cookies.

Fix: `secure: Application.compile_env(:ad_butler, :session_secure_cookie, true)` with `false` in dev/test config.

### W2 — OAuth state not deleted from session on failure
File: `lib/ad_butler_web/controllers/auth_controller.ex:64-84`

On `verify_state/2` failure, `{state, issued_at}` stays in session for up to 10 minutes. A captured session cookie keeps a replay-eligible state.

Fix: `delete_session(conn, :oauth_state)` on all failure exit paths of `verify_state/2`.

### W3 — CSP missing `frame-ancestors`, `form-action`, `base-uri`, `object-src`
File: `lib/ad_butler_web/router.ex:11-14`

Fix: Add `frame-ancestors 'none'; form-action 'self'; base-uri 'self'; object-src 'none'`.

### W4 — `style-src 'unsafe-inline'` enables CSS exfiltration
File: `lib/ad_butler_web/router.ex:13`

Fix: `style-src-attr 'unsafe-inline'; style-src 'self'` or nonce.

### W5 — `TokenRefreshWorker` retries full job on schedule failure
File: `lib/ad_butler/workers/token_refresh_worker.ex:51-61`

After a successful token update, a `schedule_next_refresh` failure returns `{:error, :schedule_failed}`, causing Oban to retry and re-refresh an already-updated token. The sweep covers missed schedules.

Fix: Log scheduling failures and return `:ok`.

---

## SUGGESTIONS (6)

### S1 — `xff_ip/1` takes rightmost XFF hop (proxy, not client)
File: `lib/ad_butler_web/plugs/plug_attack.ex:26`
`List.last()` returns the closest proxy. Should be `List.first()`. Low impact since `fly-client-ip` is tried first.

### S2 — `authenticate_via_meta/1` has no transaction boundary
File: `lib/ad_butler/accounts.ex:10-24`
Two Repo writes (`create_or_update_user` + `create_meta_connection`) without a transaction. Partial failure leaves orphaned user row. Non-corrupting (next login upserts correctly), but not atomic. Use `Ecto.Multi`.

### S3 — `on_conflict` revives revoked `MetaConnection`s
File: `lib/ad_butler/accounts.ex:54-62`
`on_conflict: {:replace, [..., :status, ...]}` silently re-activates revoked connections on new OAuth exchange. Remove `:status` from replace list.

### S4 — Dev/test Cloak keys are human-readable ASCII (verify byte length)
Files: `config/dev.exs:98`, `config/test.exs:51`
Keys decode to readable strings. Also verify they are 32 bytes — a 27-byte key raises at AES-256-GCM startup.

### S5 — `get_me/1` returns duplicate `id` and `meta_user_id` fields
File: `lib/ad_butler/meta/client.ex:163-170`
Both map to the same value. Pick one canonical key.

### S6 — Auth controller test happy-path stub missing `expires_in`
File: `test/ad_butler_web/controllers/auth_controller_test.exs:54`
Stub exercises fallback TTL path silently. Add `"expires_in" => 86400`.

---

## Previously Resolved (Confirmed)

All pass-1 and pass-2 findings confirmed present and correct in current code.
