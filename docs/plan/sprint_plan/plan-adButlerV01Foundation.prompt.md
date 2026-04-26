# AdButler v0.1 — Day-by-Day Implementation Plan with Specifications

**Goal:** Build the foundation for Meta ad monitoring SaaS. 15-day sprint to deliver Meta OAuth login, encrypted token storage, ad data sync via Broadway+RabbitMQ, minimal LiveView UI, and LLM cost tracking plumbing. No analysis or chat yet—purely reliable ingestion.

**Philosophy:** Prove you can reliably ingest and reason about Meta data before building chat. Build in TDD mode with parallel work streams. Ship token ledger in v0.1, not v0.3—adding it later means back-filling data you can't reconstruct.

---

## Development Discipline (CODING_PRINCIPLES.md)

**All work follows [CODING_PRINCIPLES.md](/CODING_PRINCIPLES.md).** Key principles enforced throughout:

### TDD Workflow (Red → Green → Refactor)
1. **Write test first** — Test defines success, watch it fail (red)
2. **Make it pass** — Write minimal code to pass test (green)
3. **Clean up** — Refactor with passing tests (refactor)
4. **No untested code in main** — Test coverage = 100%

### Quality Gates (mix precommit)
Before every commit, run `mix precommit` which executes:
- `mix format --check-formatted` — Formatting is non-negotiable
- `mix compile --warnings-as-errors` — Warnings are bugs
- `mix credo --strict` — Code quality checks
- `mix test --cover` — Full test suite with coverage
- Coverage report must show 100%

### Core Principles
- **Behaviours for external services** — Meta.ClientBehaviour + Mox for testing
- **Contexts own Repo** — No direct Repo calls outside contexts
- **Tenant isolation via scope/2** — MANDATORY for all tenant-scoped queries
- **Oban for background jobs** — No GenServers for cron/scheduled work
- **Tagged tuples for errors** — `{:ok, value} | {:error, reason}`, no raises in happy path
- **Structured logging** — Key-value metadata, never string interpolation
- **Secrets from environment** — runtime.exs only, never compiled config
- **Cloak for PII** — Encrypt access tokens, sensitive data at rest
- **Custom UI components** — No DaisyUI, custom Tailwind, mobile-first

### Code Review Checklist
Every PR must pass:
- [ ] All tests pass (`mix test`)
- [ ] 100% code coverage
- [ ] `mix format --check-formatted` passes
- [ ] `mix compile --warnings-as-errors` passes
- [ ] `mix credo --strict` passes (or violations documented)
- [ ] Tenant isolation tests for context queries
- [ ] Behaviours defined for external services
- [ ] Secrets not logged or exposed
- [ ] Functions have `@spec` on public APIs

---

## Week 1: Database, Auth, and Meta Client (Days 1-5)

### Day 1: Database Schema & Migrations

**Parallel Track: Can run simultaneously with Day 2**

**Deliverables:**
1. Create migrations for core tables:
   - `users`, `meta_connections`, `ad_accounts`, `campaigns`, `ad_sets`, `ads`, `creatives`
   - Dependencies: `llm_usage`, `llm_pricing`, `user_quotas`
2. All tables include `inserted_at`, `updated_at` timestamps
3. Foreign keys with `on_delete: :delete_all` for cascades
4. Add indexes: `meta_connections(user_id)`, `ad_accounts(meta_connection_id)`, etc.

**Schema Specifications:**

```elixir
# Migration: create users
create table(:users, primary_key: false) do
  add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
  add :email, :string, null: false
  add :meta_user_id, :string  # from Meta OAuth
  add :name, :string
  
  timestamps(type: :utc_datetime_usec)
end

create unique_index(:users, [:email])
create index(:users, [:meta_user_id])

# Migration: create meta_connections
create table(:meta_connections, primary_key: false) do
  add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
  add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
  add :meta_user_id, :string, null: false
  add :access_token, :binary, null: false  # encrypted by Cloak
  add :token_expires_at, :utc_datetime_usec, null: false
  add :scopes, {:array, :string}, null: false, default: []
  add :status, :string, default: "active"  # active | expired | revoked
  
  timestamps(type: :utc_datetime_usec)
end

create index(:meta_connections, [:user_id])
create unique_index(:meta_connections, [:user_id, :meta_user_id])

# Migration: create ad_accounts
create table(:ad_accounts, primary_key: false) do
  add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
  add :meta_connection_id, references(:meta_connections, type: :uuid, on_delete: :delete_all)
  add :meta_id, :string, null: false  # Meta's ad account ID
  add :name, :string, null: false
  add :currency, :string, null: false
  add :timezone_name, :string, null: false
  add :status, :string, null: false
  add :last_synced_at, :utc_datetime_usec
  add :raw_jsonb, :jsonb, default: "{}"
  
  timestamps(type: :utc_datetime_usec)
end

create index(:ad_accounts, [:meta_connection_id])
create unique_index(:ad_accounts, [:meta_connection_id, :meta_id])

# Migration: create campaigns
create table(:campaigns, primary_key: false) do
  add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
  add :ad_account_id, references(:ad_accounts, type: :uuid, on_delete: :delete_all)
  add :meta_id, :string, null: false
  add :name, :string, null: false
  add :status, :string, null: false  # ACTIVE | PAUSED | DELETED
  add :objective, :string, null: false  # OUTCOME_TRAFFIC | OUTCOME_SALES | etc
  add :daily_budget_cents, :bigint
  add :lifetime_budget_cents, :bigint
  add :raw_jsonb, :jsonb, default: "{}"
  
  timestamps(type: :utc_datetime_usec)
end

create index(:campaigns, [:ad_account_id])
create unique_index(:campaigns, [:ad_account_id, :meta_id])

# Migration: create ad_sets
create table(:ad_sets, primary_key: false) do
  add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
  add :ad_account_id, references(:ad_accounts, type: :uuid, on_delete: :delete_all)
  add :campaign_id, references(:campaigns, type: :uuid, on_delete: :delete_all)
  add :meta_id, :string, null: false
  add :name, :string, null: false
  add :status, :string, null: false
  add :daily_budget_cents, :bigint
  add :lifetime_budget_cents, :bigint
  add :bid_amount_cents, :bigint
  add :targeting_jsonb, :jsonb, default: "{}"
  add :raw_jsonb, :jsonb, default: "{}"
  
  timestamps(type: :utc_datetime_usec)
end

create index(:ad_sets, [:ad_account_id])
create index(:ad_sets, [:campaign_id])
create unique_index(:ad_sets, [:ad_account_id, :meta_id])

# Migration: create ads
create table(:ads, primary_key: false) do
  add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
  add :ad_account_id, references(:ad_accounts, type: :uuid, on_delete: :delete_all)
  add :ad_set_id, references(:ad_sets, type: :uuid, on_delete: :delete_all)
  add :creative_id, references(:creatives, type: :uuid, on_delete: :nilify_all)
  add :meta_id, :string, null: false
  add :name, :string, null: false
  add :status, :string, null: false
  add :raw_jsonb, :jsonb, default: "{}"
  
  timestamps(type: :utc_datetime_usec)
end

create index(:ads, [:ad_account_id])
create index(:ads, [:ad_set_id])
create index(:ads, [:creative_id])
create unique_index(:ads, [:ad_account_id, :meta_id])

# Migration: create creatives
create table(:creatives, primary_key: false) do
  add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
  add :ad_account_id, references(:ad_accounts, type: :uuid, on_delete: :delete_all)
  add :meta_id, :string, null: false
  add :name, :string
  add :asset_specs_jsonb, :jsonb, default: "{}"  # images, video, body, title, cta
  add :raw_jsonb, :jsonb, default: "{}"
  
  timestamps(type: :utc_datetime_usec)
end

create index(:creatives, [:ad_account_id])
create unique_index(:creatives, [:ad_account_id, :meta_id])

# Migration: create llm_usage (plumbing for v0.3)
create table(:llm_usage, primary_key: false) do
  add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
  add :user_id, references(:users, type: :uuid, on_delete: :delete_all)
  add :conversation_id, :uuid
  add :turn_id, :uuid
  add :purpose, :string, null: false  # chat_response | embedding | finding_summary
  add :provider, :string, null: false  # anthropic | openai
  add :model, :string, null: false
  add :input_tokens, :integer, null: false, default: 0
  add :output_tokens, :integer, null: false, default: 0
  add :cached_tokens, :integer, null: false, default: 0
  add :cost_cents_input, :integer, null: false, default: 0
  add :cost_cents_output, :integer, null: false, default: 0
  add :cost_cents_total, :integer, null: false, default: 0
  add :latency_ms, :integer
  add :status, :string, null: false  # ok | error | timeout
  add :request_id, :string
  add :metadata, :jsonb, default: "{}"
  
  add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
end

create index(:llm_usage, [:user_id, :inserted_at])
create index(:llm_usage, [:inserted_at])
create index(:llm_usage, [:conversation_id])

# Migration: create llm_pricing
create table(:llm_pricing, primary_key: false) do
  add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
  add :provider, :string, null: false
  add :model, :string, null: false
  add :cents_per_1k_input, :decimal, precision: 10, scale: 6, null: false
  add :cents_per_1k_output, :decimal, precision: 10, scale: 6, null: false
  add :cents_per_1k_cached_input, :decimal, precision: 10, scale: 6
  add :effective_from, :utc_datetime_usec, null: false
  add :effective_to, :utc_datetime_usec
  
  timestamps(type: :utc_datetime_usec)
end

create unique_index(:llm_pricing, [:provider, :model, :effective_from])
create index(:llm_pricing, [:effective_from])

# Migration: create user_quotas
create table(:user_quotas, primary_key: false) do
  add :user_id, references(:users, type: :uuid, on_delete: :delete_all), primary_key: true
  add :daily_cost_cents_limit, :integer, default: 500  # $5/day
  add :daily_cost_cents_soft, :integer, default: 300  # warm at $3
  add :monthly_cost_cents_limit, :integer, default: 10_000  # $100/month
  add :tier, :string, default: "free"  # free | partner | internal
  add :cutoff_until, :utc_datetime_usec
  add :note, :text
  
  timestamps(type: :utc_datetime_usec)
end
```

**TDD Workflow for Day 1:**

No traditional TDD for schema migrations—schema IS the spec. Verification through:
1. **Migration test**: Run `mix ecto.migrate` and verify success
2. **Schema dump inspection**: Review generated schema matches specification
3. **Constraint testing**: Try violating constraints (unique, FK, null) to confirm enforcement

**Acceptance Criteria:**
- [ ] `mix ecto.migrate` succeeds without errors
- [ ] `mix ecto.dump` produces schema matching spec
- [ ] All foreign keys enforced
- [ ] Unique indexes prevent duplicates
- [ ] Constraint violations properly rejected (manual testing in `psql`)

