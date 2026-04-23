# Week 2 — Days 6–10: Sync Pipeline & Ads Context

**Feature:** RabbitMQ topology, Ads context with tenant isolation, Sync.Scheduler, FetchAdAccountsWorker, Broadway MetadataSyncPipeline, DLQ replay task.  
**Branch:** `week-02-sync-pipeline-ads-context`  
**Sprint ref:** `docs/plan/sprint_plan/plan-adButlerV01Foundation.prompt.md` — Days 6–10  
**Depth:** Standard

---

## Context

Week 1 delivered: database migrations, Accounts context + Cloak encryption, Meta OAuth flow, Meta.Client with ETS rate-limit ledger, TokenRefreshWorker + SweepWorker, and all security hardening.

Week 2 builds the sync pipeline: RabbitMQ topology, the Ads context (all five domain schemas + tenant-isolated queries), a Sync.Scheduler that kicks off ad-account discovery at startup, a `FetchAdAccountsWorker` Oban job that writes ad accounts and publishes metadata sync tasks, and a Broadway `MetadataSyncPipeline` that consumes those tasks and upserts campaigns/ad_sets/ads. Day 10 adds integration testing and a DLQ replay mix task.

**Key corrections vs sprint plan:**
1. **Contexts own Repo** — Sprint plan's workers call `Repo.insert` directly. This plan adds `upsert_*` functions to the Ads context; workers call those.
2. **AMQP connection pooling** — Sprint plan opens a new AMQP connection per-message in worker code. This plan introduces a `Messaging.Publisher` GenServer that owns one supervised channel.
3. **Broadway in test env** — Sprint plan relies on a Docker RabbitMQ for unit tests. This plan configures Broadway with `Broadway.DummyProducer` in test env; only the integration test requires a live broker.
4. **No `Process.sleep` in tests** — Integration test uses `Oban.Testing.perform_job/2` instead.
5. **Phase order** — Day 8 (Ads context) moved before Days 7 and 9 because workers and pipeline both depend on Ads schemas and upsert functions.

**Parallel opportunities:**
- Phase 1 (RabbitMQ topology) and Phase 2 (Ads context) are independent — can run concurrently.
- Phase 4 (MetadataPipeline) can begin once Phase 2 (Ads context upserts) and Phase 1 (topology) complete.

---

## Phase 1 — Dependencies + RabbitMQ Topology (Day 6)

> Sets up AMQP infrastructure. No dependency on Ads context.

- [x] [otp] Add `{:broadway_rabbitmq, "~> 0.8"}` to `mix.exs` deps; run `mix deps.get`
  - `broadway_rabbitmq` pulls in `amqp` transitively — no need to list `amqp` separately
  - Verify with `mix deps | grep broadway`

- [x] [otp] Add RabbitMQ config to `config/runtime.exs` (prod + dev blocks):
  ```elixir
  config :ad_butler, :rabbitmq,
    url: System.fetch_env!("RABBITMQ_URL")
  ```
  Add `RABBITMQ_URL` to test config with a static localhost value so topology tests can run:
  ```elixir
  # config/test.exs
  config :ad_butler, :rabbitmq, url: "amqp://guest:guest@localhost:5672"
  ```

- [x] [otp] Create `lib/ad_butler/messaging/rabbitmq_topology.ex`
  - Module attributes: `@exchange "ad_butler.sync.fanout"`, `@dlq_exchange "ad_butler.sync.dlq.fanout"`, `@queue "ad_butler.sync.metadata"`, `@dlq "ad_butler.sync.metadata.dlq"`, `@dlq_ttl_ms 300_000`
  - `setup/0` — opens a temp AMQP connection; declares DLQ exchange + queue first, then main exchange + queue with dead-letter args; closes connection; returns `:ok`
    ```elixir
    AMQP.Queue.declare(channel, @queue,
      durable: true,
      arguments: [
        {"x-dead-letter-exchange", :longstr, @dlq_exchange},
        {"x-message-ttl", :long, @dlq_ttl_ms}
      ]
    )
    ```
  - Structured logging on success: `Logger.info("RabbitMQ topology ready", exchange: @exchange, queue: @queue, dlq: @dlq)`
  - `@spec setup() :: :ok | {:error, term()}`
  - Private `rabbitmq_url/0` — reads from `Application.fetch_env!/2`

