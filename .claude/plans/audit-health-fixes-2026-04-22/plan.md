# Audit Health Fixes — 2026-04-22

Source: `.claude/audit/summaries/project-health-2026-04-22.md`  
Branch: `main`  
Overall health: 79/100 — C (Needs Attention)

13 tasks across 3 phases. Phase 1 must ship before the next deploy.

---

## Phase 1: Critical (before next deploy)

### A1 — Remove MetaConnection cross-context JOIN from Ads context

- [x] [P1-T1][code] Add `Accounts.list_meta_connection_ids_for_user/1` and rewrite `scope/2` and `scope_ad_account/2` in `Ads` to use it — removed cross-context JOIN, Accounts now exposes IDs via query, Ads uses `in ^mc_ids`
  Files: `lib/ad_butler/accounts.ex`, `lib/ad_butler/ads.ex`

  **Problem**: `ads.ex` imports `AdButler.Accounts.MetaConnection` and JOINs it directly in
  `scope/2` (line 24) and `scope_ad_account/2` (line 15). This is a cross-context schema import —
  `Ads` must not know about `MetaConnection` internals.

  **Fix**:

  1. Add to `lib/ad_butler/accounts.ex`:
     ```elixir
     @spec list_meta_connection_ids_for_user(User.t()) :: [binary()]
     def list_meta_connection_ids_for_user(%User{id: user_id}) do
       MetaConnection
       |> where([mc], mc.user_id == ^user_id and mc.status == "active")
       |> select([mc], mc.id)
       |> Repo.all()
     end
     ```

  2. In `lib/ad_butler/ads.ex`:
     - Remove `MetaConnection` from the alias line (keep `User`, `AdAccount`, `Ad`, `AdSet`, `Campaign`, `Creative`)
     - Add `alias AdButler.Accounts`
     - Rewrite `scope_ad_account/2`:
       ```elixir
       defp scope_ad_account(queryable, %User{} = user) do
         mc_ids = Accounts.list_meta_connection_ids_for_user(user)
         from aa in queryable, where: aa.meta_connection_id in ^mc_ids
       end
       ```
     - Rewrite `scope/2`:
       ```elixir
       defp scope(queryable, %User{} = user) do
         mc_ids = Accounts.list_meta_connection_ids_for_user(user)
         from q in queryable,
           join: aa in AdAccount,
           on: q.ad_account_id == aa.id,
           where: aa.meta_connection_id in ^mc_ids
       end
       ```

  Note: The extra IDs query is a single cheap `SELECT id WHERE user_id = ? AND status = 'active'`.
  It replaces the JOIN on a cross-context schema, which is the correct trade-off here.

---

### A2 + S3 — Fix direct Repo call + add UUID validation in MetadataPipeline

- [x] [P1-T2][code] Add `Ads.get_ad_account/1` and use it in `MetadataPipeline.handle_message/3` with UUID validation — with chain replaces triple-nested case; Repo alias removed from pipeline
  Files: `lib/ad_butler/ads.ex`, `lib/ad_butler/sync/metadata_pipeline.ex`

  **A2 problem**: `metadata_pipeline.ex:32` calls `Repo.get(AdAccount, ad_account_id)` directly,
  bypassing the `Ads` context. Any future context-level logic (soft deletes, audit hooks) would
  be silently skipped.

  **S3 problem**: `ad_account_id` comes from raw JSON. A malformed UUID goes straight to
  `Repo.get` → `Ecto.Query.CastError` → message fails → DLQ churn.

  **Fix**:

  1. Add to `lib/ad_butler/ads.ex` (internal, unscoped — sync pipeline has no user):
     ```elixir
     @spec get_ad_account(binary()) :: AdAccount.t() | nil
     def get_ad_account(id), do: Repo.get(AdAccount, id)
     ```

  2. Replace `handle_message/3` body in `metadata_pipeline.ex`:
     ```elixir
     def handle_message(_processor, %Message{data: data} = message, _context) do
       case Jason.decode(data) do
         {:ok, %{"ad_account_id" => raw_id}} ->
           case Ecto.UUID.cast(raw_id) do
             {:ok, ad_account_id} ->
               case Ads.get_ad_account(ad_account_id) do
                 nil -> Message.failed(message, :not_found)
                 ad_account ->
                   message
                   |> Message.put_data(ad_account)
                   |> Message.put_batcher(:default)
               end

             :error ->
               Message.failed(message, :invalid_uuid)
           end

         _ ->
           Message.failed(message, :invalid_payload)
       end
     end
     ```

  Also remove `alias AdButler.Ads.AdAccount` (no longer needed directly; accessed via `Ads.get_ad_account`).
  Keep it for `partition_by_ad_account/1` pattern match on `%AdAccount{}`.