**Quality Gates:**
```bash
mix format --check-formatted  # Format migrations
mix compile --warnings-as-errors  # No warnings
mix ecto.migrate  # Migrations succeed
mix ecto.dump  # Inspect schema
mix ecto.rollback  # Test rollback works
mix ecto.migrate  # Re-run migration
```

**Verification:**
```bash
mix ecto.migrate
mix ecto.dump
psql $DATABASE_URL -c "\d users"
psql $DATABASE_URL -c "\d meta_connections"
# Try violating constraints:
psql $DATABASE_URL -c "INSERT INTO users(id, email) VALUES (gen_random_uuid(), 'test@test.com');"
psql $DATABASE_URL -c "INSERT INTO users(id, email) VALUES (gen_random_uuid(), 'test@test.com');"  # Should fail unique constraint
```

---

### Day 2: Accounts Context + Encryption Setup

**Parallel Track: Can run simultaneously with Day 1**

**Deliverables:**
1. Add dependencies: `{:cloak_ecto, "~> 1.3"}`, `{:oban, "~> 2.18"}`
2. Create `lib/ad_butler/accounts.ex` context
3. Define `Accounts.User` schema with virtual `meta_id` field
4. Setup Cloak.Ecto vault with `CLOAK_KEY` env var
5. Define `Accounts.MetaConnection` schema with encrypted `:access_token`
6. Context functions: `get_user!/1`, `get_meta_connection!/1`, `create_meta_connection/2`

**Implementation:**

```elixir
# mix.exs - add dependencies
defp deps do
  [
    # ... existing deps
    {:cloak_ecto, "~> 1.3"},
    {:oban, "~> 2.18"}
  ]
end

# lib/ad_butler/vault.ex
defmodule AdButler.Vault do
  use Cloak.Vault, otp_app: :ad_butler
end

# config/config.exs
config :ad_butler, AdButler.Vault,
  ciphers: [
    default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: Base.decode64!(System.get_env("CLOAK_KEY"))}
  ]

# lib/ad_butler/accounts/user.ex
defmodule AdButler.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "users" do
    field :email, :string
    field :meta_user_id, :string
    field :name, :string
    
    has_many :meta_connections, AdButler.Accounts.MetaConnection

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :meta_user_id, :name])
    |> validate_required([:email])
    |> validate_format(:email, ~r/@/)
    |> unique_constraint(:email)
  end
end

# lib/ad_butler/accounts/meta_connection.ex
defmodule AdButler.Accounts.MetaConnection do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "meta_connections" do
    field :meta_user_id, :string
    field :access_token, AdButler.Encrypted.Binary
    field :token_expires_at, :utc_datetime_usec
    field :scopes, {:array, :string}
    field :status, :string, default: "active"
    
    belongs_to :user, AdButler.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(connection, attrs) do
    connection
    |> cast(attrs, [:user_id, :meta_user_id, :access_token, :token_expires_at, :scopes, :status])
    |> validate_required([:user_id, :meta_user_id, :access_token, :token_expires_at, :scopes])
    |> validate_inclusion(:status, ["active", "expired", "revoked"])
  end
end

# lib/ad_butler/encrypted/binary.ex
defmodule AdButler.Encrypted.Binary do
  use Cloak.Ecto.Binary, vault: AdButler.Vault
end

# lib/ad_butler/accounts.ex
defmodule AdButler.Accounts do
  @moduledoc """
  Context for user authentication and Meta OAuth token management.
  """

  import Ecto.Query
  alias AdButler.Repo
  alias AdButler.Accounts.{User, MetaConnection}

  @spec get_user!(binary()) :: User.t()
  def get_user!(id), do: Repo.get!(User, id)

  @spec get_user_by_email(String.t()) :: User.t() | nil
  def get_user_by_email(email), do: Repo.get_by(User, email: email)

  @spec create_or_update_user(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def create_or_update_user(attrs) do
    case get_user_by_email(attrs[:email]) do
      nil -> 
        %User{}
        |> User.changeset(attrs)
        |> Repo.insert()
      
      user ->
        user
        |> User.changeset(attrs)
        |> Repo.update()
    end
  end

  @spec get_meta_connection!(binary()) :: MetaConnection.t()
  def get_meta_connection!(id), do: Repo.get!(MetaConnection, id)

  @spec create_meta_connection(User.t(), map()) :: {:ok, MetaConnection.t()} | {:error, Ecto.Changeset.t()}
  def create_meta_connection(%User{} = user, attrs) do
    %MetaConnection{}
    |> MetaConnection.changeset(Map.put(attrs, :user_id, user.id))
    |> Repo.insert()
  end

  @spec list_meta_connections(User.t()) :: list(MetaConnection.t())
  def list_meta_connections(%User{id: user_id}) do
    MetaConnection
    |> where([mc], mc.user_id == ^user_id)
    |> where([mc], mc.status == "active")
    |> Repo.all()
  end
end
```

**Tests:**

```elixir
# test/ad_butler/accounts_test.exs
defmodule AdButler.AccountsTest do
  use AdButler.DataCase, async: true

  alias AdButler.Accounts

  describe "create_meta_connection/2" do
    test "encrypts token before storage" do
      user = insert(:user)
      
      attrs = %{
        meta_user_id: "meta_123",
        access_token: "plaintext_token",
        token_expires_at: DateTime.add(DateTime.utc_now(), 60, :day),
        scopes: ["ads_read", "ads_management"]
      }
      
      {:ok, connection} = Accounts.create_meta_connection(user, attrs)
      
      # Token should be encrypted in DB
      raw_connection = Repo.get!(Accounts.MetaConnection, connection.id)
      refute raw_connection.access_token == "plaintext_token"
      
      # But decrypts when accessed
      assert connection.access_token == "plaintext_token"
    end
  end
end
```

**TDD Workflow for Day 2:**

1. **RED**: Write test for `create_meta_connection/2` encryption
   - Test verifies raw DB value ≠ plaintext
   - Test verifies decrypted value == plaintext
   - Run test, watch it FAIL (no implementation yet)

2. **GREEN**: Implement `Accounts` context
   - Create `Vault`, `Encrypted.Binary`, `User`, `MetaConnection` schemas
   - Implement `create_meta_connection/2` function
   - Run test, watch it PASS

3. **REFACTOR**: Clean up
   - Add `@spec` type annotations
   - Extract magic values to module attributes
   - Ensure consistent error handling

**Acceptance Criteria:**
- [ ] Token stored encrypted in database (verify in tests)
- [ ] Token decrypts correctly on read (verify in tests)
- [ ] User CRUD operations work
- [ ] All tests pass with 100% coverage
- [ ] `@spec` annotations on all public functions
- [ ] Cloak encryption verified in test (compare raw vs accessed value)

**Quality Gates:**
```bash
CLOAK_KEY=$(mix cloak.generate.key) mix test test/ad_butler/accounts_test.exs
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict lib/ad_butler/accounts.ex lib/ad_butler/accounts/
mix test --cover  # Should show 100% for Accounts context
```

**Verification:**
```bash
CLOAK_KEY=$(mix cloak.generate.key) mix test test/ad_butler/accounts_test.exs
# Verify encryption in console:
mix run -e 'AdButler.Repo.all(AdButler.Accounts.MetaConnection) |> IO.inspect()'
```

**Principle Checkpoints:**
- ✅ CODING_PRINCIPLES.md Section 11: Cloak for PII encryption
- ✅ Section 1: TDD (test-first development)
- ✅ Section 6: Contexts own Repo (no direct Repo outside context)

---

### Day 3: Meta OAuth Flow

**Deliverables:**
1. Create `lib/ad_butler_web/controllers/auth_controller.ex`
2. Routes: `GET /auth/meta`, `GET /auth/meta/callback`
3. OAuth URL builder with scopes: `ads_management`, `ads_read`, `email`
4. Callback handler: exchange code for token, create/update `meta_connection`
5. Session management: store `user_id` in session
6. Error handling: invalid code, expired state, denied permissions

**Implementation:**

```elixir
# lib/ad_butler_web/router.ex
scope "/auth", AdButlerWeb do
  pipe_through :browser
  
  get "/meta", AuthController, :request
  get "/meta/callback", AuthController, :callback
end

# lib/ad_butler_web/controllers/auth_controller.ex
defmodule AdButlerWeb.AuthController do
  use AdButlerWeb, :controller
  
  alias AdButler.Accounts
  
  @meta_oauth_url "https://www.facebook.com/v19.0/dialog/oauth"
  
  def request(conn, _params) do
    state = generate_state()
    
    oauth_url = build_oauth_url(state)
    
    conn
    |> put_session(:oauth_state, state)
    |> redirect(external: oauth_url)
  end
  
  def callback(conn, %{"code" => code, "state" => state} = params) do
    with :ok <- verify_state(conn, state),
         {:ok, token_response} <- exchange_code_for_token(code),
         {:ok, user_info} <- fetch_user_info(token_response["access_token"]),
         {:ok, user} <- Accounts.create_or_update_user(%{
           email: user_info["email"],
           meta_user_id: user_info["id"],
           name: user_info["name"]
         }),
         {:ok, _connection} <- Accounts.create_meta_connection(user, %{
           meta_user_id: user_info["id"],
           access_token: token_response["access_token"],
           token_expires_at: calculate_expiry(token_response["expires_in"]),
           scopes: ["ads_read", "ads_management", "email"]
         }) do
      
      conn
      |> put_session(:user_id, user.id)
      |> put_flash(:info, "Successfully connected to Meta")
      |> redirect(to: ~p"/dashboard")
    else
      {:error, :invalid_state} ->
        conn
        |> put_flash(:error, "Invalid OAuth state")
        |> redirect(to: ~p"/")
      
      {:error, reason} ->
        conn
        |> put_flash(:error, "Failed to connect: #{inspect(reason)}")
        |> redirect(to: ~p"/")
    end
  end
  
  def callback(conn, %{"error" => error, "error_description" => description}) do
    conn
    |> put_flash(:error, "OAuth error: #{description}")
    |> redirect(to: ~p"/")
  end
  
  defp build_oauth_url(state) do
    params = %{
      client_id: meta_app_id(),
      redirect_uri: callback_url(),
      state: state,
      scope: "ads_read,ads_management,email"
    }
    
    query = URI.encode_query(params)
    "#{@meta_oauth_url}?#{query}"
  end
  
  defp exchange_code_for_token(code) do
    url = "https://graph.facebook.com/v19.0/oauth/access_token"
    
    params = %{
      client_id: meta_app_id(),
      client_secret: meta_app_secret(),
      redirect_uri: callback_url(),
      code: code
    }
    
    case Req.post(url, form: params) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{body: body}} -> {:error, body}
      {:error, reason} -> {:error, reason}
    end
  end
  
  defp fetch_user_info(access_token) do
    url = "https://graph.facebook.com/v23.0/me"
    params = [access_token: access_token, fields: "id,name,email"]
    
    case Req.get(url, params: params) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{body: body}} -> {:error, body}
      {:error, reason} -> {:error, reason}
    end
  end
  
  defp verify_state(conn, state) do
    case get_session(conn, :oauth_state) do
      ^state -> :ok
      _ -> {:error, :invalid_state}
    end
  end
  
  defp generate_state do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end
  
  defp calculate_expiry(expires_in) when is_integer(expires_in) do
    DateTime.add(DateTime.utc_now(), expires_in, :second)
  end
  
  defp meta_app_id, do: Application.fetch_env!(:ad_butler, :meta_app_id)
  defp meta_app_secret, do: Application.fetch_env!(:ad_butler, :meta_app_secret)
  defp callback_url, do: Application.fetch_env!(:ad_butler, :meta_oauth_callback_url)
end
```

