# Plan: Audit Health Fixes — v0.2

Source: `.claude/plans/v0.2-audit-fixes/reviews/audit-triage.md`
Date: 2026-04-27
Status: Ready to implement

## Context

20 findings from the project health audit, triaged by priority. All 20 are
included below; 6 were explicitly skipped by the user in the triage file and
are listed at the bottom for reference.

---

## Phase 1 — Iron Law Violations (auto-approved)

### SEC-1 · Fix `parse_page/1` crash risk in 4 LiveViews

`String.to_integer/1` raises on non-numeric input (e.g. `?page=abc`). Replace
with `Integer.parse/1` fallback pattern.

Files: `dashboard_live.ex:109-110`, `campaigns_live.ex:202-203`,
`ad_sets_live.ex:207-208`, `ads_live.ex:198-199`.

- [ ] [liveview] Replace `parse_page/1` in all 4 LiveViews:
  ```elixir
  defp parse_page(nil), do: 1
  defp parse_page(p) when is_binary(p) do
    case Integer.parse(p) do
      {n, ""} when n > 0 -> n
      _ -> 1
    end
  end
  ```

---

### SEC-2 · Fix Logger string interpolation in `auth_controller.ex`

Line 77: `Logger.error("OAuth failure reason=#{inspect(reason)}")` violates
structured logging rule.

- [ ] [ecto] Change to:
  ```elixir
  Logger.error("oauth_failure", reason: ErrorHelpers.safe_reason(reason))
  ```

---

### ARCH-1 · Create `AdButler.Analytics` context; move Repo out of workers

Three workers call `Repo` directly. Context boundary: workers call context
functions; context owns all DB calls.

**New module: `lib/ad_butler/analytics.ex`**

Wraps:
- `Analytics.refresh_view/1` — called by `MatViewRefreshWorker`
- `Analytics.create_future_partitions/0` — called by `PartitionManagerWorker`
- `Analytics.detach_old_partitions/0` — called by `PartitionManagerWorker`
- `Analytics.check_future_partition_count/0` — called by `PartitionManagerWorker`
- `Analytics.list_partition_names/0` — shared by detach + check (also fixes PERF-4)

**`Accounts.stream_connections_and_run/1`** — wraps the
`Repo.transaction` + stream pattern used by `SyncAllConnectionsWorker`.

Tasks:

- [ ] [ecto] Create `lib/ad_butler/analytics.ex` with `@moduledoc`; move all
  Repo/SQL logic from `MatViewRefreshWorker` and `PartitionManagerWorker` into
  public functions:
  - `refresh_view/1` — takes `"7d" | "30d"`, queries Repo, logs, returns `:ok`
  - `list_partition_names/0` — executes the `pg_inherits` query, returns
    `[String.t()]`
  - `create_future_partitions/0` — iterates 7/14 days ahead, calls
    `Repo.query!` for `CREATE TABLE IF NOT EXISTS`
  - `detach_old_partitions/0` — calls `list_partition_names/0`, detaches old
    ones via `Repo.query!`
  - `check_future_partition_count/0` — calls `list_partition_names/0`, logs
    critical error if fewer than 2 future partitions
  - Add `@doc` to every public function

- [ ] [oban] Refactor `MatViewRefreshWorker.perform/1` to delegate to
  `Analytics.refresh_view/1`; remove `alias AdButler.Repo`

- [ ] [oban] Refactor `PartitionManagerWorker.perform/1` to delegate to
  `Analytics.create_future_partitions/0`, `Analytics.detach_old_partitions/0`,
  `Analytics.check_future_partition_count/0`; remove `alias AdButler.Repo`;
  keep private helpers (`week_start/1`, `partition_name/1`, etc.) in the worker
  or move to Analytics — either is fine as long as the worker has no Repo alias

- [ ] [ecto] Add `Accounts.stream_connections_and_run/1` to `accounts.ex`:
  ```elixir
  @doc "Runs `fun` inside a transaction with a stream of active MetaConnections."
  @spec stream_connections_and_run((Enumerable.t() -> any()), keyword()) :: {:ok, any()} | {:error, term()}
  def stream_connections_and_run(fun, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, :timer.minutes(2))
    Repo.transaction(fn -> fun.(stream_active_meta_connections()) end, timeout: timeout)
  end
  ```