---

### P1 — Fix N+1: load MetaConnection once per batch group

- [x] [P1-T3][code] Pass `MetaConnection` into `sync_ad_account/2` — load once per group, not once per account — connection fetched once from first_account, passed into sync_ad_account/2
  File: `lib/ad_butler/sync/metadata_pipeline.ex`

  **Problem**: `process_batch_group/1` (line 55) calls `sync_ad_account/1` per message, which
  fetches `Accounts.get_meta_connection!/1` (line 64) for each ad_account. Messages in the same
  group share a `meta_connection_id` (they were grouped in `handle_batch` line 51). Result:
  10 ad accounts in one group = 10 identical DB fetches.

  **Fix**:
  ```elixir
  defp process_batch_group([%Message{data: first_account} | _] = msgs) do
    connection = Accounts.get_meta_connection!(first_account.meta_connection_id)

    Enum.map(msgs, fn %Message{data: ad_account} = msg ->
      case sync_ad_account(ad_account, connection) do
        :ok -> msg
        {:error, reason} -> Message.failed(msg, reason)
      end
    end)
  end

  defp sync_ad_account(ad_account, connection) do
    client = meta_client()
    with {:ok, campaigns} <- client.list_campaigns(ad_account.meta_id, connection.access_token, []),
         ...
  ```

  Remove the `connection = Accounts.get_meta_connection!(...)` line from `sync_ad_account/2`.

---

## Phase 2: Short-term (next sprint)

### P2 — Bulk upsert campaigns and ad_sets

- [x] [P2-T1][code] Add `Ads.bulk_upsert_campaigns/2` and `Ads.bulk_upsert_ad_sets/2`; wire into `MetadataPipeline` — Repo.insert_all with on_conflict; pipeline private functions now build attrs lists then call bulk
  Files: `lib/ad_butler/ads.ex`, `lib/ad_butler/sync/metadata_pipeline.ex`

  **Problem**: `upsert_campaigns/2` and `upsert_ad_sets/2` in the pipeline loop one
  `INSERT...ON CONFLICT` per row (lines 99–104, 108–113). 100 campaigns = 100 round trips.

  **Fix**: Add to `lib/ad_butler/ads.ex`:
  ```elixir
  @spec bulk_upsert_campaigns(AdAccount.t(), [map()]) :: {integer(), [Campaign.t()]}
  def bulk_upsert_campaigns(%AdAccount{} = ad_account, attrs_list) do
    now = DateTime.utc_now()
    entries =
      Enum.map(attrs_list, fn attrs ->
        attrs
        |> Map.put(:ad_account_id, ad_account.id)
        |> Map.put(:inserted_at, now)
        |> Map.put(:updated_at, now)
      end)

    Repo.insert_all(
      Campaign,
      entries,
      on_conflict: {:replace, [:name, :status, :objective, :daily_budget_cents, :lifetime_budget_cents, :raw_jsonb, :updated_at]},
      conflict_target: [:ad_account_id, :meta_id],
      returning: [:id, :meta_id]
    )
  end
  ```
  Return value is `{count, [%{id: ..., meta_id: ...}]}`. Build the `meta_id → db_id` map from that.
  Apply the same pattern for `bulk_upsert_ad_sets/3`.

  In `metadata_pipeline.ex`, replace the `upsert_campaigns/2` and `upsert_ad_sets/2` private
  functions with calls to the new bulk versions.

  Note: `Repo.insert_all` does not run changesets — validate attrs at the pipeline boundary
  (the Meta API response is the source, already validated upstream). Add only field presence
  assertions in a test rather than reinventing changeset logic.

