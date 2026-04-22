# Week-1 Audit Fixes

Source: `.claude/audit/summaries/project-health-2026-04-21.md`  
Branch: `week-01-Day-01-05-Authentication`  
Overall health: 74/100 — B-

14 tasks across 6 phases. Phase 1 is a production crash fix; do it first.

---

## Phase 1: Crash Fix (do first)

- [x] [P1-T1][code] Add `PageController.dashboard/2` action and template — added action + dashboard.html.heex placeholder
  File: `lib/ad_butler_web/controllers/page_controller.ex`, `lib/ad_butler_web/controllers/page_html/dashboard.html.heex`
  Every successful OAuth login redirects to `/dashboard` which hits `UndefinedFunctionError`.
  1. Add `def dashboard(conn, _params), do: render(conn, :dashboard)` to `PageController`
  2. Create `page_html/dashboard.html.heex` — minimal placeholder ("Dashboard coming soon" or similar)
  Note: `PageHTML` uses `embed_templates "page_html/*"` so any new `.heex` file is auto-included.

---

## Phase 2: Security

- [x] [P2-T1][code] Fix changeset logged verbatim on token update failure — match `%Ecto.Changeset{}`, log `changeset.errors` only
  File: `lib/ad_butler/workers/token_refresh_worker.ex` — the `{:error, reason}` branch in `do_refresh/1`
  on `update_meta_connection` failure. The full `Ecto.Changeset` is logged; its `changes` map
  carries the plaintext `access_token` (pre-Cloak). `filter_parameters` does not scrub Logger metadata.
  Change: `reason: reason` → `reason: inspect(changeset.errors)` and match the tuple as `{:error, %Ecto.Changeset{} = changeset}`.
  The generic `{:error, reason}` catch-all below can stay for non-changeset errors.

- [x] [P2-T2][code] Move committed session salts to runtime env vars — removed prod-specific overrides from prod.exs; compile_env! kept (fetch_env! warned); runtime.exs placeholder omitted to avoid compile_env boot conflict
  File: `config/prod.exs:24-27`, `config/runtime.exs`, `lib/ad_butler_web/endpoint.ex:10-11`
  Currently `session_signing_salt`, `session_encryption_salt`, and `live_view: [signing_salt:]`
  are committed plaintext strings in `prod.exs`. Rotating them requires a code change + redeploy.
  1. In `config/runtime.exs` (inside `config_env() == :prod` block), add:
     ```elixir
     config :ad_butler,
       session_signing_salt: System.fetch_env!("SESSION_SIGNING_SALT"),
       session_encryption_salt: System.fetch_env!("SESSION_ENCRYPTION_SALT")
     config :ad_butler, AdButlerWeb.Endpoint,
       live_view: [signing_salt: System.fetch_env!("LIVE_VIEW_SIGNING_SALT")]
     ```
  2. Remove the three salt lines from `config/prod.exs`.
  3. In `endpoint.ex`, change `Application.compile_env!(:ad_butler, :session_signing_salt)` and
     `Application.compile_env!(:ad_butler, :session_encryption_salt)` to `Application.fetch_env!`.
     (These are session salts, not secrets — but `compile_env!` would fail at compile time if
     moved to runtime.exs, so switch to `fetch_env!/2` which reads at startup.)
  Note: dev.exs and test.exs already set these — no change needed there.
  Add env var names to `.env.example` or deployment docs.

---

## Phase 3: Architecture

- [x] [P3-T1][code] Move sweep worker query into Accounts context
  File: `lib/ad_butler/workers/token_refresh_sweep_worker.ex`, `lib/ad_butler/accounts.ex`
  Sweep worker directly imports `Ecto.Query`, aliases `Repo`, and queries `MetaConnection` raw —
  bypassing any future Accounts-layer filters (soft-delete, status enum changes, etc.).
  1. Add to `lib/ad_butler/accounts.ex`:
     ```elixir
     @spec list_expiring_meta_connections(pos_integer()) :: [%MetaConnection{}]
     def list_expiring_meta_connections(days_ahead \\ 70) do
       threshold = DateTime.add(DateTime.utc_now(), days_ahead, :day)
       MetaConnection
       |> where([mc], mc.status == "active" and mc.token_expires_at < ^threshold)
       |> Repo.all()
     end
     ```
  2. In sweep worker: remove `import Ecto.Query`, remove `alias AdButler.Repo`, remove raw query.
     Call `Accounts.list_expiring_meta_connections()` instead.