- [x] [otp] Create `lib/ad_butler/messaging/publisher.ex` — supervised AMQP publisher GenServer
  - `use GenServer`; `start_link/0`; name `__MODULE__`
  - `init/1` — opens one AMQP connection + channel; stores `%{conn: conn, channel: channel}` in state
  - `handle_info({:basic_cancel, _}, state)` — log warning + reconnect
  - `handle_info({:DOWN, ...}, state)` — reconnect on channel/connection crash
  - Public `publish/2` — `GenServer.call(__MODULE__, {:publish, payload})`
  - `handle_call({:publish, payload}, _from, %{channel: channel} = state)` — `AMQP.Basic.publish(channel, @exchange, "", payload, persistent: true)`; return `{:reply, :ok, state}`
  - Private `@exchange "ad_butler.sync.fanout"`
  - `@spec publish(binary()) :: :ok | {:error, term()}`

- [x] [otp] Add `Messaging.Publisher` and `RabbitMQTopology.setup()` invocation to supervision tree in `application.ex`
  - Add `AdButler.Messaging.Publisher` to children list (after Oban, before Endpoint)
  - **Do NOT** start Publisher in test env — guard with `if config_env() != :test` in the children list so Broadway tests don't require a live broker
  - Call `AdButler.Messaging.RabbitMQTopology.setup()` inside `start/2` after `Supervisor.start_link/2` in prod/dev only:
    ```elixir
    if Application.get_env(:ad_butler, :env) != :test do
      :ok = AdButler.Messaging.RabbitMQTopology.setup()
    end
    ```
  > Actually — better design: call setup in a `Task.start_link` child so topology errors don't crash the supervisor. Log and continue; Broadway won't consume non-existent queues gracefully but won't crash.

- [x] [testing] Write `test/ad_butler/messaging/rabbitmq_topology_test.exs`
  - Tag `@moduletag :integration` — skipped in normal `mix test`, only runs with `--include integration`
  - `setup/0` verifies topology using `AMQP.Queue.declare` with passive: true (no creation) — asserts queue exists with correct arguments
  - Test: DLQ queue has `x-dead-letter-exchange` and `x-message-ttl` arguments
  - Note in test: requires Docker RabbitMQ: `docker run -d -p 5672:5672 rabbitmq:3.13-alpine`

- [x] [testing] Write `test/ad_butler/messaging/publisher_test.exs`
  - `@moduletag :integration`
  - `publish/1` success: start supervised Publisher, publish a JSON payload, assert AMQP consumer receives it from queue

---

## Phase 2 — Ads Context with scope/2 (Day 8 — moved before Day 7)

> Tenant-isolated context for all ad objects. Workers and pipeline depend on this.

### Schemas

- [x] [ecto] Create `lib/ad_butler/ads/ad_account.ex`
  - `@primary_key {:id, :binary_id, autogenerate: true}`, `@foreign_key_type :binary_id`
  - Fields: `meta_id :string`, `name :string`, `currency :string`, `timezone_name :string`, `status :string`, `last_synced_at :utc_datetime_usec`, `raw_jsonb :map`
  - `belongs_to :meta_connection, AdButler.Accounts.MetaConnection`
  - `has_many :campaigns, AdButler.Ads.Campaign`
  - `has_many :ad_sets, AdButler.Ads.AdSet`
  - `has_many :ads, AdButler.Ads.Ad`
  - `has_many :creatives, AdButler.Ads.Creative`
  - Changeset: cast + validate required `[:meta_connection_id, :meta_id, :name, :currency, :timezone_name, :status]`; `unique_constraint([:meta_connection_id, :meta_id])`