**Tests:**

```elixir
# test/ad_butler_web/controllers/auth_controller_test.exs
defmodule AdButlerWeb.AuthControllerTest do
  use AdButlerWeb.ConnCase, async: true
  
  describe "GET /auth/meta" do
    test "redirects to Meta OAuth", %{conn: conn} do
      conn = get(conn, ~p"/auth/meta")
      
      assert redirected_to(conn, 302) =~ "facebook.com"
      assert get_session(conn, :oauth_state)
    end
  end
  
  describe "GET /auth/meta/callback" do
    test "creates user and connection on success", %{conn: conn} do
      # Mock Meta responses
      # ... implementation
    end
    
    test "handles OAuth errors gracefully", %{conn: conn} do
      conn = get(conn, ~p"/auth/meta/callback", %{
        "error" => "access_denied",
        "error_description" => "User denied permissions"
      })
      
      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "OAuth error"
    end
  end
end
```

**TDD Workflow for Day 3:**

1. **RED**: Write controller tests first
   - Test `/auth/meta` redirects to Facebook with state in session
   - Test `/auth/meta/callback` with valid code creates user + connection
   - Test error cases (invalid state, OAuth denied)
   - Run tests, watch them FAIL

2. **GREEN**: Implement `AuthController`
   - Build `request/2` action with OAuth URL generation
   - Build `callback/2` with code exchange and user creation
   - Mock Meta API responses in tests using Mox (Day 4 prereq)
   - Run tests, watch them PASS

3. **REFACTOR**: Extract helpers
   - Move OAuth URL building to private function
   - Extract error handling to dedicated clauses
   - Add structured logging for OAuth events

**Acceptance Criteria:**
- [ ] OAuth flow initiates correctly (test verifies redirect URL)
- [ ] Callback creates user and meta_connection (test mocks Meta API)
- [ ] Session contains user_id after success
- [ ] Errors handled gracefully (test all error paths)
- [ ] All tests pass with 100% coverage
- [ ] Structured logging for OAuth success/failure
- [ ] Secrets loaded from `runtime.exs` (never compiled config)

**Quality Gates:**
```bash
mix test test/ad_butler_web/controllers/auth_controller_test.exs
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict lib/ad_butler_web/controllers/auth_controller.ex
mix test --cover  # Check controller coverage = 100%
```

**Verification:**
```bash
# Manual OAuth test (optional, requires Meta app setup):
iex -S mix phx.server
# Navigate to localhost:4000/auth/meta in browser
# Complete OAuth flow
# Verify user created: Repo.all(User)
```

**Principle Checkpoints:**
- ✅ Section 11: Secrets from environment (runtime.exs, never log tokens)
- ✅ Section 1: TDD (test controller actions before implementation)
- ✅ Section 5: Tagged tuples for errors (`{:ok, _}` | `{:error, reason}`)

---

### Day 4: Meta.Client + Rate-Limit Ledger

**Deliverables:**
1. Create `lib/ad_butler/meta/client.ex` using `Req`
2. Functions: `list_ad_accounts/1`, `get_ad_account/2`, `list_ads/2`
3. Parse `X-Business-Use-Case-Usage` header into ETS table keyed by account_id
4. Batch call support: `batch_request/2` (packs up to 50 requests)
5. Error handling: rate limit exceeded, invalid token, network timeout
6. Create `lib/ad_butler/meta/behaviour.ex` for Mox

**Implementation:**

```elixir
# lib/ad_butler/meta/behaviour.ex
defmodule AdButler.Meta.ClientBehaviour do
  @callback list_ad_accounts(String.t()) :: {:ok, list(map())} | {:error, term()}
  @callback list_campaigns(String.t(), String.t(), keyword()) :: {:ok, list(map())} | {:error, term()}
  @callback list_ad_sets(String.t(), String.t(), keyword()) :: {:ok, list(map())} | {:error, term()}
  @callback list_ads(String.t(), String.t(), keyword()) :: {:ok, list(map())} | {:error, term()}
  @callback get_creative(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  @callback batch_request(String.t(), list(map())) :: {:ok, list(map())} | {:error, term()}
  @callback get_rate_limit_usage(String.t()) :: float()
  @callback refresh_token(String.t()) :: {:ok, map()} | {:error, term()}
end

# lib/ad_butler/meta/client.ex
defmodule AdButler.Meta.Client do
  @moduledoc """
  Meta Graph API client with rate-limit awareness and batch support.
  """
  
  @behaviour AdButler.Meta.ClientBehaviour
  
  @graph_api_base "https://graph.facebook.com/v23.0"
  @rate_limit_table :meta_rate_limits
  
  require Logger
  
  def init do
    :ets.new(@rate_limit_table, [:named_table, :public, :set])
  end
  
  @impl true
  def list_ad_accounts(access_token) do
    path = "/me/adaccounts"
    fields = "id,name,currency,timezone_name,account_status"
    
    make_request(:get, path, access_token, params: [fields: fields])
  end
  
  @impl true
  def list_campaigns(access_token, ad_account_id, opts \\ []) do
    path = "/#{ad_account_id}/campaigns"
    fields = opts[:fields] || "id,name,status,objective,daily_budget,lifetime_budget"
    
    make_request(:get, path, access_token, params: [fields: fields])
  end
  
  @impl true
  def list_ad_sets(access_token, ad_account_id, opts \\ []) do
    path = "/#{ad_account_id}/adsets"
    fields = opts[:fields] || "id,name,status,daily_budget,lifetime_budget,bid_amount,targeting"
    
    make_request(:get, path, access_token, params: [fields: fields])
  end
  
  @impl true
  def list_ads(access_token, ad_account_id, opts \\ []) do
    path = "/#{ad_account_id}/ads"
    fields = opts[:fields] || "id,name,status,creative,adset_id"
    
    make_request(:get, path, access_token, params: [fields: fields])
  end
  
  @impl true
  def get_creative(access_token, creative_id) do
    path = "/#{creative_id}"
    fields = "id,name,object_story_spec,asset_feed_spec,thumbnail_url"
    
    make_request(:get, path, access_token, params: [fields: fields])
  end
  
  @impl true
  def batch_request(access_token, requests) when length(requests) <= 50 do
    path = "/"
    batch_param = Jason.encode!(requests)
    
    make_request(:post, path, access_token, form: [batch: batch_param])
  end
  
  @impl true
  def get_rate_limit_usage(ad_account_id) do
    case :ets.lookup(@rate_limit_table, ad_account_id) do
      [{_, {call_count, _cpu, _time, _updated}}] -> call_count * 1.0
      [] -> 0.0
    end
  end
  
  @impl true
  def refresh_token(current_token) do
    path = "/oauth/access_token"
    
    make_request(:get, path, current_token, 
      params: [
        grant_type: "fb_exchange_token",
        client_id: meta_app_id(),
        client_secret: meta_app_secret(),
        fb_exchange_token: current_token
      ]
    )
  end
  
  # Private helpers
  
  defp make_request(method, path, access_token, opts \\ []) do
    url = "#{@graph_api_base}#{path}"
    opts = Keyword.merge(opts, [params: [access_token: access_token | (opts[:params] || [])]])
    
    case Req.request(method: method, url: url, opts) do
      {:ok, %{status: 200, body: %{"data" => data}} = response} ->
        parse_rate_limit_header(response, extract_account_id(path))
        {:ok, data}
      
      {:ok, %{status: 200, body: body} = response} ->
        parse_rate_limit_header(response, extract_account_id(path))
        {:ok, body}
      
      {:ok, response} ->
        handle_error(response)
      
      {:error, reason} ->
        handle_error(reason)
    end
  end
  
  defp parse_rate_limit_header(%{headers: headers}, ad_account_id) when not is_nil(ad_account_id) do
    case List.keyfind(headers, "x-business-use-case-usage", 0) do
      {_, value} ->
        with {:ok, decoded} <- Jason.decode(value),
             [%{"call_count" => cc, "total_cputime" => cpu, "total_time" => tt} | _] <- decoded do
          :ets.insert(@rate_limit_table, {ad_account_id, {cc, cpu, tt, DateTime.utc_now()}})
        end
      nil ->
        :ok
    end
  end
  defp parse_rate_limit_header(_, _), do: :ok
  
  defp extract_account_id("/" <> path) do
    case String.split(path, "/") do
      ["act_" <> _rest = account_id | _] -> account_id
      _ -> nil
    end
  end
  
  defp handle_error(%{status: 400, body: body}) do
    {:error, {:bad_request, get_in(body, ["error", "message"])}}
  end
  
  defp handle_error(%{status: 401}) do
    {:error, :unauthorized}
  end
  
  defp handle_error(%{status: 403}) do
    {:error, :forbidden}
  end
  
  defp handle_error(%{status: 429}) do
    {:error, :rate_limit_exceeded}
  end
  
  defp handle_error(%{status: status}) when status >= 500 do
    {:error, :meta_server_error}
  end
  
  defp handle_error({:error, %{reason: :timeout}}) do
    {:error, :timeout}
  end
  
  defp handle_error({:error, reason}) do
    {:error, reason}
  end
  
  defp meta_app_id, do: Application.fetch_env!(:ad_butler, :meta_app_id)
  defp meta_app_secret, do: Application.fetch_env!(:ad_butler, :meta_app_secret)
end
```

**TDD Workflow for Day 4:**

1. **RED**: Write behaviour and tests using Mox
   - Define `Meta.ClientBehaviour` with callbacks
   - Write tests using `Mox` (mock Meta API responses)
   - Test: `list_ad_accounts/1` returns parsed data
   - Test: Rate limit headers populate ETS
   - Test: Batch request packs up to 50 requests
   - Test: Error cases (401, 429, timeout)
   - Run tests, watch them FAIL

