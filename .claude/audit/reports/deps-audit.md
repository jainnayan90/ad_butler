# Dependency Audit — 2026-04-23

**Score: 60/100**

## Issues Found

### [-10] `broadway_rabbitmq ~> 0.8` — outdated
Locked at 0.8.2 (2023). Upstream has 0.9+ with Broadway 1.1+ improvements. `~> 0.8` silently blocks upgrades.

### [-10] `req ~> 0.5` — constraint blocks 0.6+ upgrade
Locked at 0.5.17. Swoosh already allows `~> 0.6`. Not a security issue but creates technical debt.

### [-5] `plug_attack ~> 0.4` — unmaintained since 2022-09-13
Last release 0.4.3, no commits since. Security-sensitive layer with no upstream maintenance. Evaluate `hammer` or custom plug.

### [-5] `ex_machina` wrong scope
`only: [:test, :dev]` should be `only: :test`. Factory is in `test/support/`; seeds file does not use ExMachina.

### [-4] `sobelow` absent
Missing Phoenix-specific security static analysis for a project handling OAuth, encrypted tokens, and rate-limiting plugs. Add `{:sobelow, "~> 0.13", only: :dev, runtime: false}`.

### [-3] `dialyxir` absent
No type checking. Would catch structural errors in `meta/client.ex` and Oban worker arg shapes.

### [-3] `tidewave ~> 0.1` constraint too loose
`~> 0.1` resolves to `>= 0.1.0 and < 1.0.0`. Locked at 0.5.6. Tighten to `~> 0.5`.

## Clean (one line each)

- No known CVEs in any locked version (mix hex.audit clean). ✓
- No duplicate package versions in lock file. ✓
- No unused deps — all 29 direct deps verified in use. ✓
- `credo ~> 1.6` correctly has `runtime: false`. ✓
- Core deps use tight `~>` constraints; no dangerously open `>= 0.1.0` on prod-critical packages. ✓
- No retired packages. ✓

## Recommended Actions (Priority)

1. Add `{:sobelow, "~> 0.13", only: :dev, runtime: false}` + `mix sobelow` in precommit
2. Add `{:dialyxir, "~> 1.4", only: :dev, runtime: false}`
3. Fix `ex_machina` scope: `only: :test`
4. Evaluate `plug_attack` replacement; file tracking issue
5. Upgrade `req` constraint to allow `~> 0.5 or ~> 0.6`
6. Tighten `tidewave` to `~> 0.5`
7. Evaluate `broadway_rabbitmq ~> 0.9` upgrade with integration test run