- [x] [ecto] Create `lib/ad_butler/ads/campaign.ex`
  - Fields: `meta_id :string`, `name :string`, `status :string`, `objective :string`, `daily_budget_cents :integer`, `lifetime_budget_cents :integer`, `raw_jsonb :map`
  - `belongs_to :ad_account, AdButler.Ads.AdAccount`
  - `has_many :ad_sets, AdButler.Ads.AdSet`
  - Changeset: validate required `[:ad_account_id, :meta_id, :name, :status, :objective]`; `validate_inclusion(:status, ["ACTIVE", "PAUSED", "DELETED", "ARCHIVED"])`; `unique_constraint([:ad_account_id, :meta_id])`

- [x] [ecto] Create `lib/ad_butler/ads/ad_set.ex`
  - Fields: `meta_id :string`, `name :string`, `status :string`, `daily_budget_cents :integer`, `lifetime_budget_cents :integer`, `bid_amount_cents :integer`, `targeting_jsonb :map`, `raw_jsonb :map`
  - `belongs_to :ad_account, AdButler.Ads.AdAccount`
  - `belongs_to :campaign, AdButler.Ads.Campaign`
  - Changeset: validate required `[:ad_account_id, :campaign_id, :meta_id, :name, :status]`; `unique_constraint([:ad_account_id, :meta_id])`

- [x] [ecto] Create `lib/ad_butler/ads/ad.ex`
  - Fields: `meta_id :string`, `name :string`, `status :string`, `raw_jsonb :map`
  - `belongs_to :ad_account, AdButler.Ads.AdAccount`
  - `belongs_to :ad_set, AdButler.Ads.AdSet`
  - `belongs_to :creative, AdButler.Ads.Creative`
  - Changeset: validate required `[:ad_account_id, :ad_set_id, :meta_id, :name, :status]`; `unique_constraint([:ad_account_id, :meta_id])`
  - Note: `:creative_id` may be nil (on_delete: :nilify_all in migration)

- [x] [ecto] Create `lib/ad_butler/ads/creative.ex`
  - Fields: `meta_id :string`, `name :string`, `asset_specs_jsonb :map`, `raw_jsonb :map`
  - `belongs_to :ad_account, AdButler.Ads.AdAccount`
  - Changeset: validate required `[:ad_account_id, :meta_id]`; `unique_constraint([:ad_account_id, :meta_id])`

### Context

- [x] [ecto] Create `lib/ad_butler/ads.ex` context
  - `import Ecto.Query`; alias all five schemas + `User`/`MetaConnection`/`Repo`

  **scope/2 — THE SECURITY BOUNDARY:**
  ```elixir
  # For Campaign, AdSet, Ad — scope via ad_account → meta_connection → user_id
  defp scope(queryable, %User{id: user_id}) do
    from q in queryable,
      join: aa in AdAccount, on: q.ad_account_id == aa.id,
      join: mc in MetaConnection, on: aa.meta_connection_id == mc.id,
      where: mc.user_id == ^user_id
  end
  ```
  Note: `AdAccount` uses a different join (no `ad_account_id` field — scope directly through `meta_connection`).

  **AdAccount functions:**
  - `list_ad_accounts/1` — `AdAccount |> join(:inner, [aa], mc in MetaConnection, on: aa.meta_connection_id == mc.id) |> where([aa, mc], mc.user_id == ^user_id) |> Repo.all()`
  - `get_ad_account!/2` — scoped to user, raise if not found
  - `get_ad_account_by_meta_id/2` — `Repo.get_by(AdAccount, [meta_connection_id: conn_id, meta_id: meta_id])`; internal/worker function, not user-scoped
  - `upsert_ad_account/2` — takes a `MetaConnection` struct and attrs map; builds changeset; `Repo.insert(changeset, on_conflict: {:replace, [:name, :currency, :timezone_name, :status, :last_synced_at, :raw_jsonb, :updated_at]}, conflict_target: [:meta_connection_id, :meta_id], returning: true)`

  **Campaign functions:**
  - `list_campaigns/2` — scoped; accepts `opts` for `ad_account_id:` and `status:` filters via private `apply_campaign_filters/2`
  - `get_campaign!/2` — scoped, raise if not found
  - `upsert_campaign/2` — takes `AdAccount` struct + attrs; `on_conflict: {:replace, [:name, :status, :objective, :daily_budget_cents, :lifetime_budget_cents, :raw_jsonb, :updated_at]}`, `conflict_target: [:ad_account_id, :meta_id]`

  **AdSet functions:**
  - `list_ad_sets/2` — scoped; `opts` for `ad_account_id:`, `campaign_id:`
  - `get_ad_set!/2` — scoped
  - `upsert_ad_set/2` — takes `AdAccount` + attrs; on_conflict replace relevant fields

  **Ad functions:**
  - `list_ads/2` — scoped; `opts` for `ad_account_id:`, `ad_set_id:`
  - `get_ad!/2` — scoped
  - `upsert_ad/2` — takes `AdAccount` + attrs

  **Creative functions:**
  - `upsert_creative/2` — takes `AdAccount` + attrs; `on_conflict: {:replace, [:name, :asset_specs_jsonb, :raw_jsonb, :updated_at]}`, `conflict_target: [:ad_account_id, :meta_id]`

  All public functions have `@spec`.