2. **GREEN**: Implement `Meta.Client` with `Req`
   - Implement all behaviour callbacks
   - Parse rate limit headers into ETS
   - Handle all error status codes
   - Run tests, watch them PASS

3. **REFACTOR**: Extract helpers
   - Private `make_request/4` for DRY
   - Consistent error tuple patterns
   - Module attributes for API constants

**Acceptance Criteria:**
- [ ] API calls return parsed data (tested with Mox)
- [ ] Rate limits tracked in ETS (verify in test)
- [ ] Batch requests work (test batching logic)
- [ ] All error cases handled (401, 403, 429, 500, timeout)
- [ ] 100% test coverage with Mox mocks
- [ ] `Meta.ClientBehaviour` defined for testing
- [ ] No direct HTTP calls in tests (all mocked)

**Quality Gates:**
```bash
mix test test/ad_butler/meta/client_test.exs
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict lib/ad_butler/meta/
mix test --cover  # Meta.Client coverage = 100%
```

**Verification:**
```bash
# Verify ETS table creation:
iex -S mix
AdButler.Meta.Client.init()
:ets.info(:meta_rate_limits)

# Run full test suite:
mix test test/ad_butler/meta/
```

**Principle Checkpoints:**
- ✅ Section 9: Behaviours for external services (Meta.ClientBehaviour)
- ✅ Section 9: Mox for testing external APIs
- ✅ Section 1: TDD (test with mocks before making real API calls)
- ✅ AGENTS.md: Use `:req` library, not httpoison/tesla

---

### Day 5: Token Refresh Job + Oban Setup

**Deliverables:**
1. Add Oban to supervision tree in `application.ex`
2. Configure queues: `:default`, `:sync`, `:analytics`
3. Create `lib/ad_butler/workers/token_refresh_worker.ex`
4. Schedule job 50 days from token issue
5. Job logic: call Meta refresh endpoint, update `meta_connection`

**Implementation:**

```elixir
# lib/ad_butler/application.ex
def start(_type, _args) do
  children = [
    AdButler.Repo,
    {Oban, Application.fetch_env!(:ad_butler, Oban)},
    AdButlerWeb.Endpoint,
    {Phoenix.PubSub, name: AdButler.PubSub}
  ]
  
  # Initialize Meta Client ETS table
  AdButler.Meta.Client.init()
  
  opts = [strategy: :one_for_one, name: AdButler.Supervisor]
  Supervisor.start_link(children, opts)
end

# config/config.exs
config :ad_butler, Oban,
  repo: AdButler.Repo,
  queues: [default: 10, sync: 20, analytics: 5],
  plugins: []

# lib/ad_butler/workers/token_refresh_worker.ex
defmodule AdButler.Workers.TokenRefreshWorker do
  use Oban.Worker, queue: :default, max_attempts: 3
  
  alias AdButler.{Accounts, Meta, Repo}
  
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"meta_connection_id" => connection_id}}) do
    connection = Accounts.get_meta_connection!(connection_id)
    
    case Meta.Client.refresh_token(connection.access_token) do
      {:ok, %{"access_token" => new_token, "expires_in" => expires_in}} ->
        connection
        |> Ecto.Changeset.change(%{
          access_token: new_token,
          token_expires_at: DateTime.add(DateTime.utc_now(), expires_in, :second)
        })
        |> Repo.update()
        
        # Schedule next refresh (50 days from now)
        schedule_next_refresh(connection_id, expires_in)
        
        :ok
      
      {:error, reason} ->
        {:error, reason}
    end
  end
  
  def schedule_refresh(meta_connection_id, days_until_expiry) do
    refresh_in_days = max(days_until_expiry - 10, 1)
    
    %{meta_connection_id: meta_connection_id}
    |> new(schedule_in: {refresh_in_days, :days})
    |> Oban.insert()
  end
  
  defp schedule_next_refresh(connection_id, expires_in_seconds) do
    days_until_expiry = div(expires_in_seconds, 86400)
    schedule_refresh(connection_id, days_until_expiry)
  end
end
```

**TDD Workflow for Day 5:**

1. **RED**: Write Oban worker test first
   - Test: Job performs token refresh successfully (mock Meta.Client)
   - Test: Job schedules next refresh 50 days out
   - Test: Job handles refresh failures gracefully
   - Run test, watch it FAIL

2. **GREEN**: Implement `TokenRefreshWorker`
   - Add Oban to supervision tree
   - Implement `perform/1` with Meta.Client.refresh_token/1
   - Schedule next job after success
   - Run test, watch it PASS

3. **REFACTOR**: Extract scheduling logic
   - Public `schedule_refresh/2` function
   - Private `schedule_next_refresh/2` helper
   - Add structured logging

**Acceptance Criteria:**
- [ ] Oban starts with application
- [ ] Job enqueues successfully (test verifies job in DB)
- [ ] Token refresh works (mocked in test)
- [ ] Next job scheduled (verify scheduled_at timestamp)
- [ ] 100% test coverage on worker
- [ ] Worker retries on failure (max_attempts: 3)
- [ ] Structured logging for refresh events

**Quality Gates:**
```bash
mix test test/ad_butler/workers/token_refresh_worker_test.exs
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict lib/ad_butler/workers/
mix test --cover  # Worker coverage = 100%
```

**Verification:**
```bash
# Verify Oban supervision:
iex -S mix
Supervisor.which_children(AdButler.Supervisor) |> IO.inspect(label: "Children")

# Enqueue test job:
AdButler.Workers.TokenRefreshWorker.schedule_refresh("conn_id", 60)
AdButler.Repo.all(Oban.Job) |> IO.inspect()
```

**Principle Checkpoints:**
- ✅ Section 3: Oban for background jobs (NOT GenServer with timers)
- ✅ Section 1: TDD (test worker before implementation)
- ✅ Section 9: Mock Meta.Client in worker tests (behaviour from Day 4)

---

## Week 2: Sync Pipeline & Ads Context (Days 6-10)

### Day 6: RabbitMQ Topology + Broadway Setup

**Deliverables:**
1. Add `{:broadway_rabbitmq, "~> 0.8"}` dependency
2. Create `lib/ad_butler/messaging/rabbitmq_topology.ex`
3. Define exchanges: `ad_butler.sync.fanout`, `ad_butler.sync.dlq.fanout`
4. Define queues: `ad_butler.sync.metadata`, `ad_butler.sync.metadata.dlq`
5. Configure dead-letter exchange with TTL (5 minutes)
6. Setup Broadway pipeline stub (full implementation Day 9)

**Implementation:**

```elixir
# mix.exs
defp deps do
  [
    # ... existing
    {:broadway_rabbitmq, "~> 0.8"}
  ]
end

# config/runtime.exs
config :ad_butler, :rabbitmq,
  url: System.fetch_env!("RABBITMQ_URL")

# lib/ad_butler/messaging/rabbitmq_topology.ex
defmodule AdButler.Messaging.RabbitMQTopology do
  @moduledoc """
  Defines RabbitMQ exchanges, queues, and bindings for sync pipeline.
  """
  
  require Logger
  
  @exchange "ad_butler.sync.fanout"
  @dlq_exchange "ad_butler.sync.dlq.fanout"
  @queue "ad_butler.sync.metadata"
  @dlq "ad_butler.sync.metadata.dlq"
  
  def setup do
    {:ok, conn} = AMQP.Connection.open(rabbitmq_url())
    {:ok, channel} = AMQP.Channel.open(conn)
    
    # Declare DLQ exchange and queue first
    AMQP.Exchange.declare(channel, @dlq_exchange, :fanout, durable: true)
    AMQP.Queue.declare(channel, @dlq, durable: true)
    AMQP.Queue.bind(channel, @dlq, @dlq_exchange)
    
    # Declare main exchange
    AMQP.Exchange.declare(channel, @exchange, :fanout, durable: true)
    
    # Declare main queue with DLQ arguments
    AMQP.Queue.declare(channel, @queue,
      durable: true,
      arguments: [
        {"x-dead-letter-exchange", :longstr, @dlq_exchange},
        {"x-message-ttl", :long, 300_000}  # 5 minutes before DLQ
      ]
    )
    
    AMQP.Queue.bind(channel, @queue, @exchange)
    
    AMQP.Channel.close(channel)
    AMQP.Connection.close(conn)
    
    Logger.info("RabbitMQ topology setup complete",
      exchange: @exchange,
      queue: @queue,
      dlq: @dlq
    )
    
    :ok
  end
  
  defp rabbitmq_url, do: Application.fetch_env!(:ad_butler, :rabbitmq)[:url]
end
```

**TDD Workflow for Day 6:**

1. **RED**: Write setup verification test
   - Test: Topology setup creates exchange, queue, DLQ
   - Test: Queue has correct DLQ arguments
   - Test: Bindings exist
   - Run test with ephemeral RabbitMQ (Docker), watch it FAIL

2. **GREEN**: Implement topology setup
   - Create exchange, queue, DLQ with correct arguments
   - Run test, watch it PASS

3. **REFACTOR**: Extract constants
   - Module attributes for exchange/queue names
   - Configuration for TTL values

**Acceptance Criteria:**
- [ ] Topology setup creates all exchanges and queues
- [ ] DLQ configured with TTL
- [ ] Bindings verified in test
- [ ] 100% coverage for topology module
- [ ] Structured logging for setup events

**Quality Gates:**
```bash
# Start test RabbitMQ container:
docker run -d --name rabbitmq-test -p 5672:5672 rabbitmq:3.13-alpine

RABBITMQ_URL=amqp://localhost:5672 mix test test/ad_butler/messaging/rabbitmq_topology_test.exs
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict lib/ad_butler/messaging/

# Cleanup:
docker stop rabbitmq-test && docker rm rabbitmq-test
```

**Verification:**
```bash
# Run topology setup manually:
RABBITMQ_URL=amqp://localhost:5672 mix run -e 'AdButler.Messaging.RabbitMQTopology.setup()'

# Inspect queues:
docker exec rabbitmq-test rabbitmqctl list_queues name durable arguments
docker exec rabbitmq-test rabbitmqctl list_exchanges name type durable
```

**Principle Checkpoints:**
- ✅ Section 11: Secrets from environment (RABBITMQ_URL in runtime.exs)
- ✅ Section 10: Structured logging (key-value metadata)

---

### Day 7: Sync.Scheduler GenServer

**Parallel Track: Can run simultaneously with Day 6**

**Deliverables:**
1. Create `lib/ad_butler/sync/scheduler.ex` GenServer
2. On startup, query active `meta_connections`
3. For each connection, enqueue Oban job to fetch ad accounts
4. Expose `schedule_sync_for_connection/1` public API
5. Handle connection refresh events