- [ ] [oban] Refactor `SyncAllConnectionsWorker.perform/1` to use
  `Accounts.stream_connections_and_run/1`; remove direct `AdButler.Repo` call

---

### ARCH-2 · Move `Repo` out of `HealthController`

`HealthController.default_db_ping/0` calls `SQL.query(Repo, ...)` directly.
Move to a proper context module.

- [ ] [ecto] Create `lib/ad_butler/health.ex`:
  ```elixir
  defmodule AdButler.Health do
    @moduledoc "Internal health checks for the application."
    alias AdButler.Repo
    alias Ecto.Adapters.SQL

    @doc "Pings the database with a 1-second timeout. Returns `{:ok, _}` or `{:error, _}`."
    def db_ping do
      SQL.query(Repo, "SELECT 1", [], timeout: 1_000, queue_target: 200)
    end
  end
  ```

- [ ] [ecto] Update `HealthController`: replace `default_db_ping/0` body with
  `AdButler.Health.db_ping/0`; remove `alias AdButler.Repo` and
  `alias Ecto.Adapters.SQL`

---

### ARCH-3 · Fix `ConnectionsLive` — stream, pagination, `connected?` gate

Three issues: DB query not gated on `connected?`, plain list assign,
no pagination.

New context function needed: `Accounts.paginate_meta_connections/2`.

- [ ] [ecto] Add `paginate_meta_connections/2` to `accounts.ex`:
  ```elixir
  @doc """
  Returns a page of MetaConnections for `user` (all statuses) and the total count.
  Options: `:page` (default 1), `:per_page` (default 50).
  """
  @spec paginate_meta_connections(User.t(), keyword()) :: {[MetaConnection.t()], non_neg_integer()}
  def paginate_meta_connections(%User{id: user_id}, opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 50)

    base = from(mc in MetaConnection, where: mc.user_id == ^user_id, order_by: [desc: mc.inserted_at])
    total = Repo.aggregate(base, :count)
    items = base |> limit(^per_page) |> offset(^((page - 1) * per_page)) |> Repo.all()
    {items, total}
  end
  ```

- [ ] [liveview] Refactor `ConnectionsLive`:
  - `mount/3`: initialize stream and pagination assigns; gate DB call behind
    `connected?(socket)` — on disconnect set `stream(:connections, [])` and
    `assign(:total_pages, 1)`
  - `handle_params/3`: read `page` param, call `paginate_meta_connections/2`,
    use `stream(:connections, items, reset: true)`
  - Remove plain `:connections` list assign; update template `:for` to use
    `@streams.connections`
  - Add `assign(:page, page)` and `assign(:total_pages, total_pages)` and
    `assign(:connection_count, total)`

---

### ARCH-4 · Add `LLM.insert_usage/1`; remove `Repo` from `UsageHandler`

`UsageHandler` calls `Repo.insert` directly — violates context boundary.

- [ ] [ecto] Add `insert_usage/1` to `lib/ad_butler/llm.ex`:
  ```elixir
  @doc false
  def insert_usage(attrs) when is_map(attrs) do
    changeset = Usage.changeset(%Usage{}, attrs)
    case Repo.insert(changeset, on_conflict: :nothing, conflict_target: [:request_id]) do
      {:ok, _} -> :ok
      {:error, cs} -> {:error, cs}
    end
  end
  ```

- [ ] [ecto] Update `UsageHandler.insert_usage/1` to call
  `AdButler.LLM.insert_usage(attrs)` and log on `{:error, cs}`;
  remove `alias AdButler.Repo` and `alias AdButler.LLM.Usage`

---

### TEST-1 · `AdButler.LLM` context tests with tenant isolation

- [ ] [testing] Create `test/ad_butler/llm_test.exs`:
  - `list_usage_for_user/2` — basic returns own rows
  - `list_usage_for_user/2` — tenant isolation (user A rows invisible to user B)
  - `list_usage_for_user/2` — filters: `:purpose`, `:provider`, `:status`, `:limit`
  - `total_cost_for_user/1` — sums correctly; returns zeros when no rows
  - `total_cost_for_user/1` — tenant isolation
  - `get_usage!/2` — returns row for owner; raises for wrong user

---

### TEST-3 · `Ads.paginate_*` tests with tenant isolation