---

### S1 — Move session salts to runtime env vars (prod)

- [x] [P2-T2][code] Override session salts from env vars in `runtime.exs` for prod; keep defaults in `config.exs` for dev/test — added SESSION_SIGNING_SALT, SESSION_ENCRYPTION_SALT, LIVE_VIEW_SIGNING_SALT to runtime.exs prod block and .env.example
  Files: `config/config.exs`, `config/runtime.exs`

  **Problem**: `config.exs:18-19` and `config.exs:29` contain hardcoded
  `session_signing_salt`, `session_encryption_salt`, and `live_view: [signing_salt:]`.
  These are committed to the repo and cannot be rotated without a code change.

  **Note on compile_env!**: `endpoint.ex:13-14` uses `compile_env!` for `@session_options`
  (needed by the LiveView socket connect_info macro). These compile-time values are the dev
  defaults; the `session/2` plug at line 75 uses `fetch_env!` (runtime) for actual HTTP sessions.
  Only the HTTP session pick up the runtime override. LiveView socket requires a recompile.
  This is an accepted trade-off — document it.

  **Fix**:
  1. Keep the current values in `config.exs` as dev/test defaults (no change there).
  2. Add to `runtime.exs` inside `config_env() == :prod` block:
     ```elixir
     config :ad_butler,
       session_signing_salt: System.fetch_env!("SESSION_SIGNING_SALT"),
       session_encryption_salt: System.fetch_env!("SESSION_ENCRYPTION_SALT")

     config :ad_butler, AdButlerWeb.Endpoint,
       live_view: [signing_salt: System.fetch_env!("LIVE_VIEW_SIGNING_SALT")]
     ```
  3. Add `SESSION_SIGNING_SALT`, `SESSION_ENCRYPTION_SALT`, `LIVE_VIEW_SIGNING_SALT` to `.env.example`
     with `mix phx.gen.secret 32` usage instructions.

---

### S2 — Move dev Cloak key out of source

- [x] [P2-T3][code] Read dev Cloak key from env var with hardcoded fallback; document in `.env.example` — System.get_env("CLOAK_KEY_DEV", fallback) in dev.exs
  File: `config/dev.exs`

  **Problem**: `dev.exs:100` has the AES key hardcoded: `Base.decode64!("DWd3enw3...")`.
  The key is committed to the repo — any dev with repo access can decrypt all dev DB tokens.

  **Fix**:
  ```elixir
  config :ad_butler, AdButler.Vault,
    ciphers: [
      default:
        {Cloak.Ciphers.AES.GCM,
         tag: "AES.GCM.V1",
         key: Base.decode64!(System.get_env("CLOAK_KEY_DEV", "DWd3enw3lCLQQhOo7zcLHBUds5byv33NIJuHMvqG114="))}
    ]
  ```

  Note: The fallback value stays so dev works without any `.env` setup. The key is for local
  dev data only — no real user credentials. The goal is to break the habit and document the
  pattern; a future rotation only needs an env var update.
  Add `CLOAK_KEY_DEV` to `.env.example`.

---

### P3 — Replace Scheduler GenServer with Oban cron

