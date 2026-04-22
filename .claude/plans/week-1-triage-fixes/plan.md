# Plan: Week 1 Triage Fixes

**Source**: `.claude/plans/week-1-post-review-fixes/reviews/week-1-post-review-fixes-triage.md`  
**Findings**: 3 deploy blockers · 4 critical · 4 high security · 4 test gaps · 8 warnings (23 total)  
**Phases**: 5 · **Tasks**: 23

---

## Phase 1: Config & Deploy [5 tasks]

> Fix production config conflicts and environment hardening.
> Pure config changes — no behavior change in application code.
> Fastest phase; unblocks deploy.

- [x] [P1-T1] **B1** Enable DB SSL — ssl: true + ssl_opts with verify_peer in `config/runtime.exs` prod block: add `ssl: true, ssl_opts: [verify: :verify_peer, cacerts: :public_key.cacerts_get()]` to the `AdButler.Repo` config — `config/runtime.exs:57`

- [x] [P1-T2] **B2** Resolve conflicting `force_ssl` — removed from prod.exs, runtime.exs has exclude list: remove the `force_ssl` block from `config/prod.exs:14-21`; in `config/runtime.exs` replace the bare `force_ssl: [hsts: true, rewrite_on: [...]]` with the full config including the exclude list:
  ```elixir
  force_ssl: [
    hsts: true,
    rewrite_on: [:x_forwarded_proto],
    exclude: ["localhost", "127.0.0.1"]
  ]
  ```
  Note: the prod.exs comment says "force_ssl required at compile time" — this is a stale generator comment; Plug.SSL reads config at plug init time, not compile time, so runtime.exs works correctly.

- [x] [P1-T3] **B3** Add a comment — MIX_ENV=prod guard added near force_ssl block to `config/runtime.exs` near the `force_ssl` block documenting that production builds must use `MIX_ENV=prod` for the `secure: Mix.env() == :prod` cookie flag in `endpoint.ex` to be effective. No code change needed — just documentation guard.

- [x] [P1-T4] **W7** Change `PHX_HOST` — now raises if missing in `config/runtime.exs:77` from silent default to raise:
  ```elixir
  System.get_env("PHX_HOST") ||
    raise "environment variable PHX_HOST is missing."
  ```

- [x] [P1-T5] **W8** Move Vault cipher config — prod-only in runtime.exs, static dev key in dev.exs from `if config_env() != :test` to `if config_env() == :prod` in `config/runtime.exs`. Add a static dev key in `config/dev.exs`:
  ```elixir
  config :ad_butler, AdButler.Vault,
    ciphers: [
      default:
        {Cloak.Ciphers.AES.GCM,
         tag: "AES.GCM.V1",
         key: Base.decode64!("YWRfYnV0bGVyX2Rldl9rZXlfZm9yX2xvY2Fs")}
    ]
  ```
  (32-byte ASCII "ad_butler_dev_key_for_local")

---

## Phase 2: Worker & Controller Correctness [5 tasks]

> Fix silent failure modes, hardcoded values, and Oban config.
> All isolated to `token_refresh_worker.ex`, `auth_controller.ex`, and `config.exs`.

- [x] [P2-T1] **C1** Return `{:error, :schedule_failed}` — schedule_next_refresh now propagates errors from `perform/1` when `schedule_next_refresh/2` fails. Change the current result-discard at line 43 to:
  ```elixir
  {:ok, _} ->
    schedule_result = schedule_next_refresh(connection.id, expires_in)
    Logger.info("Token refresh success", meta_connection_id: id)
    case schedule_result do
      :ok -> :ok
      {:error, reason} ->
        Logger.error("Token re-schedule failed", meta_connection_id: id, reason: reason)
        {:error, :schedule_failed}
    end
  ```
  Also update `schedule_next_refresh/2` to return `:ok` on success (currently returns `{:ok, job}` from the case — normalize to `:ok`) — `token_refresh_worker.ex:38-54`

- [x] [P2-T2] **C4** Use `_ =` — revoke branch result discarded explicitly to explicitly discard inner `case` result in the revoke branch:
  ```elixir
  _ = case Accounts.update_meta_connection(connection, %{status: "revoked"}) do
  ```
  — `token_refresh_worker.ex:61`

