# Scratchpad — Week 1 Days 2-5

## Key decisions

### Cloak config goes in runtime.exs (not config.exs)
Sprint plan shows `config.exs` with `System.get_env` — but project principles say "Secrets from environment, runtime.exs only". Moved to `runtime.exs` with `System.fetch_env!` (hard failure if missing).

### Atomic upsert for create_or_update_user
Sprint plan uses get-then-insert pattern which races under concurrent OAuth. Plan uses `Repo.insert` with `on_conflict: {:replace, [:name, :meta_user_id, :updated_at]}, conflict_target: :email` instead.

### RateLimitStore GenServer owns ETS (not bare init call)
Sprint plan does `Meta.Client.init()` in application.ex — table owned by Application process. Using a dedicated supervised GenServer instead so table survives client crashes and is part of the supervision tree.

### update_meta_connection/2 added to Accounts context
Sprint plan's TokenRefreshWorker calls `Repo.update` directly — violates "Contexts own Repo". Added `update_meta_connection/2` to Accounts and worker must call it.

### Req.Test.stub for controller tests
No need for `bypass` gem — Req 0.5+ has built-in `Req.Test.stub/2`. AuthController makes two HTTP calls (token exchange + user info), both stubbed in tests.

### Oban testing: :inline for test env
Simpler than manual job execution for unit tests. If queue-ordering tests are needed later, switch specific tests to `:manual` mode.

### meta_client/0 config helper in TokenRefreshWorker
Worker reads `Application.get_env(:ad_butler, :meta_client, AdButler.Meta.Client)` so tests can inject `ClientMock` via `config/test.exs` without changing the worker module.

## Dead ends
(none yet)