- [ ] [testing] Create or expand `test/ad_butler/ads_test.exs` (or
  `test/ad_butler/ads/` directory):
  - `paginate_campaigns/2` — returns correct page/total; tenant isolation
  - `paginate_ad_sets/2` — returns correct page/total; tenant isolation
  - `paginate_ads/2` — returns correct page/total; tenant isolation
  - `paginate_ad_accounts/2` — returns correct page/total; tenant isolation
  - Each isolation test: two users, insert for user A, assert user B gets empty
    results (count 0, items [])

---

## Phase 2 — High Priority

### PERF-1 · Add `select:` projection to `list_*` / `paginate_*` in `ads.ex`

Excludes `:raw_jsonb` (all schemas) and `:targeting_jsonb` (AdSet only) from
default fetches.

- [ ] [ecto] Define a `@list_fields` or `select:` fragment per schema. For each
  of `list_campaigns/2`, `paginate_campaigns/2`, `list_ad_sets/2`,
  `paginate_ad_sets/2`, `list_ads/2`, `paginate_ads/2`, `list_ad_accounts/1`,
  `paginate_ad_accounts/2`: add `|> select([x], map(x, ^excluded_fields_list))`
  or use `struct/2` to exclude heavy JSON columns.
  - Campaign: exclude `:raw_jsonb`
  - AdSet: exclude `:raw_jsonb`, `:targeting_jsonb`
  - Ad: exclude `:raw_jsonb`
  - AdAccount: exclude `:raw_jsonb`
  - Keep `select:` off `get_*!` and `upsert_*` functions (those need full records)

---

### PERF-2 · `Ads.stream_active_ad_accounts/0` using `Repo.stream`

`InsightsSchedulerWorker` loads all active ad accounts into memory with
`list_ad_accounts_internal/0`. Replace with a streaming approach.

- [ ] [ecto] Add `stream_active_ad_accounts/0` to `ads.ex`:
  ```elixir
  @doc "Streams active AdAccounts for internal scheduler use. Must be called inside a transaction."
  @spec stream_active_ad_accounts() :: Enum.t()
  def stream_active_ad_accounts do
    from(aa in AdAccount, where: aa.status == "ACTIVE")
    |> Repo.stream(max_rows: 500)
  end
  ```

- [ ] [oban] Refactor `InsightsSchedulerWorker.perform/1` to wrap in
  `Repo.transaction` and use `stream_active_ad_accounts/0` with
  `Stream.chunk_every(200)`; accumulate results for error reporting

---

### TEST-2 · `MatViewRefreshWorker` tests

- [ ] [testing] Create `test/ad_butler/workers/mat_view_refresh_worker_test.exs`:
  - `perform/1` with `%{"view" => "7d"}` — mock/stub `Analytics.refresh_view/1`
    returns `:ok`, assert worker returns `:ok`
  - `perform/1` with `%{"view" => "30d"}` — same
  - `perform/1` with `%{"view" => "unknown"}` — assert `{:error, _}` returned

  Note: after ARCH-1, the worker delegates to `Analytics.refresh_view/1`. Test
  the worker behaviour, not the SQL (the Analytics context owns the DB test).

---

## Phase 3 — Medium Priority

### PERF-3 · Resolve `mc_ids` once in `handle_info(:reload_on_reconnect)`

`campaigns_live.ex`, `ads_live.ex`, `ad_sets_live.ex` each call
`Accounts.list_meta_connection_ids_for_user/1` multiple times inside the same
`handle_info` clause.

- [ ] [liveview] In each of the three LiveViews, extract `mc_ids` into a
  `let` binding at the top of the `handle_info(:reload_on_reconnect, ...)` body
  and pass it to context functions instead of `socket.assigns.current_user`
  where `mc_ids` is already available.

---

### PERF-4 · Extract `list_partition_names/0` (part of ARCH-1)

Duplicate `pg_inherits` SQL in `detach_old_partitions/0` and
`check_future_partition_count/0`.

**Resolved by ARCH-1**: when both functions move to the `Analytics` context,
`list_partition_names/0` is extracted as a shared private function there.
Mark as done when ARCH-1 `Analytics` tasks are complete.

- [ ] [ecto] Verify `Analytics.list_partition_names/0` is used by both
  `detach_old_partitions/0` and `check_future_partition_count/0` after ARCH-1
  (no separate work needed if ARCH-1 is done correctly)

---

### PERF-5 · Add `limit: 200` to `list_ad_accounts/1` (mc_ids variant)

