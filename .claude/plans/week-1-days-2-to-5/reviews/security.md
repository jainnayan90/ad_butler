# Security Audit: AdButler OAuth / Session / Secrets (Week 1 Days 2-5)

## Executive Summary

Overall posture is **solid for an early feature**: strong OAuth state CSRF token generation (32 bytes CSPRNG), encrypted-at-rest access tokens via Cloak (AES-GCM), all OAuth credentials and Cloak key sourced from environment in `runtime.exs`, and `protect_from_forgery` + `put_secure_browser_headers` on the browser pipeline.

Severity summary: **0 Critical, 3 High, 5 Medium, 3 Low**.

---

## High Severity

### H1. Timing-unsafe OAuth state comparison
- **Location**: `auth_controller.ex:70-76`
- `verify_state/2` uses `==`, which short-circuits on first differing byte. Use `Plug.Crypto.secure_compare/2` instead. Also **delete `:oauth_state` from session after verification** — currently it persists and can be replayed.
- **OWASP**: A02 / A07.

### H2. No session rotation on authentication (session fixation)
- **Location**: `auth_controller.ex:52-54`
- `put_session(:user_id, user.id)` without session rotation.
- Fix: `configure_session(renew: true) |> clear_session()` before `put_session(:user_id, …)`. Add `live_socket_id` for force-logout support.
- **OWASP**: A07.

### H3. Sensitive values may leak into logs
- **Locations**: No `:filter_parameters` in `config/config.exs`; `Logger.error` with `inspect(reason)` in `auth_controller.ex:62` and `token_refresh_worker.ex:27` where `reason` may contain Meta API responses with token values.
- Fix: Add `config :phoenix, :filter_parameters, ["password", "access_token", "client_secret", "code", "fb_exchange_token", "token"]`. Replace `inspect(reason)` with structured field extraction.

---

## Medium Severity

### M1. Access token may appear in inspect-logged error bodies
- **Location**: `token_refresh_worker.ex:27` — `inspect(reason)` on token refresh error responses.

### M2. No `redact: true` on encrypted field
- **Location**: `meta_connection.ex:10`
- The struct holds **plaintext** in memory after decryption. `IO.inspect`, crash reports, or Logger metadata including a `%MetaConnection{}` will leak the token.
- Fix: `field :access_token, AdButler.Encrypted.Binary, redact: true`

### M3. Open-redirect pre-emption needed when `return_to` param is added
- Currently static redirect is fine. Must validate any future dynamic redirect target.

### M4. Rate-limit ETS: wrong key + unbounded growth
- **Location**: `meta/client.ex:118` — `parse_rate_limit_header(resp, params[:access_token])` passes the **access token** as `ad_account_id`. ETS key becomes the access token (PII in RAM), and `get_rate_limit_usage(ad_account_id)` can never find the entry.
- Fix: Pass the actual `ad_account_id` (parse from URL or thread through). Add periodic pruning in `RateLimitStore` GenServer and cap table size.

### M5. Account-takeover via email collision in `create_or_update_user`
- **Location**: `accounts.ex:14-22`
- `conflict_target: :email` with `{:replace, [:meta_user_id, …]}` means two Meta identities with the same email silently merge. Combined with the synthetic `"#{id}@facebook.com"` fallback this is dangerous.
- Fix: Upsert keyed on `meta_user_id`, not email. Meta's email is optional and not guaranteed unique across accounts.

---

## Low Severity

### L1. Synthetic `"#{id}@facebook.com"` email
- Fake non-routable address, may collide with real Meta addresses. Make email optional (nil) or fail login without email scope.

### L2. Session cookie options not explicit
- `endpoint.ex` session options don't set `secure: true, http_only: true` explicitly (Phoenix defaults are reasonable; be explicit).

### L3. `meta_user_id` in log metadata
- Third-party PII in retained logs — compliance consideration.

---

## Security Posture Summary

| Area | Status |
|------|--------|
| OAuth state generation | ✅ 32-byte CSPRNG |
| State comparison | ❌ `==` not constant-time; not cleared after use |
| Session rotation on login | ❌ Missing |
| Secrets management | ✅ All in runtime.exs via fetch_env! |
| Token storage at rest | ✅ Cloak AES-GCM; missing `redact: true` |
| Logging / PII | ❌ No :filter_parameters; inspect(reason) risks |
| CSRF / browser headers | ✅ protect_from_forgery on all browser routes |
| Rate-limit ETS key | ❌ Using access token as key instead of ad_account_id |
| Injection surface | ✅ cast/3 allow-list; no String.to_atom on user input |
