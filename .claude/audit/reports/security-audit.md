# Security Audit — 2026-04-23

**Score: 80/100**

## Issues Found

### [M1] Meta Graph API tokens in URL query strings (Medium)
`lib/ad_butler/meta/client.ex:21–72, 180–199`
OWASP A02/A09. All GET calls pass `access_token` via `params:`. `filter_parameters` scrubs inbound request logs but not outbound URLs visible to Fly router, Meta access logs, or corporate proxies. `exchange_code/1` and `refresh_token/1` correctly use form bodies — extend to reads. -10 pts.
Fix: `headers: [{"authorization", "Bearer " <> access_token}]` on `list_ad_accounts`, `list_campaigns`, `list_ad_sets`, `list_ads`, `get_creative`, `get_me`.

### [M2] OAuth callback rate limit too coarse (Medium)
`lib/ad_butler_web/plugs/plug_attack.ex:18–26`
OWASP A07. Single 10 req/60s throttle covers all `/auth/*` routes. The callback path costs a Meta token-exchange + DB write — 10/min is too generous. -10 pts.
Fix: add a dedicated rule for `/auth/meta/callback` at 3/min.

### [L1] Dev Cloak key defaults to all-zeros base64 (Low)
`config/dev.exs:106–112`. Safe on isolated laptops; dangerous if dev data is ever shared. Drop the default, raise if unset.

### [L2] `dev_routes` guard is implicit (Low)
`lib/ad_butler_web/router.ex:79–93`. LiveDashboard + Swoosh mailbox mounted behind `compile_env(:ad_butler, :dev_routes)`. A future `config :ad_butler, dev_routes: true` in prod would silently expose both. Add `config_env() == :dev` to the if.

## Clean (one line each)

- Authentication: 32-byte random OAuth state, 600s TTL, secure_compare, session renewed on login, logout disconnects live sockets. ✓
- Authorization: all user-facing reads go through scope/2; `unsafe_get_ad_account_for_sync/1` explicitly labelled. ✓
- Input validation: changesets on User/MetaConnection; DLQ validates ad_account_id UUID; RequireAuthenticated casts session user_id via Ecto.UUID.cast. ✓
- SQL injection: all queries use `^`; no String.to_atom, fragment, binary_to_term, raw/ on user input. ✓
- XSS: strict CSP (script-src 'self', frame-ancestors 'none', object-src 'none'). ✓
- CSRF: :protect_from_forgery in :browser pipeline; OAuth state covers external round-trip. ✓
- Secrets: all prod secrets via env vars in runtime.exs; Cloak key length-checked at boot; @derive Inspect + redact: true on access_token; filter_parameters covers token/code/secret/salt. ✓
- Transport: force_ssl HSTS, cookies http_only + same_site: Lax + secure in prod, DB TLS verify_peer + system CAs. ✓
- Log sanitization: ErrorHelpers.safe_reason strips payloads; no logger access_token leaks. ✓
- DLQ: UUID-validated republish, ACK-and-drop invalid, NACK+requeue on failure. ✓
