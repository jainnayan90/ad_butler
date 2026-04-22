# Scratchpad: week-1-security-fixes

## Session Salt Architecture

Salts (signing_salt, encryption_salt, live_view_signing_salt) are derivation inputs, not secrets.
The actual secret is SECRET_KEY_BASE (already in env vars via runtime.exs).

Current setup uses `Application.compile_env!` in endpoint.ex → values must be in compile-time
config files (not runtime.exs). This is why prod salts end up in prod.exs (committed).

To fully remove prod salts from git in future:
1. Change endpoint.ex `@session_options` from module attribute to a function
2. Switch from `compile_env!` to `Application.fetch_env!`
3. Move values to runtime.exs behind SESSION_SIGNING_SALT etc. env vars

Not done in this plan — scope is rotation only (invalidates existing sessions, makes committed values useless).

## Sweep Worker Simplification

The pending_ids pre-query was added to avoid duplicate Oban jobs, but TokenRefreshWorker already has:
  `unique: [period: {23, :hours}, keys: [:meta_connection_id]]`
Oban handles deduplication at insert time. The pre-query added complexity + a type mismatch bug.
Decision: remove entirely, rely on Oban uniqueness.

## PlugAttack X-Forwarded-For

Chosen simple approach: read first IP from X-Forwarded-For header directly.
Did NOT add `remote_ip` hex library — single proxy (Fly.io) makes this safe.
If multi-proxy setup is ever needed, add {:remote_ip, "~> 1.0"} dep and use RemoteIp plug.
