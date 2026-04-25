# Week 3: LiveView UI & Deployment (Days 11–15)

**Source:** `docs/plan/sprint_plan/plan-adButlerV01Foundation.prompt.md` §Week 3
**Branch:** create from `module_documentation_and_audit_fixes`

## Key Decisions

- **Auth**: `live_session` with `AdButlerWeb.AuthLive.on_mount(:require_authenticated, ...)` hook; `RequireAuthenticated` plug stays as HTTP-layer defense-in-depth. The hook reads `session["user_id"]`, calls `Accounts.get_user/1`, assigns `current_user` with plain `assign/3` (not `assign_new`).
- **Route**: `PageController.dashboard/2` and `page_html/dashboard.html.heex` are replaced by `live "/dashboard", DashboardLive`.
- **Logout**: `<.link method="delete" href={~p"/auth/logout"}>` in LiveView templates — delegates to `AuthController.logout/2` which broadcasts disconnect and drops session.
- **Streams**: Use `stream/3` for ad accounts and campaigns. Load campaigns in `handle_params/3`, not `mount/3`, so filters from URL params are respected.
- **Components**: One-off markup as private `defp` in the LiveView module. Shared components (status badge, stat card) in a new `AdButlerWeb.DashboardComponents`. Use existing `<.table>` from `CoreComponents`.
- **`llm_usage` migration**: Already exists at `20260420155228_create_llm_usage.exs`; only schema module + telemetry handler needed.
- **LLM handler**: Named module `AdButler.LLM.UsageHandler`, wired in `Application.start/2`. `on_conflict: :nothing` keyed on `request_id` for idempotency.
- **Fly.io**: `fly.toml` already exists and correct. Need `fly.staging.toml`, RabbitMQ (CloudAMQP), and `--build-secret` for compile-time salts.

---

## Phase 1 — LiveView Auth Infrastructure (Day 11)

- [x] Create `lib/ad_butler_web/auth_live.ex` — `on_mount(:require_authenticated, ...)` reads `session["user_id"]`, looks up user via `Accounts.get_user/1`, assigns `current_user`; halts with redirect to `/` if nil or not found

- [x] Update `lib/ad_butler_web/router.ex`:
  - Replace `get "/dashboard", PageController, :dashboard` with a `live_session :authenticated` block containing `live "/dashboard", DashboardLive` and `live "/campaigns", CampaignsLive`
  - Keep `pipe_through [:browser, :authenticated]` — plug stays for defense-in-depth
  - `live_session :authenticated, on_mount: {AdButlerWeb.AuthLive, :require_authenticated}`

- [x] Delete `lib/ad_butler_web/controllers/page_html/dashboard.html.heex` (replaced by LiveView)
- [x] Remove `dashboard/2` action from `lib/ad_butler_web/controllers/page_controller.ex`

---

## Phase 2 — DashboardLive (Day 11)

- [x] [liveview] Create `lib/ad_butler_web/live/dashboard_live.ex`:
  - `mount/3`: stream ad accounts (`stream(socket, :ad_accounts, Ads.list_ad_accounts(current_user))`), assign `ad_account_count`
  - `render/1`: stat card (count), ad account list using `<.table>` or stream for loop; empty state with "Connect Meta Account" link; logout via `<.link method="delete" href={~p"/auth/logout"}>`
  - Mobile-first Tailwind layout (no DaisyUI)

- [x] Create `lib/ad_butler_web/components/dashboard_components.ex` — `stat_card/1` function component (reusable across Dashboard + Campaigns)

- [x] Create `test/ad_butler_web/live/dashboard_live_test.exs`:
  - Setup: `insert(:user)` + `insert(:meta_connection)` + `insert(:ad_account, meta_connection: mc)`
  - Test: mounts, shows user email
  - Test: shows ad account count (1 account)
  - Test: empty state renders "Connect Meta Account" link when no accounts
  - Test: unauthenticated request redirects to `/`
  - Test: logout link renders with `method="delete"` and href `/auth/logout`