- [x] [P2-T4][code] Delete `Sync.Scheduler` GenServer; add `SyncAllConnectionsWorker`; register in Oban cron — GenServer removed, new Oban worker at 0 */6 * * *, Scheduler module kept with schedule_sync_for_connection/1 only
  Files: `lib/ad_butler/sync/scheduler.ex`, `lib/ad_butler/workers/sync_all_connections_worker.ex` (new),
  `config/config.exs`, `lib/ad_butler/application.ex`

  **Problem**: `Scheduler` fires once (5s after boot) and never re-schedules (line 23). After
  the first run, no more syncs happen until the next restart. It also lacks the Sandbox.allow
  coverage needed for tests.

  **Fix**:
  1. Create `lib/ad_butler/workers/sync_all_connections_worker.ex`:
     ```elixir
     defmodule AdButler.Workers.SyncAllConnectionsWorker do
       use Oban.Worker, queue: :sync, max_attempts: 3,
         unique: [period: 3600, states: [:available, :executing, :scheduled, :retryable]]

       alias AdButler.Accounts
       alias AdButler.Sync.Scheduler

       @impl Oban.Worker
       def perform(_job) do
         connections = Accounts.list_all_active_meta_connections()
         Enum.each(connections, &Scheduler.schedule_sync_for_connection/1)
         :ok
       end
     end
     ```
  2. Keep `Scheduler.schedule_sync_for_connection/1` as a public helper (used by the new worker
     and directly by tests). Remove everything else in `Scheduler` (the `GenServer` boilerplate,
     `init/1`, `handle_info/2`). Or just delete `scheduler.ex` and inline the enqueue logic into
     the worker — whichever is cleaner.
  3. In `config/config.exs`, add to `Oban.Plugins.Cron` crontab:
     ```elixir
     {"0 */6 * * *", AdButler.Workers.SyncAllConnectionsWorker}
     ```
  4. Remove `AdButler.Sync.Scheduler` from the `application.ex` supervised children list.

  Note: `schedule_sync_for_connection/1` is still needed by `FetchAdAccountsWorker` tests
  and any direct callers — keep it accessible.

---

### A4 — Fix atom keys in Oban job args

- [x] [P2-T5][code] Change `schedule_sync_for_connection/1` to use string key `"meta_connection_id"` — fixed in both scheduler.ex and sync_all_connections_worker.ex
  File: `lib/ad_butler/sync/scheduler.ex` (or wherever `schedule_sync_for_connection/1` ends up after P2-T4)

  **Problem**: `scheduler.ex:16` uses atom key: `%{meta_connection_id: connection.id}`.
  Oban serializes args to JSON, so atom keys round-trip to string keys. The worker already
  pattern-matches on the string form (line 19 in `fetch_ad_accounts_worker.ex`), so it works at
  runtime — but atom keys in Oban args are a bug waiting to surface in `assert_enqueued/1`
  comparisons and `unique` key matching.

  **Fix**:
  ```elixir
  %{"meta_connection_id" => connection.id}
  |> FetchAdAccountsWorker.new()
  |> Oban.insert()
  ```

---

### P4 — Add LIMIT to `list_all_active_meta_connections/0`

- [x] [P2-T6][code] Add a reasonable hard cap (1000) to `list_all_active_meta_connections/0` — added limit/1 param with default 1000
  File: `lib/ad_butler/accounts.ex`

  **Problem**: `list_all_active_meta_connections/0` (line 84) has no LIMIT. At scale, fetching
  all active connections in one query blocks the scheduler and loads the entire table into memory.

  **Fix**:
  ```elixir
  @spec list_all_active_meta_connections(pos_integer()) :: [MetaConnection.t()]
  def list_all_active_meta_connections(limit \\ 1000) do
    MetaConnection
    |> where([mc], mc.status == "active")
    |> limit(^limit)
    |> Repo.all()
  end
  ```

  Note: For >1000 connections, the real fix is cursor-based pagination through Oban cron +
  batched workers. This cap is a safety net, not a final solution. Document as such.

---

### T2 — Fix Sandbox.allow gap in scheduler_test

