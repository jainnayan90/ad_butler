# Week 1 — Days 2–5: Accounts Context, OAuth, Meta Client, Token Refresh

**Feature:** Accounts context with Cloak encryption, Meta OAuth flow, Meta.Client with rate-limit ETS, and Oban TokenRefreshWorker.  
**Branch:** `day-02-to-05-auth-and-meta-client`  
**Sprint ref:** `docs/plan/sprint_plan/plan-adButlerV01Foundation.prompt.md` — Days 2–5 sections  
**Depth:** Standard

---

## Context

Day 1 delivered 10 migrations (all tables, indexes, constraints — verified in production). This sprint builds the first application layer:

- **Day 2** — `Accounts` context: `User` + `MetaConnection` schemas, Cloak token encryption, Oban + Mox + ExMachina deps  
- **Day 3** — Meta OAuth flow: `AuthController` request/callback, session management  
- **Day 4** — `Meta.Client`: Req-based Graph API client, `Meta.ClientBehaviour` for Mox, ETS rate-limit ledger  
- **Day 5** — Oban `TokenRefreshWorker`: scheduled token refresh, supervision tree wiring  

**Parallel opportunity:** Day 4 (Meta.Client) is independent of Day 3 (OAuth) — can be developed concurrently. Day 5 requires both.

**Critical constraints across all days:**
- All secrets (`CLOAK_KEY`, `META_APP_ID`, `META_APP_SECRET`, `META_OAUTH_CALLBACK_URL`) go in `runtime.exs` only — never compiled config
- **Contexts own Repo** — no direct `Repo` calls outside context modules; `TokenRefreshWorker` must call `Accounts.update_meta_connection/2`, not `Repo.update` directly
- TDD: write tests first, watch them fail, then implement

---

## Phase 1 — Dependencies + Accounts Context (Day 2)

- [x] [ecto] Add deps to `mix.exs`; run `mix deps.get`
  - `{:cloak_ecto, "~> 1.3"}`
  - `{:oban, "~> 2.18"}`
  - `{:mox, "~> 1.0", only: :test}`
  - `{:ex_machina, "~> 2.8", only: [:test, :dev]}`

- [x] [ecto] Create `lib/ad_butler/vault.ex`
  - `use Cloak.Vault, otp_app: :ad_butler`

- [x] [ecto] Create `lib/ad_butler/encrypted/binary.ex`
  - `use Cloak.Ecto.Binary, vault: AdButler.Vault`

- [x] [ecto] Add Cloak config to `config/runtime.exs` (NOT config.exs — secrets from environment)
  ```elixir
  config :ad_butler, AdButler.Vault,
    ciphers: [
      default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1",
        key: Base.decode64!(System.fetch_env!("CLOAK_KEY"))}
    ]
  ```

- [x] [otp] Add `AdButler.Vault` to supervision tree in `lib/ad_butler/application.ex`
  - Must appear **before** `AdButler.Repo` — Vault must start first so encrypted fields resolve at boot

- [x] [ecto] Create `lib/ad_butler/accounts/user.ex`
  - `@primary_key {:id, :binary_id, autogenerate: true}`
  - `@foreign_key_type :binary_id`
  - Fields: `email :string`, `meta_user_id :string`, `name :string`
  - `has_many :meta_connections, AdButler.Accounts.MetaConnection`
  - Changeset: `validate_required([:email])`, `validate_format(:email, ~r/@/)`, `unique_constraint(:email)`
  - `@spec changeset(t(), map()) :: Ecto.Changeset.t()`

- [x] [ecto] Create `lib/ad_butler/accounts/meta_connection.ex`
  - `@primary_key {:id, :binary_id, autogenerate: true}`
  - `@foreign_key_type :binary_id`
  - Fields: `meta_user_id :string`, `access_token AdButler.Encrypted.Binary`, `token_expires_at :utc_datetime_usec`, `scopes {:array, :string}`, `status :string, default: "active"`
  - `belongs_to :user, AdButler.Accounts.User`
  - Changeset: validates `[:user_id, :meta_user_id, :access_token, :token_expires_at, :scopes]` required; `validate_inclusion(:status, ["active", "expired", "revoked"])`
  - `unique_constraint([:user_id, :meta_user_id])`