---

## Phase 3 — CampaignsLive (Day 12)

- [x] [liveview] Create `lib/ad_butler_web/live/campaigns_live.ex`:
  - `mount/3`: stream campaigns with empty list (`stream(socket, :campaigns, [])`), stream ad accounts for filter dropdown, assign `selected_ad_account: nil, selected_status: nil`
  - `handle_params/3`: extract `:ad_account_id` and `:status` from params, build filter opts, call `Ads.list_campaigns(current_user, opts)`, replace stream (`stream(socket, :campaigns, campaigns, reset: true)`)
  - `handle_event("filter", ...)`: push patch with updated params (`push_patch/2`) — keeps URL in sync with filter state
  - Mobile-first responsive table; status badge showing ACTIVE (green) / PAUSED (gray) / DELETED (red)

- [x] Create `test/ad_butler_web/live/campaigns_live_test.exs`:
  - Test: campaigns display correctly for authenticated user
  - Test: filter by ad_account_id — only that account's campaigns shown
  - Test: filter by status — only ACTIVE shown when status=ACTIVE
  - Test: tenant isolation — user A cannot see user B's campaigns
  - Test: unauthenticated request redirects to `/`

---

## Phase 4 — Error Handling Polish (Day 13)

- [x] Add disconnected/reconnecting UI: in root layout or LiveView template, add `phx-disconnected` and `phx-connected` classes with a dismissable banner ("Reconnecting…")

- [x] Ensure empty states are graceful in both LiveViews:
  - DashboardLive: empty state already covered in Phase 2
  - CampaignsLive: empty state message when filter returns 0 campaigns ("No campaigns match your filters.")

- [x] Add `handle_info(:reconnected, ...)` or use `Phoenix.LiveView.on_mount/1` for reload-on-reconnect: on reconnect, reset streams with fresh data from DB (prevents stale UI after long disconnect)

- [x] Test: simulate empty filter result — CampaignsLive renders "No campaigns" message without crashing

---

## Phase 5 — LLM Usage Telemetry (Day 14)

- [x] [ecto] Run `mix ecto.migrate` — the `llm_usage` migration at `20260420155228` already exists and creates the table — added two extra migrations: alter metadata to :binary (20260425000000), add non-partial unique index on request_id (20260425000002)

- [x] [ecto] Create `lib/ad_butler/llm/usage.ex` — Ecto schema module:
  - `schema "llm_usage"` with `:binary_id` PK, no `updated_at`
  - Plain fields: `user_id`, `conversation_id`, `turn_id`, `purpose`, `provider`, `model`, `input_tokens`, `output_tokens`, `cached_tokens`, `cost_cents_input`, `cost_cents_output`, `cost_cents_total`, `latency_ms`, `status`, `request_id`
  - Encrypted field: `metadata` as `AdButler.Encrypted.Binary` (serialise map to JSON before storing)
  - `belongs_to :user, AdButler.Accounts.User, type: :binary_id`
  - `changeset/2` for insert validation; no update changeset needed (append-only)

- [x] Create `lib/ad_butler/llm/usage_handler.ex` — telemetry handler module:
  - `attach/0` function: calls `:telemetry.detach("llm-usage-logger")` then `attach/4` for `[:llm, :request, :stop]` and `[:llm, :request, :exception]`
  - `handle_event/4`: extracts `user_id`, `model`, token counts, latency from measurements/metadata; writes via `Repo.insert(changeset, on_conflict: :nothing, conflict_target: [:request_id])`
  - No inline anonymous functions — named module function only (per project pattern in `application.ex`)

- [x] Call `AdButler.LLM.UsageHandler.attach()` in `AdButler.Application.start/2`, following the existing `handle_oban_event` pattern