- [x] [P2-T3] **C3** Read `expires_in` — exchange_code returns %{access_token, expires_in}, fallback to 60-day TTL with warning from the `Client.exchange_code/3` response. The exchange response currently only returns the token string `{:ok, token}` — update `exchange_code/3` to return `{:ok, %{access_token: token, expires_in: expires_in}}` (or `{:ok, token, expires_in}`). Then use it in `auth_controller.ex` callback to set `token_expires_at` from the real `expires_in` instead of `@meta_long_lived_token_ttl_seconds`, and pass `expires_in` to `schedule_refresh/2` for the initial job — `meta/client.ex:129`, `auth_controller.ex:43-53`
  > Note: If Meta's short-lived token exchange doesn't return `expires_in`, fallback to `@meta_long_lived_token_ttl_seconds` as a default and log a warning.

- [x] [P2-T4] **W4** Increase `timeout/1` to 60 seconds — test updated too — `token_refresh_worker.ex:28`:
  ```elixir
  def timeout(_job), do: :timer.seconds(60)
  ```

- [x] [P2-T5] **W5** Increase `max_attempts` to 5 — `token_refresh_worker.ex:3`:
  ```elixir
  use Oban.Worker,
    queue: :default,
    max_attempts: 5,
    ...
  ```

---

## Phase 3: Auth Security Hardening [5 tasks]

> Harden session salts, OAuth flow, login session management,
> and input validation. Touches `endpoint.ex`, `config.exs`,
> `auth_controller.ex`, `router.ex`, and `accounts/user.ex`.

- [x] [P3-T1] **H1** Move session salts — compile_env! in endpoint.ex, static values in config.exs/prod.exs to environment variables. Generate new values with `mix phx.gen.secret 32` for each:
  1. In `config/config.exs:23` change `live_view: [signing_salt: "oHp6OLvz"]` to read from env or a compile-time config
  2. In `lib/ad_butler_web/endpoint.ex:10-11` change `signing_salt` and `encryption_salt` to be loaded from `Application.fetch_env!` or set via `config/runtime.exs`
  3. Add `SESSION_SIGNING_SALT`, `SESSION_ENCRYPTION_SALT`, `LIVE_VIEW_SIGNING_SALT` to `runtime.exs` prod config
  4. Document in README/.env.example that these must be set
  > Note: existing values are already in git history and should be considered compromised. Rotation requires clearing active sessions.