- [x] [ecto] Create `lib/ad_butler/accounts.ex` context
  - `get_user!/1` — `Repo.get!(User, id)`
  - `get_user_by_email/1` — `Repo.get_by(User, email: email)`
  - `create_or_update_user/1` — atomic upsert: `Repo.insert(changeset, on_conflict: {:replace, [:name, :meta_user_id, :updated_at]}, conflict_target: :email)` (avoids TOCTOU race of get-then-insert)
  - `get_meta_connection!/1` — `Repo.get!(MetaConnection, id)`
  - `create_meta_connection/2` — `%MetaConnection{} |> MetaConnection.changeset(attrs) |> Repo.insert()`
  - `update_meta_connection/2` — `connection |> MetaConnection.changeset(attrs) |> Repo.update()` (required by Day 5 worker)
  - `list_meta_connections/1` — filters `user_id == user.id AND status == "active"`
  - `@spec` on all public functions

- [x] [testing] Create `test/support/factory.ex`
  - `use ExMachina.Ecto, repo: AdButler.Repo`
  - `user_factory` — valid email, name
  - `meta_connection_factory` — with `user_id`, plaintext `access_token`, future `token_expires_at`, scopes list

- [x] [testing] Write `test/ad_butler/accounts_test.exs` (TDD — write first, watch fail)
  - `create_meta_connection/2`: raw DB bytes for `access_token` ≠ plaintext; loading via `Repo.get!` decrypts correctly
  - `create_or_update_user/1`: two calls with same email produce one row (no duplicate); second call updates name
  - `list_meta_connections/1`: returns only `status == "active"` connections for the given user, not other users' connections
  - `update_meta_connection/2`: token and expiry updated in DB

---

## Phase 2 — Meta OAuth Flow (Day 3)

> Depends on Phase 1 (`Accounts` context must exist).

- [x] [otp] Add Meta OAuth config to `config/runtime.exs`
  ```elixir
  config :ad_butler,
    meta_app_id: System.fetch_env!("META_APP_ID"),
    meta_app_secret: System.fetch_env!("META_APP_SECRET"),
    meta_oauth_callback_url: System.fetch_env!("META_OAUTH_CALLBACK_URL")
  ```

- [x] [otp] Add OAuth routes to `lib/ad_butler_web/router.ex` (inside `:browser` pipeline scope)
  ```elixir
  scope "/auth", AdButlerWeb do
    pipe_through :browser
    get "/meta", AuthController, :request
    get "/meta/callback", AuthController, :callback
  end
  ```

- [x] [otp] Create `lib/ad_butler_web/controllers/auth_controller.ex`
  - `request/2`: generates CSRF state via `:crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)`, stores in session, builds OAuth URL, redirects external to `facebook.com/dialog/oauth`
  - `callback/2` (code + state params): `with` chain:
    1. `verify_state(conn, state)` — compare session vs param
    2. `exchange_code_for_token(code)` — `Req.post` to `https://graph.facebook.com/v19.0/oauth/access_token`
    3. `fetch_user_info(access_token)` — `Req.get` to `https://graph.facebook.com/v19.0/me?fields=id,name,email`
    4. `Accounts.create_or_update_user/1`
    5. `Accounts.create_meta_connection/2`
    - On success: `put_session(:user_id, user.id)` → redirect to `~p"/dashboard"`
    - On `{:error, :invalid_state}`: flash error, redirect to `~p"/"`
    - On `{:error, reason}`: flash error, redirect to `~p"/"`
  - `callback/2` (error params — OAuth denied): flash `"OAuth error: #{description}"`, redirect to `~p"/"`
  - All secrets via `Application.fetch_env!(:ad_butler, :meta_*)` — no hardcoded values
  - Structured logging: log `[user_id: user.id, meta_user_id: meta_user_id]` on OAuth success

- [x] [testing] Write `test/ad_butler_web/controllers/auth_controller_test.exs` (TDD — write first)
  - `GET /auth/meta`: response redirects to `"facebook.com"`, session has `:oauth_state`
  - `GET /auth/meta/callback` (valid): set session state via `put_session/3`; stub Req with `Req.Test.stub/2` (Req 0.5 already in mix.exs) to return fake token response + user info; verify user row created in DB, session has `:user_id`, redirected to `/dashboard`
  - `GET /auth/meta/callback` (state mismatch): no session state set; verify redirect to `"/"` with error flash
  - `GET /auth/meta/callback` (OAuth error params): `%{"error" => "access_denied", "error_description" => "..."}` → redirect to `"/"` with error flash

---

## Phase 3 — Meta.Client + Rate-Limit Ledger (Day 4)

> Independent of Phase 2 — can be developed in parallel with Day 3.