**Implementation:**

```elixir
# lib/ad_butler/sync/scheduler.ex
defmodule AdButler.Sync.Scheduler do
  @moduledoc """
  GenServer that coordinates ad account sync scheduling.
  Triggered on boot and when new connections added.
  """
  
  use GenServer
  require Logger
  
  alias AdButler.Accounts
  alias AdButler.Workers.FetchAdAccountsWorker
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  @impl true
  def init(_opts) do
    # Schedule initial sync shortly after boot
    Process.send_after(self(), :schedule_all, 5_000)
    {:ok, %{}}
  end
  
  @impl true
  def handle_info(:schedule_all, state) do
    connections = Accounts.list_all_active_meta_connections()
    
    Logger.info("Scheduling syncs for connections",
      count: length(connections)
    )
    
    Enum.each(connections, &schedule_sync_for_connection/1)
    
    {:noreply, state}
  end
  
  def schedule_sync_for_connection(%Accounts.MetaConnection{id: id}) do
    %{meta_connection_id: id}
    |> FetchAdAccountsWorker.new()
    |> Oban.insert()
  end
end

# lib/ad_butler/workers/fetch_ad_accounts_worker.ex
defmodule AdButler.Workers.FetchAdAccountsWorker do
  use Oban.Worker, queue: :sync, max_attempts: 5
  
  alias AdButler.{Accounts, Meta, Repo}
  
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"meta_connection_id" => connection_id}}) do
    connection = Accounts.get_meta_connection!(connection_id)
    
    case Meta.Client.list_ad_accounts(connection.access_token) do
      {:ok, accounts} ->
        Enum.each(accounts, fn account ->
          upsert_ad_account(connection, account)
          enqueue_metadata_sync(account["id"])
        end)
        
        :ok
      
      {:error, :rate_limit_exceeded} ->
        {:snooze, 60}  # Retry in 60 seconds
      
      {:error, reason} ->
        {:error, reason}
    end
  end
  
  defp upsert_ad_account(connection, %{"id" => meta_id} = account) do
    # Use Repo.insert/update with on_conflict
    %AdButler.Ads.AdAccount{}
    |> AdButler.Ads.AdAccount.changeset(%{
      meta_connection_id: connection.id,
      meta_id: meta_id,
      name: account["name"],
      currency: account["currency"],
      timezone_name: account["timezone_name"],
      status: account["account_status"],
      raw_jsonb: account
    })
    |> Repo.insert(on_conflict: :replace_all, conflict_target: [:meta_connection_id, :meta_id])
  end
  
  defp enqueue_metadata_sync(ad_account_id) do
    # Publish message to RabbitMQ for Broadway to consume
    payload = Jason.encode!(%{ad_account_id: ad_account_id, sync_type: "full"})
    
    {:ok, conn} = AMQP.Connection.open(rabbitmq_url())
    {:ok, channel} = AMQP.Channel.open(conn)
    
    AMQP.Basic.publish(channel, "ad_butler.sync.fanout", "", payload, persistent: true)
    
    AMQP.Channel.close(channel)
    AMQP.Connection.close(conn)
  end
  
  defp rabbitmq_url, do: Application.fetch_env!(:ad_butler, :rabbitmq)[:url]
end
```

**TDD Workflow for Day 7:**

1. **RED**: Write GenServer and worker tests
   - Test: GenServer schedules jobs on `:schedule_all`
   - Test: Worker fetches ad accounts (mocked Meta.Client)
   - Test: Worker upserts ad accounts to DB
   - Test: Worker publishes to RabbitMQ
   - Test: Rate limit error triggers snooze
   - Run tests, watch them FAIL

2. **GREEN**: Implement Scheduler and Worker
   - GenServer sends `:schedule_all` on init
   - Worker calls Meta.Client (mocked in tests)
   - Worker upserts ad accounts
   - Run tests, watch them PASS

3. **REFACTOR**: Extract helpers
   - Private `upsert_ad_account/2`
   - Private `enqueue_metadata_sync/1`

**Acceptance Criteria:**
- [ ] GenServer starts and schedules syncs
- [ ] Worker fetches ad accounts (tested with Mox)
- [ ] Worker upserts ad accounts (verify in test DB)
- [ ] Worker publishes to RabbitMQ (test with mock)
- [ ] Rate limit handling works (snooze behavior)
- [ ] 100% test coverage

**Quality Gates:**
```bash
mix test test/ad_butler/sync/scheduler_test.exs test/ad_butler/workers/fetch_ad_accounts_worker_test.exs
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict lib/ad_butler/sync/ lib/ad_butler/workers/
mix test --cover
```

**Verification:**
```bash
# Manual test:
iex -S mix
AdButler.Sync.Scheduler.schedule_sync_for_connection(conn)
AdButler.Repo.all(Oban.Job) |> IO.inspect()
```

**Principle Checkpoints:**
- ✅ Section 3: GenServer ALLOWED here (stateful coordinator, not cron)
- ✅ Section 3: Oban for actual work (FetchAdAccountsWorker)
- ✅ Section 9: Mock Meta.Client in tests (behaviour)

---

### Day 8: Ads Context with scope/2

**Deliverables:**
1. Create `lib/ad_butler/ads.ex` context
2. Define schemas: `AdAccount`, `Campaign`, `AdSet`, `Ad`, `Creative`
3. Implement `scope/2` for tenant isolation (CRITICAL SECURITY)
4. Context functions: `list_campaigns/2`, `get_campaign!/2`, etc.
5. **MANDATORY**: Two-user isolation tests for every query function

**Implementation:**

```elixir
# lib/ad_butler/ads/ad_account.ex
defmodule AdButler.Ads.AdAccount do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "ad_accounts" do
    field :meta_id, :string
    field :name, :string
    field :currency, :string
    field :timezone_name, :string
    field :status, :string
    field :last_synced_at, :utc_datetime_usec
    field :raw_jsonb, :map
    
    belongs_to :meta_connection, AdButler.Accounts.MetaConnection
    
    has_many :campaigns, AdButler.Ads.Campaign
    has_many :ad_sets, AdButler.Ads.AdSet
    has_many :ads, AdButler.Ads.Ad
    has_many :creatives, AdButler.Ads.Creative

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(ad_account, attrs) do
    ad_account
    |> cast(attrs, [:meta_connection_id, :meta_id, :name, :currency, :timezone_name, :status, :last_synced_at, :raw_jsonb])
    |> validate_required([:meta_connection_id, :meta_id, :name, :currency, :timezone_name, :status])
    |> unique_constraint([:meta_connection_id, :meta_id])
  end
end

# lib/ad_butler/ads/campaign.ex
defmodule AdButler.Ads.Campaign do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "campaigns" do
    field :meta_id, :string
    field :name, :string
    field :status, :string
    field :objective, :string
    field :daily_budget_cents, :integer
    field :lifetime_budget_cents, :integer
    field :raw_jsonb, :map
    
    belongs_to :ad_account, AdButler.Ads.AdAccount
    has_many :ad_sets, AdButler.Ads.AdSet

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(campaign, attrs) do
    campaign
    |> cast(attrs, [:ad_account_id, :meta_id, :name, :status, :objective, :daily_budget_cents, :lifetime_budget_cents, :raw_jsonb])
    |> validate_required([:ad_account_id, :meta_id, :name, :status, :objective])
    |> validate_inclusion(:status, ["ACTIVE", "PAUSED", "DELETED"])
    |> unique_constraint([:ad_account_id, :meta_id])
  end
end

# lib/ad_butler/ads.ex
defmodule AdButler.Ads do
  @moduledoc """
  Context for Meta ad accounts, campaigns, ad sets, ads, and creatives.
  
  CRITICAL: All queries MUST use scope/2 for tenant isolation (see D0001).
  """
  
  import Ecto.Query
  alias AdButler.Repo
  alias AdButler.Accounts.{User, MetaConnection}
  alias AdButler.Ads.{AdAccount, Campaign, AdSet, Ad, Creative}
  
  # THE CORE SECURITY BOUNDARY
  # Every user-facing query MUST flow through scope/2
  defp scope(queryable, %User{id: user_id}) do
    from q in queryable,
      join: aa in AdAccount, on: q.ad_account_id == aa.id,
      join: mc in assoc(aa, :meta_connection),
      where: mc.user_id == ^user_id
  end
  
  # AdAccount queries
  
  @spec list_ad_accounts(User.t()) :: list(AdAccount.t())
  def list_ad_accounts(%User{id: user_id}) do
    AdAccount
    |> join(:inner, [aa], mc in assoc(aa, :meta_connection))
    |> where([aa, mc], mc.user_id == ^user_id)
    |> Repo.all()
  end
  
  @spec get_ad_account!(User.t(), binary()) :: AdAccount.t()
  def get_ad_account!(%User{id: user_id}, ad_account_id) do
    AdAccount
    |> join(:inner, [aa], mc in assoc(aa, :meta_connection))
    |> where([aa, mc], mc.user_id == ^user_id and aa.id == ^ad_account_id)
    |> Repo.one!()
  end
  
  # Campaign queries
  
  @spec list_campaigns(User.t(), keyword()) :: list(Campaign.t())
  def list_campaigns(%User{} = user, opts \\ []) do
    Campaign
    |> scope(user)
    |> apply_campaign_filters(opts)
    |> Repo.all()
  end
  
  @spec get_campaign!(User.t(), binary()) :: Campaign.t()
  def get_campaign!(%User{} = user, campaign_id) do
    Campaign
    |> scope(user)
    |> where([c], c.id == ^campaign_id)
    |> Repo.one!()
  end
  
  defp apply_campaign_filters(query, opts) do
    Enum.reduce(opts, query, fn
      {:ad_account_id, ad_account_id}, query ->
        where(query, [c], c.ad_account_id == ^ad_account_id)
      
      {:status, status}, query ->
        where(query, [c], c.status == ^status)
      
      _, query ->
        query
    end)
  end
end
```

**TDD Workflow for Day 8:**

1. **RED**: Write two-user isolation tests FIRST (MANDATORY)
   - Test: User A cannot access User B's campaigns
   - Test: User A cannot access User B's ad accounts
   - Test: `scope/2` correctly joins through meta_connection
   - Run tests, watch them FAIL

2. **GREEN**: Implement Ads context with scope/2
   - Define all schemas
   - Implement `scope/2` helper
   - Implement all query functions using `scope/2`
   - Run tests, watch them PASS

3. **REFACTOR**: Extract filters
   - Private `apply_campaign_filters/2`
   - Consistent scope usage across all functions

**Tests:**