- [x] [P3-T2] **H2** Account-link on second OAuth callback — skip session renewal if user_id matches; PlugAttack 10 req/min on /auth routes + rate limit:
  1. In `auth_controller.ex callback/2`: after `create_or_update_user` and `create_meta_connection`, if `get_session(conn, :user_id)` is already set and matches the returned user, skip re-setting session (it's a re-auth/link, not a new login)
  2. Add `PlugAttack` to `mix.exs` deps and configure a basic IP-based rate limit (10 req/min) on OAuth routes in `router.ex`:
     ```elixir
     plug PlugAttack.Plug, storage: {PlugAttack.Storage.Ets, :plug_attack_storage}
     ```
  3. Start `PlugAttack.Storage.Ets` in `application.ex`
  > If PlugAttack is already a dep, skip adding it.

- [x] [P3-T3] **H3** Fix redundant session operations — clear_session() removed on login. Replace in `auth_controller.ex:56-61`:
  ```elixir
  conn
  |> configure_session(renew: true)
  |> clear_session()
  |> put_session(:user_id, user.id)
  |> put_session(:live_socket_id, "users_sessions:#{user.id}")
  |> redirect(to: ~p"/dashboard")
  ```
  with:
  ```elixir
  conn
  |> configure_session(renew: true)
  |> put_session(:user_id, user.id)
  |> put_session(:live_socket_id, "users_sessions:#{user.id}")
  |> redirect(to: ~p"/dashboard")
  ```

- [x] [P3-T4] **H4** Tighten `meta_user_id` validation — ^[1-9]\d{0,19}$ + max 20 chars in `accounts/user.ex:24`:
  ```elixir
  |> validate_format(:meta_user_id, ~r/^[1-9]\d{0,19}$/)
  |> validate_length(:meta_user_id, max: 20)
  ```
  Update `test/support/factory.ex` meta_user_id sequences to start at `"100001"` (already digit-only; just verify `"100001"` matches `^[1-9]\d+$`). Update accounts_test hard-coded `"999001"` / `"999002"` / `"123456"` values to valid non-zero digit strings.

- [x] [P3-T5] **W1** Replace `if age <= 600 && Plug.Crypto.secure_compare(...)` with `cond` — done
  ```elixir
  defp verify_state(conn, state) do
    case get_session(conn, :oauth_state) do
      nil ->
        {:error, :invalid_state}

      {stored_state, issued_at} ->
        cond do
          System.system_time(:second) - issued_at > @state_ttl_seconds ->
            {:error, :invalid_state}
          not Plug.Crypto.secure_compare(stored_state, state) ->
            {:error, :invalid_state}
          true ->
            {:ok, delete_session(conn, :oauth_state)}
        end

      _ ->
        {:error, :invalid_state}
    end
  end
  ```
  — `auth_controller.ex:87`

---

## Phase 4: Auth Architecture & Oban Reliability [4 tasks]

> Extract business logic from controller into context, fix auth plug,
> and add Oban recovery cron. These are the larger refactors.

- [x] [P4-T1] **C2** Extract `require_authenticated_user` — AdButlerWeb.Plugs.RequireAuthenticated module plug, get_user/1 added to Accounts to a proper module plug `lib/ad_butler_web/plugs/require_authenticated.ex`:
  ```elixir
  defmodule AdButlerWeb.Plugs.RequireAuthenticated do
    import Plug.Conn
    import Phoenix.Controller, only: [redirect: 2]

    def init(opts), do: opts

    def call(conn, _opts) do
      case get_session(conn, :user_id) do
        nil ->
          conn
          |> configure_session(drop: true)
          |> redirect(to: "/")
          |> halt()

        user_id ->
          case AdButler.Accounts.get_user(user_id) do
            nil ->
              conn
              |> configure_session(drop: true)
              |> redirect(to: "/")
              |> halt()

            user ->
              assign(conn, :current_user, user)
          end
      end
    end
  end
  ```
  Add `get_user/1` (non-bang) to `AdButler.Accounts`. Update `router.ex` to use `plug AdButlerWeb.Plugs.RequireAuthenticated` instead of `plug :require_authenticated_user`. Remove private `require_authenticated_user/2` from router.

- [x] [P4-T2] **W2** Extract OAuth flow into `AdButler.Accounts.authenticate_via_meta/1` — controller now calls Accounts.authenticate_via_meta(code)
  ```elixir
  @spec authenticate_via_meta(String.t(), String.t(), String.t()) ::
    {:ok, %User{}, %MetaConnection{}} | {:error, term()}
  def authenticate_via_meta(code, app_id, app_secret) do
    with {:ok, %{access_token: token, expires_in: expires_in}} <-
           Meta.Client.exchange_code(code, app_id, app_secret),
         {:ok, user_info} <- Meta.Client.get_me(token),
         {:ok, user} <- create_or_update_user(user_info),
         {:ok, conn_record} <-
           create_meta_connection(user, %{
             meta_user_id: user_info[:meta_user_id],
             access_token: token,
             token_expires_at: DateTime.add(DateTime.utc_now(), expires_in, :second),
             scopes: ["ads_read", "ads_management", "email"]
           }) do
      {:ok, user, conn_record}
    end
  end
  ```
  Update `auth_controller.ex callback/2` to call `Accounts.authenticate_via_meta/3`.

- [x] [P4-T3] **W3** Move credentials into exchange_code/1 — 1-arg function reads from Application.fetch_env! inside `Meta.Client.exchange_code/3` (remove the params; read from `Application.fetch_env!` like `refresh_token/1`). Update `auth_controller.ex` to call `Client.exchange_code(code)` (1-arg) and remove the credential reads. Update `exchange_code/3` spec and implementation — `meta/client.ex:114`, `auth_controller.ex:39-40`

- [x] [P4-T4] **W6** Add `Oban.Plugins.Cron` config — every 6h cron + TokenRefreshSweepWorker and a `TokenRefreshSweepWorker` for orphaned connections. In `config/config.exs`, add to Oban plugins:
  ```elixir
  {Oban.Plugins.Cron,
   crontab: [
     {"0 */6 * * *", AdButler.Workers.TokenRefreshSweepWorker}
   ]}
  ```
  Create `lib/ad_butler/workers/token_refresh_sweep_worker.ex` that queries for `MetaConnection` rows with `status: "active"` and `token_expires_at < now() + 70 days` that have no pending `TokenRefreshWorker` job, and enqueues a `TokenRefreshWorker` for each.

---

## Phase 5: Tests [4 tasks]

> Cover all untested paths introduced or identified in this cycle.
> Phase 4 must complete first (module plug, context function).

- [x] [P5-T1] **T1** Add `describe "DELETE /auth/logout"` — authenticated + unauthenticated cases, PubSub broadcast asserted to `auth_controller_test.exs`:
  - Authenticated: session contains `:user_id` → assert session cleared, redirects to `/`, PubSub broadcast sent
  - Unauthenticated: no `:user_id` in session → assert redirects to `/` without error

- [x] [P5-T2] **T2** Add state TTL expiry test — expired_at 700s ago redirects with Invalid OAuth state to `auth_controller_test.exs`:
  ```elixir
  test "rejects expired state (> 600 seconds old)", %{conn: conn} do
    state = "test_state_expired"
    expired_at = System.system_time(:second) - 700
    conn = conn
      |> Plug.Test.init_test_session(%{})
      |> put_session(:oauth_state, {state, expired_at})
    conn = get(conn, ~p"/auth/meta/callback", %{"code" => "c", "state" => state})
    assert redirected_to(conn) == ~p"/"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Invalid OAuth state"
  end
  ```

- [x] [P5-T3] **T3** Add worker edge case tests — 60-day clamp, token_revoked cancel, generic error retry, schedule_refresh ref_time fix to `token_refresh_worker_test.exs`:
  1. **60-day clamp**: mock returns `expires_in: 71 * 86_400` → assert `assert_enqueued` job `scheduled_at` is within 60 days ± 5s
  2. **`:token_revoked` branch**: mock returns `{:error, :token_revoked}` → assert `{:cancel, "token_revoked"}` and connection status `"revoked"`
  3. **Generic `{:error, reason}`**: mock returns `{:error, :meta_server_error}` → assert `{:error, :meta_server_error}` (Oban retry)
  4. **Scheduling failure**: mock `Oban.insert` via test injection or verify `{:error, :schedule_failed}` is returned when `schedule_next_refresh` returns error

- [x] [P5-T4] **T4** Minor test hygiene fixes — unique_integer for meta_user_ids, get_meta_connection found-case, email:nil test, ref_time before call
  1. Replace hardcoded `meta_user_id: "999002"` in `accounts_test.exs:141` with `meta_user_id: "#{System.unique_integer([:positive])}"`
  2. Replace hardcoded `meta_user_id: "999001"` and `"123456"` similarly
  3. In `token_refresh_worker_test.exs` `schedule_refresh/2` test: capture `ref_time = DateTime.utc_now()` BEFORE calling `schedule_refresh/2`, then use in `assert_in_delta`
  4. Add found-case test to `accounts_test.exs` `describe "get_meta_connection/1"` block
  5. Add `create_or_update_user/1` test with `email: nil` → assert `{:error, changeset}` with `email: [_]` error

---

## Verification (per phase)

After each phase: `mix compile --warnings-as-errors && mix format --check-formatted`  
After Phase 3: `mix test test/ad_butler/ test/ad_butler_web/`  
After Phase 5: `mix test && mix credo --strict`

---

## Risks

1. **P2-T3 (`expires_in` from exchange)** — Meta's short-lived token exchange (`/oauth/access_token` with `fb_exchange_token`) returns `expires_in` in its response, but the long-lived token exchange may not. If `expires_in` is absent, fall back to `@meta_long_lived_token_ttl_seconds` (60 days) with a warning log. Don't raise.

2. **P3-T1 (salt rotation)** — Moving salts to env vars means all active sessions are invalidated at deploy time. Users will be logged out. Coordinate with a deploy announcement or choose a maintenance window.

3. **P3-T2 (PlugAttack)** — `PlugAttack` requires an ETS table started in the supervision tree. If the app is deployed on multiple nodes, the ETS store is per-node (no distributed rate limiting without a Redis backend). Acceptable for Week 1; document the limitation.

4. **P4-T2 (authenticate_via_meta/3)** — The context function wraps two HTTP calls (`exchange_code` + `get_me`). If either fails, the `with` chain returns early — same as current controller behavior. No transaction needed (DB writes are upserts; partial state is safe).

5. **P4-T4 (sweep worker)** — The sweep query scans `meta_connections` and cross-references `oban_jobs`. Keep the query efficient with an index on `(status, token_expires_at)`. Only run every 6 hours to avoid thundering herd.