### Factories

- [x] [testing] Add Ads factories to `test/support/factory.ex`
  - `ad_account_factory` — valid attrs + `meta_connection: build(:meta_connection)`
  - `campaign_factory` — valid attrs + `ad_account: build(:ad_account)`
  - `ad_set_factory` — valid attrs + `campaign: build(:campaign)` + `ad_account: build(:ad_account)`
  - `ad_factory` — valid attrs + `ad_set: build(:ad_set)` + `ad_account: build(:ad_account)`
  - `creative_factory` — valid attrs + `ad_account: build(:ad_account)`

### Tests

- [x] [testing] Write `test/ad_butler/ads_test.exs` (TDD — write first)
  - **MANDATORY two-user isolation tests for every query function:**
    - `list_ad_accounts/1`: user_a sees only their accounts, not user_b's
    - `get_ad_account!/2`: raises for user_a fetching user_b's account
    - `list_campaigns/2`: user isolation
    - `get_campaign!/2`: raises on cross-tenant access
    - `list_ad_sets/2`: user isolation
    - `list_ads/2`: user isolation
  - **Upsert idempotency tests:**
    - `upsert_ad_account/2`: two calls with same `(meta_connection_id, meta_id)` → one row; second call updates name
    - `upsert_campaign/2`: idempotent on `(ad_account_id, meta_id)`
  - **Filter tests:**
    - `list_campaigns/2` with `status: "ACTIVE"` filter
    - `list_ad_sets/2` with `campaign_id:` filter

---

## Phase 3 — Sync.Scheduler + FetchAdAccountsWorker (Day 7)

> Depends on Phase 2 (Ads context). Can begin after `Ads.upsert_ad_account/2` exists.

- [x] [otp] Add `list_all_active_meta_connections/0` to `lib/ad_butler/accounts.ex`
  ```elixir
  @spec list_all_active_meta_connections() :: [MetaConnection.t()]
  def list_all_active_meta_connections do
    MetaConnection
    |> where([mc], mc.status == "active")
    |> Repo.all()
  end
  ```
  This is used by `Sync.Scheduler` — it's a system-level query (not user-scoped), so it lives in `Accounts`, not `Ads`.

- [x] [otp] Create `lib/ad_butler/sync/scheduler.ex` GenServer
  - `use GenServer`; `start_link/0`; name `__MODULE__`
  - `init/1` — `Process.send_after(self(), :schedule_all, 5_000)`; state `%{}`
  - `handle_info(:schedule_all, state)` — calls `Accounts.list_all_active_meta_connections()`, calls `schedule_sync_for_connection/1` for each; logs count
  - `schedule_sync_for_connection/1` (public) — `%{meta_connection_id: conn.id} |> FetchAdAccountsWorker.new() |> Oban.insert()`; returns `{:ok, job} | {:error, reason}`
  - Structured logging: `Logger.info("Scheduling ad account sync", connection_count: n)`
  - `@spec schedule_sync_for_connection(MetaConnection.t()) :: {:ok, Oban.Job.t()} | {:error, term()}`