- [x] [P2-T7][code] Add `Ecto.Adapters.SQL.Sandbox.allow` for the Scheduler GenServer PID — GenServer removed; test rewritten to use perform_job/2 for SyncAllConnectionsWorker
  File: `test/ad_butler/sync/scheduler_test.exs`

  **Problem**: `start_supervised({Scheduler, []})` starts a new process. By default, the
  DataCase sandbox only allows the test process itself. If `handle_info(:schedule_all)` hits
  the DB from the GenServer PID, it may silently pass in `:shared` mode but fail in `:manual`.

  **Fix**: After `start_supervised`, explicitly allow the GenServer PID:
  ```elixir
  {:ok, pid} = start_supervised({Scheduler, []})
  Ecto.Adapters.SQL.Sandbox.allow(AdButler.Repo, self(), pid)
  send(pid, :schedule_all)
  :sys.get_state(pid)
  ```

  Note: Once P2-T4 ships and the Scheduler GenServer is removed, this test file will need
  to be updated for the new `SyncAllConnectionsWorker` pattern (test via `perform_job/2`).

---

### T5 — Add idempotency tests for `upsert_ad_set/2` and `upsert_ad/2`

- [x] [P2-T8][ecto][test] Add context-level upsert idempotency tests — 4 tests added for upsert_ad_set/2 (insert + update) and upsert_ad/2 (insert + update)
  File: `test/ad_butler/ads_test.exs`

  **Problem**: `upsert_campaign/2` is presumably tested, but `upsert_ad_set/2` and `upsert_ad/2`
  have no direct tests asserting that a second call with the same `(ad_account_id, meta_id)`
  updates rather than inserts a duplicate.

  **Fix**: Add to `test/ad_butler/ads_test.exs`:
  ```elixir
  describe "upsert_ad_set/2" do
    test "inserts on first call" do ...end
    test "updates on duplicate meta_id + ad_account_id" do
      ad_account = insert(:ad_account)
      attrs = %{meta_id: "s_1", name: "Original", status: "ACTIVE", ...}
      {:ok, first} = Ads.upsert_ad_set(ad_account, attrs)
      {:ok, second} = Ads.upsert_ad_set(ad_account, Map.put(attrs, :name, "Updated"))
      assert first.id == second.id
      assert second.name == "Updated"
    end
  end
  ```
  Same structure for `upsert_ad/2`.

---

## Phase 3: Long-term (backlog)

- [ ] [P3-T1][arch] Add `%Scope{}` pattern per Phoenix 1.8 conventions — removes manual `%User{}` scoping from context functions
  File: `lib/ad_butler/accounts.ex`, `lib/ad_butler/ads.ex`, router/controller layer
  Note: Defer until first LiveView is added; the current controllers are the natural seam to introduce Scope.

- [ ] [P3-T2][perf] Add `select/2` projections to list queries to drop `raw_jsonb` from list views
  Files: `lib/ad_butler/ads.ex` — `list_campaigns/2`, `list_ad_sets/2`, `list_ads/2`
  Note: Depends on knowing which fields the UI actually needs. Do when building the first list view.

- [ ] [P3-T3][arch] Add `--confirm` flag and payload validation to `Mix.Tasks.AdButler.ReplayDlq`
  File: `lib/mix/tasks/ad_butler.replay_dlq.ex`
  ReplayDlq replays all payloads with no validation — poison messages re-enter the pipeline.
  Add: `Ecto.UUID.cast` check on `ad_account_id` before republish; `--confirm` interactive prompt
  for production safety; `--dry-run` to count without moving.

- [ ] [P3-T4][test] Increase `Process.sleep(100)` reliability in `replay_dlq_test.exs`
  File: `test/mix/tasks/replay_dlq_test.exs:33`
  Use polling (`Stream.repeatedly` + short sleep) or increase to 500ms with a comment.
  Already tagged `@moduletag :integration` — acceptable to leave if the sleep is stable in CI.

---

## Verification

After each phase:
```
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix test
```

Phase 1 only: also run a smoke test confirming Broadway pipeline still starts:
```
MIX_ENV=dev iex -S mix
```
And confirm `Ads.list_campaigns(user)` still returns scoped results.
