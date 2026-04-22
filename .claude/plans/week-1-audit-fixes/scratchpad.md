# Week-1 Audit Fixes — Scratchpad

## Key Decisions

### P2-T2 — Session salts: compile_env → fetch_env
`endpoint.ex` uses `Application.compile_env!` for session salts. Moving salts to `runtime.exs`
means they won't exist at compile time, so we must switch to `Application.fetch_env!` (reads
at startup, not compile time). This is safe — salts are not needed during compilation.
dev.exs and test.exs already set these keys statically, so non-prod envs are unaffected.

### P3-T2 — Meta.Client dispatch in Accounts
Current tests for `accounts_authenticate_via_meta_test.exs` use `Req.Test` plug injection
(not the behaviour mock). After switching to `meta_client()` dispatch, the tests will route
through `ClientMock` (from `config/test.exs: config :ad_butler, :meta_client, AdButler.Meta.ClientMock`).
Need to verify the test stubs are compatible with the behaviour mock interface, not the `Req.Test` approach.

### P4-T1 — Partial index WHERE clause
Postgres partial index `WHERE status = 'active'` matches the Ecto query condition
`mc.status == "active"`. The index will be used by the planner when both conditions match.
Use `create index` with `where:` option — no `unique_index` needed here.

### P5-T2 — PlugAttack test considerations
PlugAttack ETS storage (`plug_attack_storage`) is process-global. Tests must be `async: false`
and should reset the ETS table between tests to avoid cross-test pollution.
`conn.remote_ip` defaults to `{127, 0, 0, 1}` in test — set it explicitly to a tuple like
`{10, 0, 0, 1}` to avoid conflicting with other tests that hit the same bucket.
