# Deployment Config Review: AdButler

## Summary

3 blockers found. `encryption_salt` hardcoded and `test.exs` Cloak key change are both acceptable.

---

## BLOCKERS

**B1 — Database SSL disabled in production**
`config/runtime.exs:57` — `ssl: true` is commented out, no `ssl_opts`. Production DB connections are unencrypted.
Fix:
```elixir
ssl: true,
ssl_opts: [verify: :verify_peer, cacerts: :public_key.cacerts_get()],
```

**B2 — Duplicate and conflicting `force_ssl` config**
`config/prod.exs:13-18` AND `config/runtime.exs:45-46` both define `force_ssl`. `runtime.exs` overwrites `prod.exs` at boot, silently dropping the `exclude: [hosts: ["localhost", "127.0.0.1"]]` clause. Internal/health-check traffic from localhost gets redirected to HTTPS.
Fix: Remove `force_ssl` from `prod.exs`; consolidate in `runtime.exs` with exclude list.

**B3 — `secure: Mix.env() == :prod` evaluated at compile time**
`lib/ad_butler_web/endpoint.ex:14` — `Mix.env()` resolves at compilation. If any artifact is built with `MIX_ENV != prod` and promoted to production, the `secure` cookie flag will be `false`. Safe only if all production builds guarantee `MIX_ENV=prod`.

---

## Warnings

**W1 — `PHX_HOST` silently defaults to `"example.com"`** (`runtime.exs:77`)
Change to: `System.get_env("PHX_HOST") || raise "PHX_HOST is required"`

**W2 — `CLOAK_KEY` required in dev, crashes without it**
Guard is `config_env() != :test` so dev also needs the env var. Move Vault runtime config to `if config_env() == :prod`; add a static dev key in `config/dev.exs`.

**W3 — No health check endpoints**
No `/health/startup`, `/health/liveness`, `/health/readiness`. Container orchestrators cannot safely manage the app without these.

---

## Acceptable

- `encryption_salt: "OPFmDMkSLnjk+Qu8"` (16 bytes) hardcoded in endpoint.ex — standard Phoenix pattern, salts don't need to be secret.
- `test.exs` Cloak key change to `"YWRfYnV0bGVyX3Rlc3Rfa2V5X2Zvcl90ZXN0aW5nISE="` — good hygiene improvement.
