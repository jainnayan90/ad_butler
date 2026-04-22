# Security Audit: Week 1 Auth + Oban Review-Fixes

⚠️ EXTRACTED FROM AGENT MESSAGE (Write access unavailable)

## Summary
Session fixation (B6) correctly addressed. `secure_compare` in place. Access tokens encrypted + redacted. `filter_parameters` set. No Iron Law violations. No critical issues.

## High

**H1. Session cookie missing http_only/secure/encryption_salt** (`lib/ad_butler_web/endpoint.ex:7-12`)
`@session_options` only sets `store`, `key`, `signing_salt`, `same_site`. Missing `http_only: true`, `secure: true` (prod), and `encryption_salt`. Session carries `:user_id` and `:live_socket_id`.
Fix: add `http_only: true`, `secure: Mix.env() == :prod`, `encryption_salt: <secret>`.
OWASP: A05:2021, A07:2021

**H2. No force_ssl/HSTS in prod** (`config/runtime.exs` — currently commented out)
Session cookie transmittable over plaintext HTTP. `secure: true` alone insufficient against SSL stripping.
Fix: `config :ad_butler, AdButlerWeb.Endpoint, force_ssl: [hsts: true, rewrite_on: [:x_forwarded_proto]]`
OWASP: A02:2021

## Medium

**M1. Raw Meta response bodies leak into Oban telemetry handler** (`application.ex:60`)
`log_safe_reason/1` strips body in auth_controller, but `application.ex` does `inspect(reason)` in exception handler. If an exception carries a Meta response tuple with tokens, they'd appear in logs. `filter_parameters` only covers Plug params, not Logger metadata.
Fix: sanitize at client boundary; apply same shape-match in Oban telemetry handler.

**M2. OAuth state has no TTL** (`auth_controller.ex:12-30,77-85`)
`:oauth_state` persists for full session lifetime. Replay window larger than necessary.
Fix: store `{state, System.system_time(:second)}`; reject in `verify_state/2` if older than 600s.

**M3. `get_me/1` fabricates `<id>@facebook.com` email** (`meta/client.ex:147`)
Fallback email collides with `users.email` unique index if someone holds that literal string; complicates later email-scope upgrade.
Fix: allow email nil; update `User.changeset` `validate_required` accordingly.

**M4. `User.changeset` lacks `meta_user_id` validation** (`accounts/user.ex:19-25`)
`meta_user_id` cast and used as `conflict_target` but never validated. Could be nil, making ON CONFLICT semantics unpredictable.
Fix: `validate_required([:email, :meta_user_id])`, `validate_format(:meta_user_id, ~r/^\d+$/)`.

**M5. `live_socket_id` set but no broadcast-on-logout path** (`auth_controller.ex:60`)
Correct value, but dormant until a logout handler broadcasts `"disconnect"`. Flag for Week 2.

**M6. `/dashboard` unprotected** (`router.ex:17-22`)
No `require_authenticated_user` plug. Anyone can GET `/dashboard`. Must land before Week 2 data exposure.

## Low

**L1. `schedule_refresh/2` has no upper bound on `days`** — add `min(..., 60)`.
**L2. Oban exception telemetry uses `inspect(reason)`** — sanitize like `log_safe_reason/1`.
**L3. Add runtime assertion that CLOAK_KEY != all-zero bytes in prod.**
**L4. No Content-Security-Policy header in router browser pipeline.**
**L5. `signing_salt` committed in config** — standard Phoenix practice but optional to move to runtime env for prod.

## Recommended Next Steps
1. H1 cookie hardening (http_only, secure, encryption_salt)
2. H2 force_ssl/HSTS
3. M1 sanitize Meta body at client boundary
4. M6 `require_authenticated_user` plug before Week 2
5. M2 state TTL
6. M4 `meta_user_id` validation
7. L3 CLOAK_KEY runtime guard
8. L4 CSP header

## Tools to run
`mix sobelow --exit medium`, `mix deps.audit`, `mix hex.audit`, `mix credo --strict`