```elixir
# test/ad_butler/ads_test.exs
defmodule AdButler.AdsTest do
  use AdButler.DataCase, async: true
  
  alias AdButler.Ads
  
  describe "list_campaigns/2 (tenant isolation)" do
    test "user A cannot see user B's campaigns" do
      user_a = insert(:user)
      user_b = insert(:user)
      
      conn_a = insert(:meta_connection, user: user_a)
      conn_b = insert(:meta_connection, user: user_b)
      
      aa_a = insert(:ad_account, meta_connection: conn_a)
      aa_b = insert(:ad_account, meta_connection: conn_b)
      
      campaign_a = insert(:campaign, ad_account: aa_a)
      campaign_b = insert(:campaign, ad_account: aa_b)
      
      campaigns_for_a = Ads.list_campaigns(user_a)
      
      assert length(campaigns_for_a) == 1
      assert hd(campaigns_for_a).id == campaign_a.id
      refute Enum.any?(campaigns_for_a, &(&1.id == campaign_b.id))
    end
  end
  
  describe "get_campaign!/2 (tenant isolation)" do
    test "user A cannot fetch user B's campaign by ID" do
      user_a = insert(:user)
      user_b = insert(:user)
      
      conn_b = insert(:meta_connection, user: user_b)
      aa_b = insert(:ad_account, meta_connection: conn_b)
      campaign_b = insert(:campaign, ad_account: aa_b)
      
      assert_raise Ecto.NoResultsError, fn ->
        Ads.get_campaign!(user_a, campaign_b.id)
      end
    end
  end
end
```

**Acceptance Criteria:**
- [ ] All schemas defined with correct associations
- [ ] `scope/2` implemented and used in ALL user-facing queries
- [ ] Two-user isolation tests pass for EVERY query function
- [ ] 100% test coverage for Ads context
- [ ] `@spec` on all public functions

**Quality Gates:**
```bash
mix test test/ad_butler/ads_test.exs
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict lib/ad_butler/ads/
mix test --cover  # Ads context coverage = 100%
```

**Verification:**
```bash
# Manual isolation test in IEx:
iex -S mix
user_a = AdButler.Repo.get_by!(AdButler.Accounts.User, email: "a@test.com")
user_b = AdButler.Repo.get_by!(AdButler.Accounts.User, email: "b@test.com")
AdButler.Ads.list_campaigns(user_a) |> IO.inspect(label: "User A campaigns")
AdButler.Ads.list_campaigns(user_b) |> IO.inspect(label: "User B campaigns")
```

**Principle Checkpoints:**
- ✅ Section 6: **scope/2 MANDATORY** for tenant isolation (CRITICAL SECURITY)
- ✅ Section 6: Two-user tests for all queries
- ✅ Section 1: TDD (tests define security boundary)

---

### Day 9: Broadway MetadataSyncPipeline

**Deliverables:**
1. Create `lib/ad_butler/sync/metadata_pipeline.ex` using Broadway
2. Consumer: RabbitMQ queue `ad_butler.sync.metadata`
3. Process messages: fetch campaigns/ad_sets/ads for ad_account_id
4. Batch Meta API calls (50 per batch using `batch_request/2`)
5. Upsert to DB using `Repo.insert/2` with `on_conflict: :replace_all`
6. Handle failures: reject message to DLQ on repeated errors

**Implementation:**

```elixir
# lib/ad_butler/sync/metadata_pipeline.ex
defmodule AdButler.Sync.MetadataPipeline do
  use Broadway
  
  alias Broadway.Message
  alias AdButler.{Ads, Meta, Repo}
  
  require Logger
  
  def start_link(_opts) do
    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: [
        module: {BroadwayRabbitMQ.Producer,
          queue: "ad_butler.sync.metadata",
          connection: rabbitmq_url(),
          qos: [prefetch_count: 10]
        },
        concurrency: 1
      ],
      processors: [
        default: [concurrency: 5, partition_by: &partition_by_ad_account/1]
      ],
      batchers: [
        meta_api: [concurrency: 2, batch_size: 5, batch_timeout: 2000]
      ]
    )
  end
  
  @impl true
  def handle_message(:default, %Message{data: data} = message, _context) do
    with {:ok, payload} <- Jason.decode(data),
         {:ok, ad_account} <- fetch_ad_account(payload["ad_account_id"]) do
      
      message
      |> Message.put_data(ad_account)
      |> Message.put_batcher(:meta_api)
    else
      {:error, reason} ->
        Logger.error("Failed to process message", reason: inspect(reason), data: data)
        Message.failed(message, reason)
    end
  end
  
  @impl true
  def handle_batch(:meta_api, messages, _batch_info, _context) do
    # Group messages by meta_connection to batch API calls
    messages
    |> Enum.group_by(fn msg -> msg.data.meta_connection_id end)
    |> Enum.flat_map(fn {_connection_id, msgs} ->
      sync_ad_accounts(msgs)
    end)
  end
  
  defp sync_ad_accounts([%Message{data: ad_account} | _] = messages) do
    connection = Repo.get!(AdButler.Accounts.MetaConnection, ad_account.meta_connection_id)
    
    # Fetch campaigns, ad_sets, ads in batch
    with {:ok, campaigns} <- Meta.Client.list_campaigns(connection.access_token, ad_account.meta_id),
         {:ok, ad_sets} <- Meta.Client.list_ad_sets(connection.access_token, ad_account.meta_id),
         {:ok, ads} <- Meta.Client.list_ads(connection.access_token, ad_account.meta_id) do
      
      upsert_campaigns(ad_account, campaigns)
      upsert_ad_sets(ad_account, ad_sets)
      upsert_ads(ad_account, ads)
      
      Enum.map(messages, &Message.ack(&1))
    else
      {:error, :rate_limit_exceeded} ->
        Logger.warning("Rate limit hit for ad_account", ad_account_id: ad_account.id)
        Enum.map(messages, &Message.failed(&1, :rate_limit))
      
      {:error, reason} ->
        Logger.error("Sync failed", reason: inspect(reason), ad_account_id: ad_account.id)
        Enum.map(messages, &Message.failed(&1, reason))
    end
  end
  
  defp upsert_campaigns(ad_account, campaigns) do
    Enum.each(campaigns, fn campaign ->
      %Ads.Campaign{}
      |> Ads.Campaign.changeset(%{
        ad_account_id: ad_account.id,
        meta_id: campaign["id"],
        name: campaign["name"],
        status: campaign["status"],
        objective: campaign["objective"],
        daily_budget_cents: parse_budget(campaign["daily_budget"]),
        lifetime_budget_cents: parse_budget(campaign["lifetime_budget"]),
        raw_jsonb: campaign
      })
      |> Repo.insert(on_conflict: :replace_all, conflict_target: [:ad_account_id, :meta_id])
    end)
  end
  
  defp upsert_ad_sets(ad_account, ad_sets) do
    # Similar to upsert_campaigns
    # Implementation details...
  end
  
  defp upsert_ads(ad_account, ads) do
    # Similar to upsert_campaigns
    # Implementation details...
  end
  
  defp parse_budget(nil), do: nil
  defp parse_budget(value) when is_binary(value), do: String.to_integer(value)
  defp parse_budget(value) when is_integer(value), do: value
  
  defp partition_by_ad_account(%Message{data: %{"ad_account_id" => id}}), do: id
  defp partition_by_ad_account(%Message{data: %AdButler.Ads.AdAccount{id: id}}), do: id
  
  defp fetch_ad_account(ad_account_id) do
    case Repo.get(Ads.AdAccount, ad_account_id) do
      nil -> {:error, :not_found}
      ad_account -> {:ok, ad_account}
    end
  end
  
  defp rabbitmq_url, do: Application.fetch_env!(:ad_butler, :rabbitmq)[:url]
end

# lib/ad_butler/application.ex (add to supervision tree)
def start(_type, _args) do
  children = [
    AdButler.Repo,
    {Oban, Application.fetch_env!(:ad_butler, Oban)},
    AdButler.Sync.Scheduler,
    AdButler.Sync.MetadataPipeline,  # <--- Add Broadway pipeline
    AdButlerWeb.Endpoint,
    {Phoenix.PubSub, name: AdButler.PubSub}
  ]
  
  # ... rest
end
```

**TDD Workflow for Day 9:**

1. **RED**: Write Broadway pipeline tests
   - Test: Message processing fetches ad account
   - Test: Batch handler calls Meta.Client (mocked)
   - Test: Upserts campaigns/ad_sets/ads to DB
   - Test: Rate limit errors requeue message
   - Run integration test with test RabbitMQ, watch it FAIL

2. **GREEN**: Implement MetadataPipeline
   - Configure Broadway with RabbitMQ producer
   - Implement `handle_message/3` and `handle_batch/4`
   - Mock Meta.Client in tests
   - Run tests, watch them PASS

3. **REFACTOR**: Extract upsert logic
   - Private `upsert_campaigns/2`, `upsert_ad_sets/2`, `upsert_ads/2`
   - Consistent error handling

**Acceptance Criteria:**
- [ ] Pipeline starts and consumes from RabbitMQ
- [ ] Messages processed and acked (test with fake messages)
- [ ] Meta API calls batched efficiently (verify in logs)
- [ ] Data upserted to DB (verify rows in test DB)
- [ ] Rate limit errors handled gracefully
- [ ] 100% test coverage with mocked Meta.Client

**Quality Gates:**
```bash
docker run -d --name rabbitmq-test -p 5672:5672 rabbitmq:3.13-alpine
RABBITMQ_URL=amqp://localhost:5672 mix test test/ad_butler/sync/metadata_pipeline_test.exs
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict lib/ad_butler/sync/
docker stop rabbitmq-test && docker rm rabbitmq-test
```

**Verification:**
```bash
# Publish test message:
RABBITMQ_URL=amqp://localhost:5672 mix run -e '
  {:ok, conn} = AMQP.Connection.open("amqp://localhost:5672")
  {:ok, channel} = AMQP.Channel.open(conn)
  AMQP.Basic.publish(channel, "ad_butler.sync.fanout", "", "{\"ad_account_id\":\"test_id\"}")
  AMQP.Channel.close(channel)
  AMQP.Connection.close(conn)
'

# Watch logs for processing:
tail -f log/dev.log | grep MetadataPipeline
```

**Principle Checkpoints:**
- ✅ Section 9: Mock Meta.Client in pipeline tests (behaviour)
- ✅ Section 10: Structured logging for sync events
- ✅ Section 5: Tagged tuples for errors

---

### Day 10: Integration Testing & DLQ Replay