- [x] [oban] Create `lib/ad_butler/workers/fetch_ad_accounts_worker.ex`
  - `use Oban.Worker, queue: :sync, max_attempts: 5`
  - `perform/1` args: `%{"meta_connection_id" => id}`
    1. `Accounts.get_meta_connection!(id)`
    2. `meta_client().list_ad_accounts(connection.access_token)`
    3. On `{:ok, accounts}`:
       - `Enum.each(accounts, fn account -> Ads.upsert_ad_account(connection, build_ad_account_attrs(account)) end)`
       - For each successfully upserted account: publish sync message via `Messaging.Publisher.publish(Jason.encode!(%{ad_account_id: account["id"], sync_type: "full"}))`
       - Log success: `Logger.info("Ad accounts fetched and synced", meta_connection_id: id, count: length(accounts))`
       - Return `:ok`
    4. On `{:error, :rate_limit_exceeded}` → `{:snooze, 60}` (Oban retries after 60s)
    5. On `{:error, :unauthorized}` → `{:cancel, "unauthorized"}` and update connection status to "revoked" via `Accounts.update_meta_connection`
    6. On `{:error, reason}` → `{:error, reason}` (Oban retry)
  - Private `build_ad_account_attrs/1` — maps Meta API response fields to Ads schema attrs:
    ```elixir
    %{
      meta_id: account["id"],
      name: account["name"],
      currency: account["currency"],
      timezone_name: account["timezone_name"],
      status: account["account_status"] || account["status"],
      last_synced_at: DateTime.utc_now(),
      raw_jsonb: account
    }
    ```
  - Private `meta_client/0` — `Application.get_env(:ad_butler, :meta_client, AdButler.Meta.Client)`
  - **No direct `Repo` calls** — all DB writes go through `Ads.upsert_ad_account/2`
  - `@spec` on `perform/1`

- [x] [otp] Add `AdButler.Sync.Scheduler` to supervision tree in `application.ex`
  - After Oban, before `AdButlerWeb.Endpoint`
  - Use a guard: don't start in test env (Scheduler's 5s boot trigger would interfere with tests)
    ```elixir
    if Application.get_env(:ad_butler, :env) not in [:test] do
      [AdButler.Sync.Scheduler]
    else
      []
    end
    ```
    Or more idiomatically: add `config :ad_butler, sync_scheduler_enabled: true` in config.exs and `false` in test.exs.

- [x] [testing] Write `test/ad_butler/sync/scheduler_test.exs`
  - `use Oban.Testing, repo: AdButler.Repo`
  - `schedule_sync_for_connection/1`: creates a `meta_connection` via factory; calls function; `assert_enqueued worker: FetchAdAccountsWorker, args: %{"meta_connection_id" => conn.id}`
  - `handle_info(:schedule_all, ...)`: insert 2 active + 1 revoked connection; send `:schedule_all` via `send(pid, :schedule_all)` then sync with `:sys.get_state/1`; assert 2 jobs enqueued, 0 for revoked
  - Start scheduler with `start_supervised!({Scheduler, []})` — pass `schedule_on_init: false` opt OR just test `schedule_sync_for_connection/1` directly without starting the GenServer

- [x] [testing] Write `test/ad_butler/workers/fetch_ad_accounts_worker_test.exs`
  - `use Oban.Testing, repo: AdButler.Repo`
  - `perform/1` success: `expect(Meta.ClientMock, :list_ad_accounts, ...)` returns 2 accounts; perform job; assert 2 rows in `ad_accounts` via `Ads.list_ad_accounts(user)` — confirms context routing works
  - `perform/1` rate limit: `ClientMock` returns `{:error, :rate_limit_exceeded}`; assert return `{:snooze, 60}`; DB unchanged
  - `perform/1` unauthorized: `ClientMock` returns `{:error, :unauthorized}`; assert `{:cancel, "unauthorized"}`; connection status updated to "revoked"
  - `perform/1` generic error: returns `{:error, :meta_server_error}`; assert job returns same error
  - Idempotency: call `perform/1` twice with same connection + same Meta account IDs; assert still 1 row in DB (upsert)

---

## Phase 4 — Broadway MetadataSyncPipeline (Day 9)

> Depends on Phase 1 (topology/publisher) and Phase 2 (Ads context upserts). Parallel with Phase 3.

