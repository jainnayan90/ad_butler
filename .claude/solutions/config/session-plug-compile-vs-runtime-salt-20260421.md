---
module: "AdButlerWeb.Endpoint"
date: "2026-04-21"
problem_type: integration_issue
component: configuration
symptoms:
  - "Session salts are frozen at compile time; runtime.exs cannot rotate them without a full redeploy"
  - "Using compile_env! for session salts blocks hot config reload"
  - "Using fetch_env!/get_env in @session_options warns in module body"
root_cause: "Phoenix Endpoint requires compile-time values for socket connect_info (LiveView socket), but HTTP session plug reads options at request time — these have different lifecycle requirements"
severity: high
tags: [session, session-salt, compile-env, runtime-rotation, phoenix-endpoint, liveview-socket, plug-session]
---

# Session Plug: compile_env vs Runtime Rotation Trade-off

## Symptoms

Two conflicting requirements in `AdButlerWeb.Endpoint`:

1. `socket "/live"` requires `@session_options` as a **compile-time module attribute** (LiveView socket's `connect_info` is evaluated at compile time)
2. Rotating session salts via `runtime.exs` requires **runtime reads** — but `Application.compile_env!` blocks runtime.exs from overriding the value (raises on startup if the value changed)

Attempting to use `fetch_env!` or `get_env` in `@session_options` triggers Elixir warnings.

## Investigation

1. **Tried `plug Plug.Session, @session_options`** — salts frozen at compile time, no runtime rotation possible
2. **Tried `fetch_env!` in `@session_options`** — Elixir warns: discouraged in module body
3. **Tried `compile_env!` + runtime.exs override** — boots successfully but `compile_env!` raises at startup if runtime.exs changes the value
4. **Solution**: split into two layers — `@session_options` with `compile_env!` for socket, separate `session/2` function with `fetch_env!` for HTTP requests

## Root Cause

Phoenix LiveView's `socket connect_info: [session: @session_options]` evaluates `@session_options` at **compile time** — there's no way around using a module attribute here. But the HTTP session plug can be a runtime function call.

`compile_env!` adds a compile-time assertion: if runtime.exs sets a different value, Elixir raises at startup. This is intentional — it prevents the config from diverging between compile and runtime. But it means you cannot rotate salts solely via environment variables without a recompile.

## Solution

Split session configuration into two layers:

```elixir
# Module attribute — used only for socket (compile-time requirement)
# Uses compile_env! → boot-time check, cannot be overridden by runtime.exs alone
@session_options [
  store: :cookie,
  key: "_ad_butler_key",
  signing_salt: Application.compile_env!(:ad_butler, :session_signing_salt),
  encryption_salt: Application.compile_env!(:ad_butler, :session_encryption_salt),
  same_site: "Lax",
  http_only: true,
  secure: Application.compile_env(:ad_butler, :session_secure_cookie, true)
]

# Socket uses @session_options (compile-time, required by LiveView)
socket "/live", Phoenix.LiveView.Socket,
  websocket: [connect_info: [session: @session_options]]

# HTTP session uses function plug (reads at call time, no module-body warning)
plug :session

defp session(conn, _opts) do
  opts =
    Plug.Session.init(
      store: :cookie,
      key: "_ad_butler_key",
      signing_salt: Application.fetch_env!(:ad_butler, :session_signing_salt),
      encryption_salt: Application.fetch_env!(:ad_butler, :session_encryption_salt),
      same_site: "Lax",
      http_only: true,
      secure: Application.get_env(:ad_butler, :session_secure_cookie, true)
    )
  Plug.Session.call(conn, opts)
end
```

**Rotation caveat**: HTTP sessions can be rotated by updating Application env externally (e.g., hot config reload). LiveView socket sessions remain locked to the compiled value — a recompile is required to rotate those.

### Files Changed

- `lib/ad_butler_web/endpoint.ex` — added `session/2` function plug; `@session_options` retained for socket

## Prevention

- Never use `plug Plug.Session, @session_options` if you need runtime salt rotation
- Document the LiveView socket limitation: socket session config ALWAYS requires compile-time values
- If salt rotation is required: use the function plug pattern above; rotate HTTP sessions via Application env update; accept LiveView sockets need a redeploy
- `compile_env!` vs `compile_env` (without `!`): the bang version raises if key is missing; no-bang returns the default — prefer `!` for required keys

## Related

- `.claude/solutions/build-issues/application-fetch-env-warning-in-module-body-20260421.md` — The warning that surfaces when mixing env access in module body