**Deliverables:**
1. End-to-end integration test: OAuth → Sync → Database
2. DLQ replay mechanism: `mix task for replaying failed messages
3. Rate-limit backoff verification
4. Monitoring: Count messages in DLQ, log rate-limit events

**Implementation:**

```elixir
# test/integration/sync_pipeline_test.exs
defmodule AdButler.Integration.SyncPipelineTest do
  use AdButler.DataCase, async: false  # Integration tests not async
  
  alias AdButler.{Accounts, Ads, Sync}
  
  @moduletag :integration
  
  setup do
    # Setup test RabbitMQ connection
    # Mock Meta.Client for integration tests
    :ok
  end
  
  test "full sync flow: connection -> ad accounts -> campaigns" do
    # 1. Create user and meta_connection
    user = insert(:user)
    connection = insert(:meta_connection, user: user, access_token: "test_token")
    
    # 2. Mock Meta.Client to return ad accounts
    expect(Meta.ClientMock, :list_ad_accounts, fn _token ->
      {:ok, [%{"id" => "act_123", "name" => "Test Account", "currency" => "USD", "timezone_name" => "America/Los_Angeles", "account_status" => "ACTIVE"}]}
    end)
    
    # 3. Trigger sync
    Sync.Scheduler.schedule_sync_for_connection(connection)
    
    # 4. Wait for Oban worker to complete
    :timer.sleep(1000)
    
    # 5. Verify ad account created
    ad_accounts = Ads.list_ad_accounts(user)
    assert length(ad_accounts) == 1
    assert hd(ad_accounts).meta_id == "act_123"
    
    # 6. Mock campaigns API
    expect(Meta.ClientMock, :list_campaigns, fn _token, _account_id ->
      {:ok, [%{"id" => "camp_456", "name" => "Test Campaign", "status" => "ACTIVE", "objective" => "OUTCOME_TRAFFIC"}]}
    end)
    
    # 7. Verify Broadway consumed message and upserted campaign
    :timer.sleep(2000)
    campaigns = Ads.list_campaigns(user)
    assert length(campaigns) == 1
    assert hd(campaigns).meta_id == "camp_456"
  end
end

# lib/mix/tasks/ad_butler.replay_dlq.ex
defmodule Mix.Tasks.AdButler.ReplayDlq do
  @moduledoc """
  Replays messages from DLQ back to main queue.
  
  Usage:
    mix ad_butler.replay_dlq
    mix ad_butler.replay_dlq --limit 100
  """
  
  use Mix.Task
  require Logger
  
  @shortdoc "Replay DLQ messages back to main queue"
  
  def run(args) do
    Mix.Task.run("app.start")
    
    {opts, _, _} = OptionParser.parse(args, strict: [limit: :integer])
    limit = Keyword.get(opts, :limit, :infinity)
    
    {:ok, conn} = AMQP.Connection.open(rabbitmq_url())
    {:ok, channel} = AMQP.Channel.open(conn)
    
    dlq = "ad_butler.sync.metadata.dlq"
    main_exchange = "ad_butler.sync.fanout"
    
    replayed = replay_messages(channel, dlq, main_exchange, limit)
    
    Logger.info("DLQ replay complete", replayed: replayed)
    
    AMQP.Channel.close(channel)
    AMQP.Connection.close(conn)
  end
  
  defp replay_messages(channel, dlq, exchange, limit) do
    replay_messages(channel, dlq, exchange, limit, 0)
  end
  
  defp replay_messages(_channel, _dlq, _exchange, limit, count) when count >= limit do
    count
  end
  
  defp replay_messages(channel, dlq, exchange, limit, count) do
    case AMQP.Basic.get(channel, dlq, no_ack: false) do
      {:ok, payload, meta} ->
        AMQP.Basic.publish(channel, exchange, "", payload, persistent: true)
        AMQP.Basic.ack(channel, meta.delivery_tag)
        
        replay_messages(channel, dlq, exchange, limit, count + 1)
      
      {:empty, _} ->
        count
    end
  end
  
  defp rabbitmq_url, do: Application.fetch_env!(:ad_butler, :rabbitmq)[:url]
end
```

**TDD Workflow for Day 10:**

1. **RED**: Write integration tests
   - Test: Full sync flow from connection to DB
   - Test: DLQ replay task moves messages
   - Test: Rate-limit backoff delays processing
   - Run tests, watch them FAIL (or timeout)

2. **GREEN**: Fix integration issues
   - Ensure Broadway pipeline processes messages
   - Verify DLQ replay task works
   - Run tests, watch them PASS

3. **REFACTOR**: Add monitoring
   - Count DLQ messages
   - Log rate-limit events

**Acceptance Criteria:**
- [ ] Integration test covers full sync flow
- [ ] DLQ replay task moves messages back to main queue
- [ ] Rate-limit backoff verified in tests
- [ ] Monitoring logs capture key events
- [ ] No flaky tests (deterministic test setup)

**Quality Gates:**
```bash
docker run -d --name rabbitmq-test -p 5672:5672 rabbitmq:3.13-alpine
RABBITMQ_URL=amqp://localhost:5672 mix test --only integration
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict lib/mix/tasks/
docker stop rabbitmq-test && docker rm rabbitmq-test
```

**Verification:**
```bash
# Seed DLQ with test messages:
mix run -e '...'  # Publish to DLQ

# Replay:
mix ad_butler.replay_dlq --limit 10

# Verify messages moved:
docker exec rabbitmq-test rabbitmqctl list_queues name messages
```

**Principle Checkpoints:**
- ✅ Section 1: Integration tests verify end-to-end behavior
- ✅ Section 10: Structured logging for monitoring

---

## Week 3: LiveView UI & Deployment (Days 11-15)

### Day 11: Authentication & Dashboard LiveView

**Deliverables:**
1. Add `current_user` plug using session `user_id`
2. Create `lib/ad_butler_web/live/dashboard_live.ex`
3. Display: user email, connected ad accounts count
4. Mobile-first layout with custom Tailwind components (NO DaisyUI)
5. Logout button

**Implementation:**

```elixir
# lib/ad_butler_web/plugs/load_current_user.ex
defmodule AdButlerWeb.Plugs.LoadCurrentUser do
  import Plug.Conn
  
  alias AdButler.Accounts
  
  def init(opts), do: opts
  
  def call(conn, _opts) do
    case get_session(conn, :user_id) do
      nil ->
        assign(conn, :current_user, nil)
      
      user_id ->
        user = Accounts.get_user!(user_id)
        assign(conn, :current_user, user)
    end
  end
end

# lib/ad_butler_web/router.ex
pipeline :authenticated do
  plug :browser
  plug AdButlerWeb.Plugs.LoadCurrentUser
  plug :require_authentication
end

defp require_authentication(conn, _opts) do
  if conn.assigns[:current_user] do
    conn
  else
    conn
    |> Phoenix.Controller.put_flash(:error, "You must log in to access this page")
    |> Phoenix.Controller.redirect(to: ~p"/")
    |> Plug.Conn.halt()
  end
end

# lib/ad_butler_web/live/dashboard_live.ex
defmodule AdButlerWeb.DashboardLive do
  use AdButlerWeb, :live_view
  
  alias AdButler.Ads
  
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    ad_accounts = Ads.list_ad_accounts(user)
    
    {:ok, assign(socket,
      user: user,
      ad_accounts: ad_accounts,
      ad_account_count: length(ad_accounts)
    )}
  end
  
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="max-w-4xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <%!-- Header --%>
        <div class="flex items-center justify-between mb-8">
          <div>
            <h1 class="text-3xl font-bold text-gray-900">Dashboard</h1>
            <p class="mt-1 text-sm text-gray-600">{@user.email}</p>
          </div>
          
          <button
            phx-click="logout"
            class="px-4 py-2 text-sm font-medium text-white bg-red-600 rounded-lg hover:bg-red-700 focus:outline-none focus:ring-2 focus:ring-red-500"
          >
            Logout
          </button>
        </div>
        
        <%!-- Stats Card --%>
        <div class="bg-white rounded-lg shadow-sm border border-gray-200 p-6 mb-8">
          <div class="flex items-center">
            <div class="flex-1">
              <p class="text-sm font-medium text-gray-600">Connected Ad Accounts</p>
              <p class="mt-2 text-4xl font-bold text-gray-900">{@ad_account_count}</p>
            </div>
            
            <.icon name="hero-chart-bar" class="w-12 h-12 text-blue-500" />
          </div>
        </div>
        
        <%!-- Ad Accounts List --%>
        <div class="space-y-4">
          <h2 class="text-xl font-semibold text-gray-900">Ad Accounts</h2>
          
          <%= if @ad_account_count == 0 do %>
            <div class="bg-gray-50 rounded-lg border-2 border-dashed border-gray-300 p-8 text-center">
              <.icon name="hero-inbox" class="mx-auto w-12 h-12 text-gray-400" />
              <p class="mt-4 text-sm text-gray-600">No ad accounts connected yet.</p>
              <a
                href={~p"/auth/meta"}
                class="mt-4 inline-block px-4 py-2 text-sm font-medium text-white bg-blue-600 rounded-lg hover:bg-blue-700"
              >
                Connect Meta Account
              </a>
            </div>
          <% else %>
            <div class="space-y-3">
              <div :for={account <- @ad_accounts} class="bg-white rounded-lg shadow-sm border border-gray-200 p-4 hover:shadow-md transition-shadow">
                <div class="flex items-center justify-between">
                  <div>
                    <h3 class="font-medium text-gray-900">{account.name}</h3>
                    <p class="mt-1 text-sm text-gray-600">{account.currency} • {account.timezone_name}</p>
                  </div>
                  
                  <span class={[
                    "px-3 py-1 text-xs font-medium rounded-full",
                    if(account.status == "ACTIVE", do: "bg-green-100 text-green-800", else: "bg-gray-100 text-gray-800")
                  ]}>
                    {account.status}
                  </span>
                </div>
              </div>
            </div>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end
  
  def handle_event("logout", _params, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "Logged out successfully")
     |> redirect(to: ~p"/")}
  end
