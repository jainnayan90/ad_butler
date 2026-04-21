---
module: "AdButlerWeb.Endpoint"
date: "2026-04-21"
problem_type: build_error
component: configuration
symptoms:
  - "warning: Application.fetch_env!/2 is discouraged in the module body"
  - "warning: Application.get_env/3 is discouraged outside of a function"
  - "Compile warning treated as error breaks build with --warnings-as-errors"
root_cause: "Application.fetch_env!/2 and get_env/3 read config at compile time in module body; Elixir warns because the value may not be set yet during compilation of the module itself"
severity: medium
tags: [application-env, compile-env, fetch-env, module-body, configuration, warning]
---

# Application.fetch_env!/get_env Warning in Module Body

## Symptoms

Elixir emits compile warnings when `Application.fetch_env!` or `Application.get_env`
are used inside a module attribute (module body):

```
warning: Application.fetch_env!/2 is discouraged in the module body,
use Application.compile_env!/2 instead
```

With `mix compile --warnings-as-errors` this becomes a build-breaking error.

## Investigation

1. **Tried `fetch_env!` in `@session_options` module attribute** — triggered warning
2. **Tried `get_env` in `@session_options` module attribute** — also triggered warning
3. **Tried `compile_env!` in function body** — Elixir error: compile_env cannot be called inside functions, only module body
4. **Root cause found**: `compile_env!` belongs in module body; `fetch_env!`/`get_env` belong in function bodies

## Root Cause

Elixir distinguishes between compile-time and runtime config access:

- `Application.compile_env!/2` — safe in module body; reads during compilation; adds a boot-time consistency check (raises on startup if runtime.exs changes the value)
- `Application.fetch_env!/2` / `Application.get_env/3` — safe only in function bodies; reading in module body can capture stale values if the app hasn't started yet

The warning exists because using `fetch_env!` in module body is order-dependent: if the key isn't set yet when the module compiles, you get a runtime error at an unexpected time.

```elixir
# WRONG — warns
@session_options [
  signing_salt: Application.fetch_env!(:ad_butler, :session_signing_salt)
]

# WRONG — also warns
@session_options [
  signing_salt: Application.get_env(:ad_butler, :session_signing_salt)
]

# WRONG — compile_env cannot be called in function body
defp session(conn, _opts) do
  salt = Application.compile_env!(:ad_butler, :session_signing_salt)
end
```

## Solution

**Module attribute**: use `compile_env!` (compile-time, warning-free in module body)
**Function body**: use `fetch_env!` or `get_env` (runtime, warning-free in functions)

```elixir
# Module attribute — compile_env! is correct here
@session_options [
  signing_salt: Application.compile_env!(:ad_butler, :session_signing_salt),
  secure: Application.compile_env(:ad_butler, :session_secure_cookie, true)
]

# Function body — fetch_env!/get_env are correct here
defp session(conn, _opts) do
  opts = Plug.Session.init(
    signing_salt: Application.fetch_env!(:ad_butler, :session_signing_salt),
    secure: Application.get_env(:ad_butler, :session_secure_cookie, true)
  )
  Plug.Session.call(conn, opts)
end
```

### Files Changed

- `lib/ad_butler_web/endpoint.ex` — `@session_options` uses `compile_env!`, `session/2` function uses `fetch_env!`

## Prevention

- [ ] In any module attribute that reads config: always use `compile_env!`
- [ ] In any function body that reads config: always use `fetch_env!` or `get_env`
- Never mix: `compile_env` in functions raises, `fetch_env!` in module body warns
- Tip: `compile_env!` adds a boot-time check that raises if `runtime.exs` tries to override the value — document this trade-off when it matters (e.g., session salt rotation)

## Related

- `.claude/solutions/config/session-plug-compile-vs-runtime-salt-20260421.md` — When compile_env! blocks runtime.exs rotation
