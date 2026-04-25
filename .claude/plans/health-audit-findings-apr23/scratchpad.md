# Scratchpad: health-audit-findings-apr23

## Dead Ends (DO NOT RETRY)

- **DEPS-2**: `broadway_rabbitmq ~> 0.9` does not exist on Hex (latest: 0.8.2). Do not retry until 0.9 is released.
- **DEPS-3**: `req ~> 0.6` does not exist on Hex (latest: 0.5.17). Current `~> 0.5` already covers 0.6.x by Elixir semver semantics. No change needed.

## Decisions

- **PERF-2**: `Oban.insert_all/1` returns a plain list `[Job.t()]`, NOT `{:ok, jobs}`. Updated impl accordingly.
- **PERF-2 testability**: `Oban.insert_all` has no application-level uniqueness check — used injectable `oban_mod()` + Mox `ObanMock` to test `{:error, :all_enqueues_failed}` path.
- **SEC-2 side-effect**: auth_controller_test.exs needed unique `remote_ip` per test to avoid sharing the tightened (3/min) PlugAttack bucket.

## Handoff

- Branch: module_documentation_and_audit_fixes
- Plan: .claude/plans/health-audit-findings-apr23/plan.md
- Next: (to be filled on session end)