end
```

**TDD Workflow for Day 11:**

1. **RED**: Write LiveView tests
   - Test: Dashboard shows user email
   - Test: Dashboard shows ad account count
   - Test: Empty state when no ad accounts
   - Test: Logout redirects to home
   - Run tests, watch them FAIL

2. **GREEN**: Implement DashboardLive
   - Mount loads user's ad accounts (scoped via Ads.list_ad_accounts/1)
   - Render displays accounts with mobile-first Tailwind
   - Run tests, watch them PASS

3. **REFACTOR**: Extract components
   - Stats card component
   - Ad account list item component

**Acceptance Criteria:**
- [ ] Dashboard displays user info
- [ ] Ad accounts listed correctly (scoped to user)
- [ ] Mobile-responsive layout (test on small viewport)
- [ ] Logout works
- [ ] 100% test coverage for LiveView

**Quality Gates:**
```bash
mix test test/ad_butler_web/live/dashboard_live_test.exs
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict lib/ad_butler_web/live/
mix test --cover
```

**Verification:**
```bash
# Manual UI test:
iex -S mix phx.server
# Navigate to localhost:4000/dashboard
# Verify mobile layout:  # Resize browser to 375px width
```

**Principle Checkpoints:**
- ✅ Section 21: Custom Tailwind components (NO DaisyUI)
- ✅ Section 21: Mobile-first design
- ✅ Section 6: scope/2 used (Ads.list_ad_accounts/1 scopes to user)

---

### Day 12: Campaigns List LiveView

**Deliverables:**
1. Create `lib/ad_butler_web/live/campaigns_live.ex`
2. Display campaigns table: name, status, objective, budget
3. Filter by ad_account_id (dropdown)
4. Filter by status (ACTIVE | PAUSED | DELETED)
5. Mobile-first responsive table

**Implementation:**

```elixir
# lib/ad_butler_web/live/campaigns_live.ex
defmodule AdButlerWeb.CampaignsLive do
  use AdButlerWeb, :live_view
  
  alias AdButler.Ads
  
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    ad_accounts = Ads.list_ad_accounts(user)
    campaigns = Ads.list_campaigns(user)
    
    {:ok, assign(socket,
      user: user,
      ad_accounts: ad_accounts,
      campaigns: campaigns,
      selected_ad_account: nil,
      selected_status: nil
    )}
  end
  
  def handle_event("filter", %{"ad_account_id" => ad_account_id, "status" => status}, socket) do
    user = socket.assigns.current_user
    
    filters = [
      {:ad_account_id, parse_filter(ad_account_id)},
      {:status, parse_filter(status)}
    ]
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    
    campaigns = Ads.list_campaigns(user, filters)
    
    {:noreply, assign(socket,
      campaigns: campaigns,
      selected_ad_account: ad_account_id,
      selected_status: status
    )}
  end
  
  defp parse_filter(""), do: nil
  defp parse_filter(value), do: value
end
```

**TDD Workflow for Day 12:**

1. **RED**: Write LiveView tests
   - Test: Campaigns list displays correctly
   - Test: Filter by ad_account_id updates list
   - Test: Filter by status updates list
   - Test: User A cannot see User B's campaigns (tenant isolation)
   - Run tests, watch them FAIL

2. **GREEN**: Implement CampaignsLive
   - Mount loads campaigns scoped to user
   - Filter event updates campaigns with filters
   - Run tests, watch them PASS

3. **REFACTOR**: Extract components
   - Filter form component
   - Campaign table component

**Acceptance Criteria:**
- [ ] Campaigns display correctly
- [ ] Filters work (ad_account, status)
- [ ] Mobile-responsive table
- [ ] Tenant isolation verified in tests
- [ ] 100% coverage

**Quality Gates:**
```bash
mix test test/ad_butler_web/live/campaigns_live_test.exs
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix test --cover
```

**Principle Checkpoints:**
- ✅ Section 21: Mobile-first Tailwind
- ✅ Section 6: scope/2 (Ads.list_campaigns/2 scopes to user)

---

### Day 13: Error Handling Polish

**Deliverables:**
1. Graceful degradation for Meta API errors
2. User-friendly error messages in LiveView
3. Flash messages for OAuth errors
4. Sentry integration for error tracking (optional)

**TDD Workflow:**
- Test error scenarios (API timeout, 401, 429)
- Verify user sees helpful messages
- Verify errors logged to structured logger

**Principle Checkpoints:**
- ✅ Section 10: Structured logging
- ✅ Section 5: Tagged tuple errors, no raises

---

### Day 14: LLM Usage Telemetry Plumbing

**Deliverables:**
1. Create `:telemetry` handler for `[:llm, :request, :stop]` events
2. Handler writes to `llm_usage` table
3. Encrypt sensitive metadata with Cloak
4. Verify cost calculation logic

**TDD Workflow:**
- Test telemetry handler writes llm_usage row
- Test cost calculation (input + output + cached tokens)
- Mock telemetry events in tests

**Principle Checkpoints:**
- ✅ Section 11: Cloak for sensitive metadata
- ✅ Section 10: Structured logging

---

### Day 15: Staging Deploy & Meta App Review

**Deliverables:**
1. Deploy to staging (Fly.io or similar)
2. Verify OAuth flow works in production
3. Verify sync pipeline runs
4. Submit Meta App Review for production app_id

**Verification:**
```bash
# Deploy to staging:
fly deploy --config fly.staging.toml

# Verify health:
curl https://adbutler-staging.fly.dev/health

# Test OAuth:
# Navigate to staging URL, complete OAuth
```

**Principle Checkpoints:**
- ✅ Section 11: Secrets from environment (never compiled)

---

## Critical Patterns & Specifications

### Tenant Isolation Pattern (scope/2)

**MANDATORY:** Every query in tenant-scoped contexts MUST use `scope/2` to prevent data leaks.

```elixir
defmodule AdButler.Ads do
  import Ecto.Query
  alias AdButler.Accounts.User
  
  # The core security boundary
  defp scope(queryable, %User{id: user_id}) do
    from q in queryable,
      join: aa in AdAccount,
        on: q.ad_account_id == aa.id,
      join: mc in assoc(aa, :meta_connection),
      where: mc.user_id == ^user_id
  end
  
  # All public functions use scope/2
  def list_ads(%User{} = user, opts \\ []) do
    Ad
    |> scope(user)
    |> apply_filters(opts)
    |> Repo.all()
  end
end
```

**Mandatory Test Pattern:**

```elixir
test "user A cannot see user B's ads" do
  user_a = insert(:user)
  user_b = insert(:user)
  
  ad_a = insert(:ad, user: user_a)
  ad_b = insert(:ad, user: user_b)
  
  ads_for_a = Ads.list_ads(user_a)
  assert hd(ads_for_a).id == ad_a.id
  refute Enum.any?(ads_for_a, &(&1.id == ad_b.id))
end
```

**See:** `/memories/session/tenant-isolation-spec.md` for complete pattern documentation.

---

## Verification Checklist

### Day 1-5 (Week 1)
- [ ] All migrations run successfully
- [ ] Tokens encrypted/decrypted correctly (Cloak verification)
- [ ] OAuth flow completes end-to-end
- [ ] Meta API calls return data (mocked in tests)
- [ ] Rate limits tracked in ETS
- [ ] Oban jobs enqueue and execute
- [ ] Tenant isolation tests pass
- [ ] `mix precommit` passes with 100% coverage

### Day 6-10 (Week 2)
- [ ] RabbitMQ topology created
- [ ] Broadway pipeline consumes messages
- [ ] Ads context queries scoped correctly (scope/2 tests pass)
- [ ] Sync scheduler enqueues tasks
- [ ] DLQ replay works
- [ ] Integration tests pass
- [ ] `mix precommit` passes with 100% coverage

### Day 11-15 (Week 3)
- [ ] Login flow works
- [ ] Ad list renders correctly (mobile-first responsive)
- [ ] All error paths graceful
- [ ] LLM telemetry handler attached
- [ ] Staging deploy successful
- [ ] Meta App Review submitted
- [ ] `mix precommit` passes with 100% coverage

---

## Reference Materials

**Session Memory Specifications:**
- `/memories/session/plan.md` — 15-day breakdown with parallel work streams
- `/memories/session/schema-spec.md` — Complete database schemas and migrations
- `/memories/session/sync-spec.md` — Meta.Client and Broadway pipeline specs
- `/memories/session/tenant-isolation-spec.md` — Critical scope/2 security pattern

**Project Documentation:**
- `docs/plan/decisions/0001-skip-rls-for-mvp.md` — scope/2 discipline
- `docs/plan/decisions/0003-claude-via-reqllm.md` — LLM integration
- `CLAUDE.md` — coding principles and agent-facing development standards

---

## Daily Workflow Template

**Before starting any day:**
```bash
git checkout -b day-N-description
```

**During implementation (for each feature):**
1. **RED**: Write test first, watch it fail
2. **GREEN**: Write minimal code to pass
3. **REFACTOR**: Clean up with passing tests

**Before committing:**
```bash
mix precommit  # MUST pass before commit
git add .
git commit -m "Day N: Feature description"
```

**End of day:**
```bash
mix precommit  # Final check
git push origin day-N-description
# Open PR with "Day N Complete" checklist
```

---

## Success Criteria for v0.1

**Functional:**
- ✅ User can OAuth with Meta
- ✅ User's ad accounts sync automatically
- ✅ User can view campaigns in LiveView UI
- ✅ Token refresh happens automatically (Oban)
- ✅ LLM cost tracking plumbing ready (telemetry handler)

**Quality:**
- ✅ 100% test coverage on all contexts
- ✅ Tenant isolation verified (two-user tests pass)
- ✅ `mix precommit` passes on all code
- ✅ No warnings or Credo violations
- ✅ Staging deployment successful

**Security:**
- ✅ Tokens encrypted at rest (Cloak)
- ✅ Secrets from environment only
- ✅ scope/2 enforced on all user queries
- ✅ OAuth state verified
- ✅ No secrets in logs

---

## Next Steps After v0.1

**v0.2 (Weeks 4-6):** Analytics pipeline, Contex charts, performance data  
**v0.3 (Weeks 7-11):** Claude chat, embeddings, findings analysis  

**For v0.1 → v0.2 transition:**
- Partition `ad_insights` table by month
- Add analytics Broadway pipeline
- Implement chart rendering with Contex

---

**Plan complete! Ready for /phx:plan and /phx:work with claude-elixir-phoenix plugin.** 🚀

---

## Architectural Decisions Reference

- **D0001**: RLS skipped, using scope/2 (discipline-based isolation)
- **D0002**: Native Postgres partitioning (no TimescaleDB in v0.1)
- **D0003**: Claude via jido_ai/ReqLLM (ready for v0.3)
- **D0004**: Server-rendered charts (Contex in v0.2+)

---

## Iron Laws (Non-Negotiable)

1. **Money fields**: Always use `_cents` (bigint), never `:float`
2. **Tenant queries**: Always use `scope/2` before any filtering
3. **User input**: Never `String.to_atom/1` on user input
4. **TDD**: Test written before implementation
5. **Scheduled work**: Use Oban, not GenServers with timers
6. **Error handling**: Return tagged tuples, raise only for programmer errors

---

## Next Actions

1. **Start Day 1**: Create database migrations
2. **Setup environment**: Meta dev app, RabbitMQ, env vars
3. **Review plan**: Adjust timeline or scope if needed

Use claude-elixir-phoenix plugin commands:
- `/phx:plan "Day 1: Database schema migrations"`
- `/phx:work .claude/plans/{plan}/plan.md`
- `/phx:verify` after each day
- `/phx:review` after each major component
