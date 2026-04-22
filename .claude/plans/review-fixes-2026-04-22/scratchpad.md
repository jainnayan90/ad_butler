# Scratchpad: review-fixes-2026-04-22

## Decisions

- **MF-2 resolution**: Remove `SESSION_SIGNING_SALT` / `SESSION_ENCRYPTION_SALT` from `runtime.exs` prod block (not add more code). `endpoint.ex` uses `compile_env!` for `@session_options` — HTTP fetch_env! and LV socket compile_env! would produce a split-brain on key rotation. Keep `LIVE_VIEW_SIGNING_SALT` (different config path, safe at runtime).
- **W6 approach**: Salts move to `dev.exs`/`test.exs` with obviously-fake values. Prod salts injected at build/compile time, not runtime.exs.
- **W2 fallback key**: Replace real AES fallback with 32 zero bytes (`AAAA...AA=`) — obviously fake, avoids committing real key.

## Dead Ends
(none yet)