- [x] [otp] Create `lib/ad_butler/meta/client_behaviour.ex`
  ```elixir
  @callback list_ad_accounts(String.t()) :: {:ok, list(map())} | {:error, term()}
  @callback list_campaigns(String.t(), String.t(), keyword()) :: {:ok, list(map())} | {:error, term()}
  @callback list_ad_sets(String.t(), String.t(), keyword()) :: {:ok, list(map())} | {:error, term()}
  @callback list_ads(String.t(), String.t(), keyword()) :: {:ok, list(map())} | {:error, term()}
  @callback get_creative(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  @callback batch_request(String.t(), list(map())) :: {:ok, list(map())} | {:error, term()}
  @callback get_rate_limit_usage(String.t()) :: float()
  @callback refresh_token(String.t()) :: {:ok, map()} | {:error, term()}
  ```

- [x] [otp] Create `lib/ad_butler/meta/rate_limit_store.ex` — ETS-owning GenServer
  - `use GenServer`; `start_link/0`; `init/1` creates `:meta_rate_limits` ETS table as `[:named_table, :public, :set, read_concurrency: true]` owned by this process
  - Owning via GenServer prevents table loss if `Meta.Client` crashes (table survives as long as this GenServer is up)

- [x] [otp] Add `AdButler.Meta.RateLimitStore` to supervision tree in `application.ex` (before Endpoint)

- [x] [otp] Create `lib/ad_butler/meta/client.ex`
  - `@behaviour AdButler.Meta.ClientBehaviour`
  - `@graph_api_base "https://graph.facebook.com/v19.0"`
  - `@rate_limit_table :meta_rate_limits`
  - All `@impl true` callbacks: `list_ad_accounts/1`, `list_campaigns/3`, `list_ad_sets/3`, `list_ads/3`, `get_creative/2`, `batch_request/2`, `get_rate_limit_usage/1`, `refresh_token/1`
  - Private `make_request/3` — `Req.request([method: method, url: url] ++ opts)`, parses `{"data" => list}` vs plain body
  - `handle_error/1` dispatches on status: `400 → {:error, {:bad_request, msg}}`, `401 → {:error, :unauthorized}`, `403 → {:error, :forbidden}`, `429 → {:error, :rate_limit_exceeded}`, `5xx → {:error, :meta_server_error}`, timeout → `{:error, :timeout}`
  - `parse_rate_limit_header/2`: reads `"x-business-use-case-usage"` header, decodes JSON, writes `{ad_account_id, {call_count, cpu_time, total_time, DateTime.utc_now()}}` to ETS
  - `@spec` on all public functions

- [x] [testing] Create `test/support/mocks.ex`
  - `Mox.defmock(AdButler.Meta.ClientMock, for: AdButler.Meta.ClientBehaviour)`

- [x] [testing] Configure test env to use mock in `config/test.exs`
  - `config :ad_butler, :meta_client, AdButler.Meta.ClientMock`

- [x] [testing] Write `test/ad_butler/meta/client_test.exs` (TDD — write first)
  - `list_ad_accounts/1`: `Req.Test.stub` returns `%{status: 200, body: %{"data" => [...]}}`, ETS entry written, returns `{:ok, [...]}`
  - `get_rate_limit_usage/1`: returns `0.0` when no ETS entry; returns float after a stubbed request that includes rate-limit header
  - `batch_request/2`: encodes requests as JSON, POSTs to root path, returns decoded list
  - Error cases: 401 → `{:error, :unauthorized}`, 429 → `{:error, :rate_limit_exceeded}`, 500 → `{:error, :meta_server_error}`, timeout → `{:error, :timeout}`

---

## Phase 4 — Token Refresh Job + Oban Setup (Day 5)

> Depends on Phase 1 (`Accounts.update_meta_connection/2`) and Phase 3 (`Meta.ClientBehaviour`/mock).

- [x] [oban] Add Oban config to `config/config.exs`
  ```elixir
  config :ad_butler, Oban,
    repo: AdButler.Repo,
    queues: [default: 10, sync: 20, analytics: 5]
  ```

- [x] [oban] Add Oban test config to `config/test.exs`
  ```elixir
  config :ad_butler, Oban, testing: :inline
  ```
  (Jobs execute synchronously in tests — no async job polling needed)

- [x] [otp] Add `{Oban, Application.fetch_env!(:ad_butler, Oban)}` to supervision tree in `application.ex` (after Repo, before Endpoint)