- [x] [otp] Create `lib/ad_butler/sync/metadata_pipeline.ex`
  ```elixir
  defmodule AdButler.Sync.MetadataPipeline do
    use Broadway
    alias Broadway.Message
    alias AdButler.{Accounts, Ads, Repo}
    alias AdButler.Ads.AdAccount
    require Logger
  ```
  - `start_link/1` — configures producer based on env:
    - Non-test: `BroadwayRabbitMQ.Producer` on queue `"ad_butler.sync.metadata"` with `qos: [prefetch_count: 10]`
    - Test: `Broadway.DummyProducer` (set via config: `config :ad_butler, :broadway_producer, Broadway.DummyProducer` in test.exs)
  - Processors: `[default: [concurrency: 5, partition_by: &partition_by_ad_account/1]]`
  - Batchers: `[default: [concurrency: 2, batch_size: 10, batch_timeout: 2_000]]`
  - `handle_message/3`: decode JSON → get `ad_account_id` → `Repo.get(AdAccount, id)` → if nil: `Message.failed(msg, :not_found)`, else: `Message.put_data(msg, ad_account) |> Message.put_batcher(:default)`
  - `handle_batch/4`: group messages by `meta_connection_id`; for each group, call `sync_ad_account/2`
  - Private `sync_ad_account/1`:
    1. Load connection: `Accounts.get_meta_connection!(ad_account.meta_connection_id)`
    2. `meta_client().list_campaigns(ad_account.meta_id, connection.access_token)` → `Ads.upsert_campaign/2` for each
    3. `meta_client().list_ad_sets(ad_account.meta_id, connection.access_token)` → `Ads.upsert_ad_set/2` for each
    4. `meta_client().list_ads(ad_account.meta_id, connection.access_token)` → `Ads.upsert_ad/2` for each
    5. On `{:error, :rate_limit_exceeded}`: log warning, return failed messages
    6. On `{:error, reason}`: log error, return failed messages
    7. On success: log info with counts; return acked messages
  - Private `partition_by_ad_account/1` — extracts `ad_account_id` from message data for partitioning
  - Private `meta_client/0` — `Application.get_env(:ad_butler, :meta_client, AdButler.Meta.Client)`
  - Private `parse_budget/1` — `nil → nil`, `binary → String.to_integer/1`, `integer → identity`
  - **No direct `Repo` calls in `handle_message/3` or `handle_batch/4`** — all DB writes through Ads context

- [x] [otp] Configure Broadway producer for test env in `config/test.exs`:
  ```elixir
  config :ad_butler, :broadway_producer, :test
  ```
  The `start_link/1` checks this and uses `Broadway.DummyProducer` when value is `:test`.

- [x] [otp] Add `AdButler.Sync.MetadataPipeline` to supervision tree in `application.ex`
  - After `Sync.Scheduler`, before `AdButlerWeb.Endpoint`
  - Skip in test env (same pattern as Scheduler — config flag)

- [x] [testing] Write `test/ad_butler/sync/metadata_pipeline_test.exs`
  - Uses `Broadway.test_message/3` to inject messages without RabbitMQ
  - `start_supervised!(MetadataPipeline)` — starts with DummyProducer in test env
  - Test: valid message → campaigns/ad_sets/ads upserted in DB (Mock Meta.Client returns data)
  - Test: message with unknown `ad_account_id` → message fails gracefully (no crash)
  - Test: rate limit error → message fails; no DB writes
  - Test: message processing is idempotent — same `ad_account_id` twice → no duplicate rows

---

## Phase 5 — Integration Testing + DLQ Replay (Day 10)

