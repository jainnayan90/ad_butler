# Security Audit — 2026-04-23

**Score: 82/100**

## Issues Found

### MEDIUM — OAuth `error_description` reflected into flash without length/content guard
`lib/ad_butler_web/controllers/auth_controller.ex:50`

`error_description` from Meta's OAuth redirect is interpolated verbatim into a flash message. Phoenix HTML-escapes output so XSS is not directly exploitable, but an attacker influencing the redirect can inject an arbitrarily long or misleading string — effective for phishing. No length cap also bloats the cookie-backed session flash.

**Fix:** Truncate to ≤200 chars and/or use a fixed generic message; log the raw value server-side only.

### MEDIUM — `refresh_token` sends access token as GET query parameter
`lib/ad_butler/meta/client.ex:103-125`

Uses HTTP GET with `fb_exchange_token: access_token` in the query string. Query params appear in proxy/CDN access logs and Erlang HTTP client debug logs. `exchange_code` already uses POST with form body — `refresh_token` should do the same.

**Fix:** Switch `refresh_token` to HTTP POST with the token in the form body.

### LOW — Tidewave has only a compile-time env guard, no runtime gate
`lib/ad_butler_web/endpoint.ex:47-49`

`if Mix.env() == :dev` is correct, but a misconfigured CI/CD pipeline building with `MIX_ENV=dev` would expose full runtime introspection with no auth.

**Fix:** Add a secondary runtime check (`Application.get_env(:ad_butler, :dev_routes)`) alongside the compile-time guard.

### LOW — `unsafe_get_ad_account_for_sync/1` is public with no module boundary enforcement
`lib/ad_butler/ads.ex:59-61`

Documented as internal-only but callable from any module. The convention is not enforced at compile time.

**Fix:** Extract sync-internal DB access into `AdButler.Ads.Sync` so the public `AdButler.Ads` surface contains only user-scoped functions.

### LOW — Prod session salt validation requires only 8 bytes; Phoenix recommends 32
`config/prod.exs`

The minimum salt validation guard only requires 8 bytes.

**Fix:** Raise the prod.exs minimum validation from 8 to 32 bytes.

## Clean Areas

- OAuth CSRF: 32-byte CSPRNG state, server-side session storage, `Plug.Crypto.secure_compare/2`, 600 s TTL — fully correct
- Session config: `http_only`, `same_site: "Lax"`, secure in prod, signing + encryption salts, force_ssl + HSTS
- Authorization: all user-facing Ads queries go through `scope/2`/`scope_ad_account/2`; pinned binds (`^mc_ids`) throughout — no bypass vectors
- RequireAuthenticated: UUID-validates session user_id before any DB lookup; drops session and halts on all failure paths
- Rate limiting: PlugAttack on all auth routes; Fly header validated via `:inet.parse_address`
- Secret/token logging: `@derive {Inspect, except: [:access_token]}` + `redact: true`; AMQP URL sanitized; `ErrorHelpers.safe_reason/1` throughout; no raw tokens in logs
- Encrypted fields: `access_token` uses Cloak AES-GCM-256; key validated to exactly 32 bytes at startup
- CSP: `default-src 'self'`, `script-src 'self'`, `object-src 'none'`, `frame-ancestors 'none'` — no unsafe-eval/unsafe-inline
- Input validation: no `String.to_atom` with external input; no `Phoenix.HTML.raw/1` in templates
- Config secrets: all prod secrets from `System.fetch_env!` with raise guards

| Criterion | Score | Notes |
|---|---|---|
| No sobelow critical issues | 30/30 | clean |
| No sobelow high issues | 20/20 | clean |
| Authorization in all handle_events | 15/15 | no LiveViews yet |
| No String.to_atom with input | 10/10 | clean |
| No raw() with untrusted content | 10/10 | clean |
| Secrets in runtime.exs only | 7/15 | session salts static; dev Cloak key in repo |

## Issues

**[S1-MEDIUM] Session salts hardcoded at compile time — config.exs:17-19**
session_signing_salt / session_encryption_salt are static literals in VCS. OWASP A02.
Fix: load from env in runtime.exs for prod.

**[S2-LOW] Dev Cloak key committed to repo — dev.exs:96-101**
Literal base64 key. If dev DB dump leaks, encrypted tokens recoverable.
Fix: System.get_env("CLOAK_KEY_DEV") with .env convention.

**[S3-MEDIUM] MetadataPipeline: ad_account_id unvalidated — metadata_pipeline.ex:31-44**
Pre-existing W4. Non-UUID value raises Ecto.Query.CastError → DLQ churn. OWASP A03/A04.
Fix: Ecto.UUID.cast/1 before Repo.get; Message.failed on :error.

**[S4-MEDIUM] ReplayDlq replays without validation — replay_dlq.ex:33-37**
Pre-existing W9. Poisoned payloads re-enter pipeline. No env guard, unbounded limit.
Fix: Jason.decode each payload, skip malformed; cap limit; require --confirm for prod.

## Clean Areas

OAuth state CSRF, session management (renew on login, drop on logout), scope/2 in Ads context, all queries parameterized, CSP/HSTS/frame-ancestors, filter_parameters covers all sensitive fields, RequireAuthenticated validates UUID, PlugAttack on auth routes, encrypted + redacted access_token, AMQP reason sanitized in logs, no String.to_atom/raw/binary_to_term patterns.