`list_ad_accounts(mc_ids)` is unbounded. A user with many ad accounts causes an
unbounded query. Cap at 200 with a warning.

- [ ] [ecto] In `ads.ex`, update the `list_ad_accounts(mc_ids)` clause:
  ```elixir
  def list_ad_accounts(mc_ids) when is_list(mc_ids) do
    AdAccount
    |> scope_ad_account(mc_ids)
    |> limit(200)
    |> Repo.all()
  end
  ```
  Add a `Logger.warning` if result length == 200 (truncation signal).

---

### TEST-4 · Fix `Process.sleep(20)` in `replay_dlq_test.exs`

Line 186: `Process.sleep(20)` is a timing-dependent sync. Replace with
message-based synchronisation.

- [ ] [testing] In `test/mix/tasks/replay_dlq_test.exs:186`: replace
  `Process.sleep(20)` with a `receive do` / `assert_receive` on a monitor DOWN
  message, or use `:sys.get_state/1` on the process under test to synchronise.
  If the tested process is a Task, monitor it before starting and assert on
  `{:DOWN, ref, :process, _, _}`.

---

## Phase 4 — Low Priority

### ARCH-5 · `InsightsSchedulerWorker` default publisher → `PublisherPool`

`FetchAdAccountsWorker` already defaults to `PublisherPool`. Align
`InsightsSchedulerWorker`.

- [ ] [oban] Change `InsightsSchedulerWorker.publisher/0` default from
  `AdButler.Messaging.Publisher` to `AdButler.Messaging.PublisherPool`

---

### TEST-5 · Replace `stub` with `expect(..., 1, fn ...)` in Mox tests

- [ ] [testing] In `test/ad_butler/accounts_authenticate_via_meta_test.exs` and
  `test/ad_butler_web/controllers/auth_controller_test.exs`: replace
  `Mox.stub(MockModule, :fun, fn ... end)` with
  `Mox.expect(MockModule, :fun, 1, fn ... end)` for assertions that should fire
  exactly once. Keep `stub` only where the call count is genuinely variable.

---

### SEC-3 · Remove default all-zeros Cloak key from `dev.exs`

Shipping a known-bad key in source is a security smell even in dev.

- [ ] [ecto] In `config/dev.exs`: remove the default `<<0::256>>` Cloak key.
  Replace with:
  ```elixir
  cloak_key = System.get_env("CLOAK_KEY_DEV") ||
    raise "Set CLOAK_KEY_DEV in .env.local (run: openssl rand -base64 32)"
  ```
  Update `.env.example` with `CLOAK_KEY_DEV=` and instructions for generating
  it.

---

### DEPS-2 · Upgrade `logger_json` to `~> 7.0`

- [ ] [ecto] In `mix.exs`: bump `{:logger_json, "~> 7.0"}`. Update
  `config/config.exs` `:backends` key to the new handler form required by 7.x
  (consult logger_json 7.0 changelog for exact key name change). Run
  `mix deps.get` and verify compile.

---

## Verification

- [ ] Run `mix precommit` and fix any failures before considering work done
- [ ] Confirm tenant isolation tests pass for LLM and Ads contexts

---

## Skipped (user decision)

| ID | Reason |
|----|--------|
| ARCH-6 | AdButler.Sync undeclared context — longer refactor, future sprint |
| DEPS-1 | plug_attack unmaintained but no CVE; replacement is a larger decision |
| DEPS-3 | req ~> 0.5 constraint — minor, widen when upgrading |
| TEST-6 | Ordering test flakiness — low probability |
| TEST-7 | async: false in sync_all_connections_worker_test — low value |
| TEST-8 | Pre-existing failure, already known |
| ARCH-7 | dev_routes guard — informational |

---

## Implementation Notes

- **ARCH-1 + PERF-4 are coupled**: write `Analytics.list_partition_names/0` as
  a private function inside the Analytics context when implementing ARCH-1.
  PERF-4 is automatically resolved.
- **ARCH-1 + TEST-2 are coupled**: `MatViewRefreshWorker` tests (TEST-2) should
  be written after ARCH-1 refactor so they test the delegating `perform/1`.
- **ARCH-3 needs `paginate_meta_connections/2` first** before the LiveView
  refactor.
- **SEC-3** requires updating `.env.example` in the same commit.
