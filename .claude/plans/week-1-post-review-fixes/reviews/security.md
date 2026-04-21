# Security Audit: AdButler Week 1 Auth

## Executive Summary

Posture is solid. OAuth state uses `:crypto.strong_rand_bytes(32)` + `Plug.Crypto.secure_compare`, session renewed on login, dropped on logout, access tokens Cloak-encrypted with `redact: true`, cookies have `http_only`/`secure`(prod)/`encryption_salt`/`SameSite=Lax`, CSRF+secure headers active. No `String.to_atom`, `raw/1`, `binary_to_term`, or interpolated `fragment(...)` found.

---

## Critical
None.

## High

**H1. `encryption_salt` and `signing_salt` committed to repo**
`endpoint.ex:10-11` and `config/config.exs:23` — `signing_salt: "rfEmV5o0"`, `encryption_salt: "OPFmDMkSLnjk+Qu8"`, `live_view: [signing_salt: "oHp6OLvz"]` are in git history. Anyone with repo access + a leaked `SECRET_KEY_BASE` can forge session cookies. Rotation requires a code change.
Fix: Load from env in `runtime.exs` (`SESSION_SIGNING_SALT`, `SESSION_ENCRYPTION_SALT`, `LIVE_VIEW_SIGNING_SALT`); rotate current values since they're already in git history.

**H2. `require_authenticated_user` never verifies the user still exists**
`router.ex:45-53` — only checks `get_session(conn, :user_id)` is non-nil. A deleted/banned user, or a replayed session after `User` row deletion, still reaches `/dashboard`. Also no `assign(:current_user, ...)`.
Fix: Load user from DB in the plug; drop session and redirect if not found; assign `current_user`.

**H3. OAuth callback allows login-CSRF / session fixation**
`auth_controller.ex:38-61` — `state` proves the same browser started the flow, but doesn't stop an attacker-initiated flow (cross-site nav to `/auth/meta`, victim authenticates, now logged in as attacker). Callback also silently overwrites existing `:user_id`.
Fix: If session already has `:user_id`, treat callback as account-link not re-login. Add rate limiting (see M4). Require POST+CSRF to initiate flow.

**H4. Redundant `configure_session(renew: true) |> clear_session()` on login**
`auth_controller.ex:56-61` — both calls mutate the session. `renew: true` alone is the canonical Phoenix session-fixation defense; `clear_session/1` after it makes flash/CSRF lifecycle ambiguous.
Fix: Use `configure_session(renew: true) |> put_session(:user_id, user.id) |> put_session(:live_socket_id, ...)` without the extra `clear_session`.

## Medium

**M1. Logout uses `drop: true` — inconsistent with login idiom**
`auth_controller.ex:98-109` — `drop: true` is functional, but `configure_session(renew: true) |> clear_session()` is the canonical Phoenix pattern. Pick one and be consistent.

**M2. `meta_user_id` regex `~r/^\d+$/` has no length bound**
`user.ex:24` — accepts `"00000"` (leading zeros) and arbitrarily long strings. Meta IDs are ≤ ~17 digits.
Fix: `~r/^[1-9]\d{0,19}$/` + `validate_length(:meta_user_id, max: 20)`.

**M3. CSP `style-src 'unsafe-inline'`**
`router.ex:13` — permits inline `style=""` injection; can exfiltrate via CSS selector attacks. Acceptable short-term but plan migration to per-request nonce.

**M4. No rate limit on `/auth/meta` or `/auth/meta/callback`**
Unbounded OAuth requests consume Meta rate-limit budget and CPU. Add `Hammer`/`PlugAttack` keyed on IP (e.g. 10 req/min).

## Low

**L1.** `callback/2` error clause does not clear stale `:oauth_state` from session.
**L2.** `force_ssl` missing `preload: true, subdomains: true` — once all subdomains are HTTPS.
**L3.** `Base.decode64!` raises cryptic error on malformed `CLOAK_KEY` — use `Base.decode64/1` with a friendly message.
**L4.** `{state, issued_at}` tuple in session — a map `%{state: ..., issued_at: ...}` is more readable.
**L5.** `email` scope added — minimize permissions if email stored in User is sufficient going forward.

---

## Clarifications on prompted questions

1. **TTL + secure_compare ordering**: correct — short-circuit on TTL doesn't leak secret timing.
2. **Session hardening**: all correct. H1 flags committed salts.
3. **Auth plug bypass**: see H2 — deleted users bypass until cookie expiry.
4. **`drop` vs `renew`**: both secure; be consistent (M1).
5. **CLOAK_KEY guard**: sufficient. No timing-oracle (boot-time only).
6. **CSP `unsafe-inline`**: acceptable short-term (M3).
7. **`meta_user_id` edge cases**: empty rejected, leading zeros and unbounded length accepted — see M2.
8. **`force_ssl` placement**: correctly in prod block.
9. **HSTS completeness**: 1-year default. Missing `preload`/`subdomains` (L2).
