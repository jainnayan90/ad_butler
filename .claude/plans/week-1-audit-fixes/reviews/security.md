# Security Review: Week-1 Audit Fixes

⚠️ EXTRACTED FROM AGENT MESSAGE (Write permission denied in subagent context)

**Verdict**: REQUIRES CHANGES — 1 critical, 2 warnings

---

## Critical

### C1: Session salts committed to git (static, shared across all envs)
**Location**: `config/config.exs:15-17,27`

`session_signing_salt: "yp0B0EBm"`, `session_encryption_salt: "Cfg1C1OwCrAmNkVp"`, and `live_view signing_salt: "27ZZYgxL"` are now the **production** values — static in VCS, identical across dev/test/prod.

`endpoint.ex:10-11` uses `Application.compile_env!/2` which freezes values at build time — runtime env vars cannot override.

**vs. previous state**: Cryptographically neutral (same static salts existed in `prod.exs`), but **regression vs stated plan intent** — the structural affordance for per-env override is gone.

**Fix**: Replace `@session_options` module attribute with a `session_opts/0` function, call `Plug.Session.call(conn, Plug.Session.init(session_opts()))`, use `Application.fetch_env!/2` inside. Move salts to `runtime.exs` via `System.fetch_env!("SESSION_SIGNING_SALT")`. Rotate salts once env vars are wired.

**OWASP**: A02:2021; CWE-798.

---

## Warnings

### W1: `plug_attack.ex` IP extraction — unsafe outside Fly.io
`client_ip/1` trusts `fly-client-ip` header. Safe on Fly (edge strips user-supplied values). **Unsafe behind Nginx/Cloudflare/bare ELB** — attacker can rotate the header to bypass throttling.

Fix: make trusted-header configurable via `runtime.exs`, or document the Fly coupling explicitly. Also: add a test asserting header precedence over `conn.remote_ip`.

### W2: Residual risk in changeset error logging
`inspect(changeset.errors)` currently doesn't leak `access_token` (errors contain field names + messages, not changes). But a future validator adding `add_error(:access_token, "token #{val} invalid")` would leak.
Fix: add a regression test asserting the submitted token substring is absent from `inspect(changeset.errors)`.

---

## Positive Findings

- **Token refresh logging**: Correctly logs `changeset.errors` only (not `changeset.changes`). Improvement confirmed.
- **`meta_client/0` dispatch**: Safe — Application env not HTTP-reachable. Fallback to `AdButler.Meta.Client` is correct prod default.
- **`:filter_parameters`**: Covers `access_token`, `fb_exchange_token`, `code`, `client_secret`, `token`, `password`. Clean.
- **Auth, authorization, input validation, SQLi, XSS, CSRF**: All clean.

---

## Pre-existing (not this session)
- Static `secret_key_base` in `dev.exs` and `test.exs` — standard Phoenix, safe with `MIX_ENV=prod` on deploy.