- [x] [oban] Create `lib/ad_butler/workers/token_refresh_worker.ex`
  - `use Oban.Worker, queue: :default, max_attempts: 3`
  - `perform/1` args: `%{"meta_connection_id" => id}`
    1. `Accounts.get_meta_connection!(id)`
    2. `meta_client().refresh_token(connection.access_token)` (reads `:meta_client` config for testability)
    3. On `{:ok, %{"access_token" => token, "expires_in" => expires_in}}`:
       - `Accounts.update_meta_connection(connection, %{access_token: token, token_expires_at: expiry})` — **NOT `Repo.update` directly**
       - `schedule_next_refresh(connection.id, expires_in)`
       - returns `:ok`
    4. On `{:error, reason}`: returns `{:error, reason}` (Oban retries automatically up to `max_attempts`)
  - Public `schedule_refresh/2` — `%{meta_connection_id: id} |> new(schedule_in: {days, :days}) |> Oban.insert()`
  - Private `schedule_next_refresh/2` — `days = max(div(expires_in_seconds, 86400) - 10, 1)`; calls `schedule_refresh/2`
  - Private `meta_client/0` — `Application.get_env(:ad_butler, :meta_client, AdButler.Meta.Client)`
  - Structured logging: log `[meta_connection_id: id]` on success and on error

- [x] [testing] Write `test/ad_butler/workers/token_refresh_worker_test.exs` (TDD — write first)
  - `use Oban.Testing, repo: AdButler.Repo`
  - `perform/1` success: `ClientMock.refresh_token/1` returns `{:ok, %{...}}`; verify token updated in DB via `Accounts.get_meta_connection!/1`; verify next job enqueued in `:default` queue
  - `perform/1` failure: `ClientMock.refresh_token/1` returns `{:error, :rate_limit_exceeded}`; verify connection unchanged in DB; job returns `{:error, :rate_limit_exceeded}`
  - `schedule_refresh/2`: job lands in `oban_jobs` with correct queue and `scheduled_at` timestamp
  - Idempotency: `perform/1` twice with same connection — second call sees updated token, no crash

---

## Phase 5 — Verification

- [x] `mix compile --warnings-as-errors` — zero warnings
- [x] `mix format --check-formatted` — no changes
- [x] `mix credo --strict lib/ad_butler/accounts/ lib/ad_butler/meta/ lib/ad_butler/workers/ lib/ad_butler_web/controllers/auth_controller.ex` — no violations
- [x] `mix test --cover` — 100% coverage on all new modules
- [x] Manual encryption smoke: `iex -S mix` → insert MetaConnection → compare raw `Repo.one(from mc in MetaConnection, select: mc.access_token)` bytes vs `connection.access_token` plaintext
- [x] Manual Oban smoke: `Oban.insert(TokenRefreshWorker.new(%{meta_connection_id: id}))` → verify job row in `oban_jobs`

---

## Risks

1. **Cloak Vault startup order** — `AdButler.Vault` must be listed before `AdButler.Repo` in `application.ex` children. If reversed, a boot crash occurs when Ecto reads any encrypted field on startup (e.g., if seeds run). Mitigation: ordering enforced in supervision tree task.

2. **ETS table ownership** — The sprint plan calls `Meta.Client.init()` as a bare function in `application.ex`, tying the ETS table to the Application process. Instead, use a dedicated `RateLimitStore` GenServer so the table is supervised and survives client restarts. If the table is lost mid-request, `get_rate_limit_usage/1` returns `0.0` (acceptable), but inserts crash — making ownership explicit prevents silent failures.

3. **`create_or_update_user` TOCTOU race** — The sprint plan uses `get_user_by_email` then `insert`/`update`. Under concurrent OAuth callbacks (two tabs), both processes find nil and both attempt to insert, causing a unique constraint error. Mitigation: use `Repo.insert/2` with `on_conflict: {:replace, [...]}` for an atomic upsert.

4. **`Req.Test.stub` vs Bypass for controller tests** — `AuthController` makes two Req calls (token exchange + user info fetch). Since Req ≥ 0.5 is already in `mix.exs`, use `Req.Test.stub/2` to intercept calls without a real HTTP server. No need for `bypass` or `mock_server` dependencies.

5. **`Oban, testing: :inline` in test.exs** — Without this, `perform/1` in tests requires manual job execution via `Oban.Testing.perform_job/2`. Setting `:inline` is simpler for unit tests, but disables the Oban queue — ensure no test relies on queue behaviour (ordering, unique jobs) which `:manual` mode handles better if needed.

6. **`update_meta_connection/2` omitted from sprint plan** — The sprint plan's `TokenRefreshWorker` calls `Repo.update` directly, violating "Contexts own Repo". This plan adds `update_meta_connection/2` to `Accounts` in Phase 1 and requires the worker to call it.