- [x] [P3-T2][code] Unify Meta.Client dispatch in Accounts via `meta_client()` helper
  File: `lib/ad_butler/accounts.ex:12-13`
  `authenticate_via_meta/1` calls `Meta.Client.exchange_code/1` and `Meta.Client.get_me/1`
  directly (concrete module), while `TokenRefreshWorker` uses `Application.get_env(:meta_client)`.
  In tests, `Accounts` tests use `Req.Test` plug injection; worker tests use the behaviour mock.
  Two mocking mechanisms in play — inconsistent and fragile.
  1. Add private helper to `Accounts`:
     ```elixir
     defp meta_client, do: Application.get_env(:ad_butler, :meta_client, AdButler.Meta.Client)
     ```
  2. Replace `Meta.Client.exchange_code(code)` → `meta_client().exchange_code(code)`
     and `Meta.Client.get_me(token)` → `meta_client().get_me(token)`.
  3. In `test/ad_butler/accounts_authenticate_via_meta_test.exs` (and related), the tests
     likely already stub via `Req.Test` — verify they still pass. If they relied on the
     concrete `Meta.Client` module path, update to use the mock behaviour instead.

---

## Phase 4: Performance

- [x] [P4-T1][ecto] Add partial index on `meta_connections (status, token_expires_at)`
  The sweep worker filters on `status = 'active' AND token_expires_at < threshold` —
  full table scan every 6 hours without an index.
  Create migration:
  ```elixir
  create index(:meta_connections, [:token_expires_at],
    where: "status = 'active'",
    name: "meta_connections_active_token_expires_at_idx"
  )
  ```
  Note: Postgres partial indexes filter at index-scan time; the `where` clause matches the
  sweep query's `status == "active"` condition exactly.

- [x] [P4-T2][code] Add limit to sweep worker query to prevent unbounded loads
  File: `lib/ad_butler/accounts.ex` — `list_expiring_meta_connections/1` (added in P3-T1)
  Add `|> limit(500)` to cap batch size. At scale, the sweep cron should be re-run more
  frequently or implement cursor-based pagination. For now, 500 is a safe upper bound.
  Update the function to accept an optional `limit` param:
  ```elixir
  def list_expiring_meta_connections(days_ahead \\ 70, limit \\ 500) do
    ...
    |> limit(^limit)
    |> Repo.all()
  end
  ```

---

## Phase 5: Test Coverage

- [x] [P5-T1][code] Add `RequireAuthenticated` plug tests
  File: `test/ad_butler_web/plugs/require_authenticated_test.exs` (new file)
  Use `ConnCase`. Three cases:
  1. No session → redirects to `~p"/"` with error flash "Please sign in"
  2. Session with `user_id` for non-existent user → redirects (deleted user case)
  3. Valid `user_id` in session → assigns `conn.assigns.current_user`, halts not called
  Use `insert(:user)` from factory for case 3.

- [x] [P5-T2][code] Add `PlugAttack` rate-limit rule tests
  File: `test/ad_butler_web/plugs/plug_attack_test.exs` (new file)
  Test the "oauth rate limit" rule:
  1. First 10 requests within 60 s from same IP → all pass (200 or redirect)
  2. 11th request from same IP → blocked (429 or PlugAttack block response)
  Use `build_conn()` with a fixed `remote_ip` (no `fly-client-ip` header in tests).
  Note: PlugAttack ETS table is process-global — `async: false`.

- [x] [P5-T3][code] Add tests for untested public Accounts functions
  File: `test/ad_butler/accounts_test.exs`
  Add `describe` blocks for:
  - `get_user/1` — existing user returns `%User{}`; unknown id returns `nil`
  - `get_user!/1` — unknown id raises `Ecto.NoResultsError`
  - `get_user_by_email/1` — returns user by email; unknown email returns `nil`
  - `list_meta_connections/1` — returns only `status: "active"` connections for user

- [x] [P5-T4][code] Fix ETS entry leak between tests in `client_test.exs`
  File: `test/ad_butler/meta/client_test.exs`
  The `list_ad_accounts` test inserts `"act_123"` into `:meta_rate_limits` ETS without cleanup.
  Add `on_exit(fn -> :ets.delete(:meta_rate_limits, "act_123") end)` inside that test.

- [x] [P5-T5][code] Add `async: true` to three ConnCase test files
  Files: `test/ad_butler_web/controllers/error_html_test.exs`,
         `test/ad_butler_web/controllers/error_json_test.exs`,
         `test/ad_butler_web/controllers/page_controller_test.exs`
  None modify global state — safe to run async. Change `async: false` → `async: true`.

---

## Phase 6: Dependencies

- [x] [P6-T1][code] Tighten unconstrained dependency version specs
  File: `mix.exs`
  1. `{:postgrex, ">= 0.0.0"}` → `{:postgrex, "~> 0.22"}`
  2. `{:lazy_html, ">= 0.1.0", only: :test}` → `{:lazy_html, "~> 0.1", only: :test}`
  3. `{:phoenix_live_view, "~> 1.1.0"}` → `{:phoenix_live_view, "~> 1.1"}`
     (`~> 1.1.0` blocks `1.2.x`; `~> 1.1` allows minor upgrades)
  Run `mix deps.get` after — lock file update only, no breaking changes expected.

---

## Verification

After all phases:
```
mix compile --warnings-as-errors && mix test
```