- [x] [testing] Create `test/integration/sync_pipeline_test.exs`
  - `@moduletag :integration` — excluded from normal `mix test`
  - `use AdButler.DataCase, async: false`
  - Full flow test (no `Process.sleep` — use `Oban.Testing.perform_job/2`):
    1. Create user + meta_connection via factory
    2. Mock `Meta.ClientMock.list_ad_accounts/1` to return 1 account
    3. Call `FetchAdAccountsWorker.new(%{meta_connection_id: conn.id}) |> Oban.Testing.perform_job(FetchAdAccountsWorker)`
    4. Assert 1 `AdAccount` row in DB via `Ads.list_ad_accounts(user)`
    5. Mock `Meta.ClientMock.list_campaigns/3`, `list_ad_sets/3`, `list_ads/3`
    6. Inject Broadway message via `Broadway.test_message(MetadataPipeline, Jason.encode!(%{ad_account_id: ad_account.meta_id, sync_type: "full"}))`
    7. Assert `ref = Broadway.test_batch(MetadataPipeline, messages)` (or use `Broadway.test_message` and await `:batch_timeout`)
    8. Assert campaigns/ad_sets/ads rows exist via Ads context functions
  - DLQ replay test: publish a message to DLQ manually; run `Mix.Tasks.AdButler.ReplayDlq.run([])`; assert message moved to main queue

- [x] [oban] Create `lib/mix/tasks/ad_butler.replay_dlq.ex`
  - `use Mix.Task`; `@shortdoc "Replay messages from DLQ back to main queue"`
  - `run/1` — parses `--limit` option; opens AMQP connection; loops `AMQP.Basic.get` from DLQ; publishes each to main exchange; acks from DLQ; logs final count
  - `@moduletag :integration` on its test
  - Handle empty queue gracefully (`:empty` return from `AMQP.Basic.get`)
  - `@spec` on `run/1`

- [x] [testing] Write `test/mix/tasks/replay_dlq_test.exs`
  - `@moduletag :integration`
  - Publish 3 messages to DLQ directly via AMQP; run task; assert DLQ empty + main queue has 3 messages

---

## Phase 6 — Verification

- [x] `mix compile --warnings-as-errors` — zero warnings
- [x] `mix format --check-formatted` — no changes
- [x] `mix credo --strict lib/ad_butler/ads/ lib/ad_butler/sync/ lib/ad_butler/messaging/ lib/ad_butler/workers/fetch_ad_accounts_worker.ex` — no violations
- [x] `mix test` (excludes `:integration` tag) — all pass, 100% coverage on new modules
- [x] `mix precommit` — passes all gates

---

## Risks

1. **`broadway_rabbitmq` + `amqp` version compatibility** — `broadway_rabbitmq ~> 0.8` requires `amqp ~> 2.0`. Check `mix deps.get` output for conflicts. If there's a lock conflict with existing deps, pin `amqp` explicitly.

2. **Broadway DummyProducer in test env** — `Broadway.DummyProducer` was introduced in Broadway 1.0. Verify the Broadway version in `mix.lock`. `Broadway.test_message/3` is the correct API for injecting test messages. If the version is old, use `Broadway.test_messages/2` or upgrade.

3. **`scope/2` join explosion** — The `scope/2` join for Campaign/AdSet/Ad queries adds two joins (→ AdAccount → MetaConnection). Verify explain-analyze output in dev shows index scans, not sequential scans, on the `meta_connections(user_id)` index. Migration `20260420155107_create_meta_connections.exs` includes this index — confirm it's present.

4. **FetchAdAccountsWorker publishing to RabbitMQ in test** — The worker calls `Messaging.Publisher.publish/1`, but Publisher isn't started in test env. Solve by checking `Application.get_env(:ad_butler, :meta_client)` pattern: also add a `messaging_publisher` config key that resolves to a no-op module in test. Alternatively, stub `Publisher.publish/1` with `Mox` (add `AdButler.Messaging.PublisherBehaviour` + mock).

5. **`list_all_active_meta_connections/0` at scale** — This query has no limit. At 1k connections, it loads everything into memory on startup. Acceptable for MVP; document with a comment that this needs cursor pagination at scale.

6. **Broadway partition_by and DummyProducer** — In test mode, `Broadway.DummyProducer` doesn't pass messages through the `partition_by` function. Broadway `test_message/3` uses the processor directly. This is fine for unit tests but means partition correctness is only verified in integration tests with real RabbitMQ.

7. **`on_conflict: {:replace, [...]}` missing `updated_at`** — All upsert functions must include `:updated_at` in the replace list. Without it, `updated_at` won't be refreshed on conflict, causing stale timestamps. Double-check all `upsert_*` functions.