- [x] Create `test/ad_butler/llm/usage_handler_test.exs`:
  - Test: telemetry event `[:llm, :request, :stop]` writes a `llm_usage` row with correct token counts
  - Test: duplicate event (same `request_id`) does not write a second row (`on_conflict: :nothing`)
  - Test: `metadata` field is stored encrypted (read raw from DB, assert it is not plaintext JSON)

---

## Phase 6 — Fly.io Staging Deploy (Day 15)

- [x] Create `fly.staging.toml` — copy from `fly.toml`, change `app` name to `ad-butler-staging`, lower `min_machines_running` to 0

- [x] Harden `runtime.exs`: move `server: true` inside `if config_env() == :prod` block unconditionally (currently gated on `PHX_SERVER` env var — fragile)

- [ ] Provision CloudAMQP staging instance (free tier); note connection URL for `RABBITMQ_URL` secret

- [ ] Set Fly secrets on staging app:
  ```
  fly secrets set -a ad-butler-staging \
    DATABASE_URL=... \
    SECRET_KEY_BASE=... \
    RABBITMQ_URL=... \
    CLOAK_KEY=... \
    META_APP_ID=... \
    META_APP_SECRET=... \
    META_OAUTH_CALLBACK_URL=https://ad-butler-staging.fly.dev/auth/meta/callback \
    LIVE_VIEW_SIGNING_SALT=...
  ```

- [ ] Provision Fly Postgres for staging:
  ```
  fly postgres create --name ad-butler-staging-db
  fly postgres attach ad-butler-staging-db -a ad-butler-staging
  ```

- [ ] Deploy with build secrets:
  ```
  fly deploy --config fly.staging.toml \
    --build-secret SESSION_SIGNING_SALT=... \
    --build-secret SESSION_ENCRYPTION_SALT=...
  ```

- [ ] Smoke test staging:
  - `curl https://ad-butler-staging.fly.dev/health/liveness` → `{"status":"ok"}`
  - `curl https://ad-butler-staging.fly.dev/health/readiness` → `{"status":"ok"}`
  - Complete OAuth flow end-to-end in browser
  - Verify sync pipeline enqueues jobs (check Oban dashboard)

- [ ] Submit Meta App Review for production `app_id` (manual step — link Meta developer console)

---

## Phase 7 — Verification

- [x] `mix compile --warnings-as-errors`
- [x] `mix format --check-formatted`
- [x] `mix credo --strict`
- [x] `mix test` — 195 tests, 0 failures (was 183, +12 new)
- [x] `mix test test/ad_butler_web/live/` — 12 LiveView tests pass
- [x] `mix test test/ad_butler/llm/` — 3 LLM telemetry tests pass

---

## Risks

1. **`assign_new` vs `assign`**: The `on_mount` hook MUST use plain `assign/3`, not `assign_new/3`. `assign_new` skips the callback if the key already exists on the socket — a reconnected socket could carry a stale user struct and bypass auth. (Iron law: authorize on every mount.)

2. **Session salts as build-time secrets**: `SESSION_SIGNING_SALT` and `SESSION_ENCRYPTION_SALT` are compiled into the release via `Application.compile_env!/2` in `prod.exs`. They are NOT Fly runtime secrets — they must be passed as `--build-secret` flags during `fly deploy`. If omitted, the build will fail at compile time (not at runtime). Document this in `fly.staging.toml` comments.

3. **RabbitMQ at staging boot**: `Application.start/2` calls `setup_rabbitmq_topology` via a supervised Task. If `RABBITMQ_URL` is unset or CloudAMQP is unreachable, the node halts after 3 retries (by design — fail-fast). Ensure CloudAMQP is provisioned and the URL is set before the first `fly deploy`.

4. **LLM telemetry handler: no LLM integration yet**: Day 14 builds the plumbing but the `[:llm, :request, :stop]` event is only emitted when LLM calls are made (future feature). The handler is attached but will never fire until an LLM client is integrated. Tests must emit the telemetry event manually using `:telemetry.execute/3`.
