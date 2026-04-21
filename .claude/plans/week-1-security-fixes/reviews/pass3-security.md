# Security Review — Pass 3

## Prior Findings — All Verified Resolved

- C1: Session fixation — RESOLVED (`clear_session` + `configure_session(renew: true)` + fast-exit branch gone)
- C2: XFF spoofing — RESOLVED (`fly-client-ip` primary, `List.last()` XFF fallback)
- Pass2 W2: Sweep uniqueness — RESOLVED (`unique: [period: {6, :hours}, fields: [:worker]]`)
- Pass2 W3: Jitter window — RESOLVED (`:rand.uniform(3_600)`)
- S2: runtime.exs meta credentials guard — RESOLVED (`== :prod`)

---

## [BLOCKER] Access token may leak via verbatim error logging

File: `lib/ad_butler/workers/token_refresh_worker.ex:98` + `lib/ad_butler/meta/client.ex:147-148`

`token_refresh_worker.ex:98` logs `reason: reason` verbatim on the catch-all error branch. When the Meta `refresh_token` call uses a GET with `access_token=...` in the query string, a `Mint.TransportError` or Req error struct can include the full URL. `:filter_parameters` only scrubs Plug conn params, not outbound Req telemetry. A live 60-day token can end up in logs.

Fix: Apply the same `log_safe_reason/1` used in `auth_controller.ex` in the worker. In `meta/client.ex`, strip `access_token` from error bodies before returning:
```elixir
{:error, reason} -> {:error, sanitize_transport_error(reason)}  # strip URL params
```

---

## [BLOCKER] `schedule_refresh/2` accepts raw ID with no authorization scope

File: `lib/ad_butler/workers/token_refresh_worker.ex:30-35`

The public `schedule_refresh/2` accepts any `meta_connection_id` string and enqueues a job. No `Ecto.UUID.cast/1` guard, no user scope. Any future controller/LiveView calling this with user-supplied input can trigger token refresh for arbitrary connections.

Fix: Change signature to `schedule_refresh(%MetaConnection{} = conn, days)` so the caller must load-and-authorize first. Add a scoped loader `get_meta_connection_for_user!(user, id)`.

---

## [WARNING] `secure:` cookie flag uses compile-time `Mix.env()`

File: `lib/ad_butler_web/endpoint.ex:14`

`secure: Mix.env() == :prod` is evaluated at compile time. A release built with non-prod `MIX_ENV` ships without the `Secure` flag on session cookies.

Fix: `secure: Application.compile_env(:ad_butler, :session_secure_cookie, true)` with `config :ad_butler, session_secure_cookie: false` in dev/test.exs.

---

## [WARNING] OAuth state not deleted from session on failure paths

File: `lib/ad_butler_web/controllers/auth_controller.ex:64-84`

On failure, `{state, issued_at}` remains in the session until TTL expiry (10 min). A captured session cookie keeps a replay-eligible state. Success clears it via `clear_session()`, but failure branches don't.

Fix: `delete_session(conn, :oauth_state)` on every exit path from `verify_state/2`.

---

## [WARNING] CSP missing `frame-ancestors`, `form-action`, `base-uri`, `object-src`

File: `lib/ad_butler_web/router.ex:11-14`

`default-src 'self'` does not cover clickjacking via `frame-ancestors` or form hijacking via `form-action`.

Fix:
```
default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline';
img-src 'self' data:; font-src 'self'; frame-ancestors 'none';
form-action 'self'; base-uri 'self'; object-src 'none'
```

---

## [WARNING] `style-src 'unsafe-inline'` enables CSS-based exfiltration

File: `lib/ad_butler_web/router.ex:13`

Combined with any future reflected HTML injection, inline `style=` attributes permit CSS attribute-selector data exfiltration.

Fix: `style-src-attr 'unsafe-inline'; style-src 'self'` or per-request nonce.

---

## [SUGGESTION] `on_conflict` in `create_meta_connection` revives revoked connections

File: `lib/ad_butler/accounts.ex:54-62`

`on_conflict: {:replace, [..., :status, ...]}` silently re-activates a user-revoked connection when a new OAuth code is exchanged.

Fix: Remove `:status` from the replace list; handle activation transitions explicitly.

---

## [SUGGESTION] Dev/test Cloak keys are human-readable ASCII

File: `config/dev.exs:98`, `config/test.exs:51`

Keys decode to readable ASCII strings. Also verify they decode to exactly 32 bytes — a 27-byte key will raise on AES-256-GCM startup.

Fix: Use `:crypto.strong_rand_bytes(32) |> Base.encode64()`.

---

## [SUGGESTION] Regex applied before `validate_length` allows huge-string scan

File: `lib/ad_butler/accounts/user.ex:24`

The `meta_user_id` regex is anchored and bounded, but a 10 MB string is still fully scanned before rejecting. Add `validate_length(:meta_user_id, max: 20)` before the `validate_format` call.

---

## [SUGGESTION] `get_user_by_email/1` latent enumeration oracle

File: `lib/ad_butler/accounts.ex:33`

Not in the auth path now — annotate or remove until needed to avoid accidental exposure.

---

## [SUGGESTION] Rate limit on `/auth/meta/callback` is lenient

File: `lib/ad_butler_web/plugs/plug_attack.ex:8-14`

10 req/60s is generous for the OAuth callback. Consider 3/60s for the callback route specifically.

---

## Checked Clean

CSRF, SQL injection (all Ecto queries use `^`), XSS (no `raw/1`), `MetaConnection.access_token` Cloak-encrypted + `redact: true`, `:filter_parameters` covers `access_token/code/client_secret`, session `http_only: true` + `same_site: "Lax"`, HSTS via `force_ssl`, Repo SSL `verify_peer`, Oban job args use string keys.
