# Triage: week3-liveview-ui-deploy
Date: 2026-04-25

## Fix Queue

- [x] [B1] Replace `Jason.encode!` with `Jason.encode/1` in `UsageHandler.encode_metadata/1`
  - `lib/ad_butler/llm/usage_handler.ex:91`
  - Return `nil` on `{:error, _}` — never raise from a telemetry handler

- [x] [B2] Fix dead `handle_info(:reload_on_reconnect)` — gate data loading on `connected?(socket)` in both LiveViews
  - `lib/ad_butler_web/live/dashboard_live.ex`
  - `lib/ad_butler_web/live/campaigns_live.ex`
  - In `mount/3`: initialise streams to `[]`, then `if connected?(socket), do: send(self(), :reload_on_reconnect)` — eliminates disconnected query and makes reconnect actually refresh

- [x] [W1] Move `UsageHandler.attach()` to after `Supervisor.start_link/2` in `Application.start/2`
  - `lib/ad_butler/application.ex:21`
  - Currently called before Repo exists; safe today (no LLM client), crash risk when wired

- [x] [W2] Add status allowlist in `CampaignsLive.handle_event("filter", ...)`
  - `lib/ad_butler_web/live/campaigns_live.ex:61-68`
  - `@valid_statuses ~w(ACTIVE PAUSED DELETED)` — reject unknown values before push_patch

- [x] [W3] Fix flawed duplicate-row assertion to scope by `request_id`
  - `test/ad_butler/llm/usage_handler_test.exs:63`
  - `Repo.aggregate(from(u in Usage, where: u.request_id == "req-dup"), :count, :id)`

- [x] [W4] Add `on_exit` telemetry detach in LLM handler test setup
  - `test/ad_butler/llm/usage_handler_test.exs:9`
  - `on_exit(fn -> :telemetry.detach("llm-usage-logger") end)`

- [x] [W5] Nilify empty `request_id` in `UsageHandler.build_attrs/3`
  - `lib/ad_butler/llm/usage_handler.ex`
  - `request_id: nilify_blank(metadata[:request_id])` — prevents empty-string idempotency collision

- [x] [S1] Add `handle_event("filter")` test with `render_change` + `assert_patch`
  - `test/ad_butler_web/live/campaigns_live_test.exs`
  - Cover `push_patch` URL construction and `maybe_put_str` empty-string logic

- [x] [S2] Add `[:llm, :request, :exception]` event test asserting `status: "error"`
  - `test/ad_butler/llm/usage_handler_test.exs`

- [x] [S3] Strengthen `html =~ "1"` assertion in DashboardLive test
  - `test/ad_butler_web/live/dashboard_live_test.exs:25`
  - Replace with a targeted check on the stat card value

- [x] [S4] `stat_card` value attr `:any` → `:integer`; unify `maybe_put`/`maybe_put_str` into single polymorphic helper
  - `lib/ad_butler_web/components/dashboard_components.ex:20`
  - `lib/ad_butler_web/live/campaigns_live.ex:195-201`

## Skipped

- Stale `PHX_SERVER` comment in runtime.exs (cosmetic only)
- Duplicate auth logic in `AuthLive` / `RequireAuthenticated` (no active bug; refactor deferred)
- `ad_account_id` UUID probing (tenant data confirmed safe; cosmetic allowlist deferred)
- `inspect(changeset.errors)` in logger (bounded risk; deferred)

## Deferred

(none)
