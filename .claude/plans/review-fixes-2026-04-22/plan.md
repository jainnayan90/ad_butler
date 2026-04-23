# Review Fixes — 2026-04-22

Source: `.claude/plans/review/reviews/audit-health-fixes-triage.md`
Branch: `main`

14 tasks across 3 phases. All findings from triage approved.

---

## Phase 1: Code Correctness (before next deploy)

### MF-1 — Replace `Enum.each` + `Oban.insert` with `Oban.insert_all`

- [x] [P1-T1][oban] Replace `Enum.each` + `Oban.insert/1` with `Oban.insert_all/1` in `SyncAllConnectionsWorker` — Enum.map + Oban.insert_all/1, one DB round-trip
  File: `lib/ad_butler/workers/sync_all_connections_worker.ex`

  **Problem**: `Enum.each` discards `{:ok, _}` / `{:error, _}` from `Oban.insert/1`. Any insert failure
  silently returns `:ok` — connections skipped, no log, no retry.

  **Fix**:
  ```elixir
  @impl Oban.Worker
  def perform(_job) do
    Accounts.list_all_active_meta_connections()
    |> Enum.map(fn connection ->
      FetchAdAccountsWorker.new(%{"meta_connection_id" => connection.id})
    end)
    |> Oban.insert_all()

    :ok
  end
  ```
  `Oban.insert_all/1` is one DB round-trip, raises on constraint violation / pool error.

---

### MF-2 — Remove split-brain session salts from `runtime.exs`

- [x] [P1-T2][code] Remove `session_signing_salt` and `session_encryption_salt` overrides from `runtime.exs` prod block — kept LIVE_VIEW_SIGNING_SALT; updated .env.example
  Files: `config/runtime.exs`

  **Problem**: `endpoint.ex:13-14` builds `@session_options` with `compile_env!` — frozen at build time.
  The LiveView socket uses `@session_options` to read/verify HTTP cookies. The HTTP session plug uses
  `fetch_env!` (runtime). If `SESSION_SIGNING_SALT` is set in prod env, HTTP cookies are signed with
  the new salt but the LV socket tries to verify them with the compile-time default (`"yp0B0EBm"`) — 
  the socket cannot decrypt the cookie, LV session silently fails.

  **Fix**: Remove the two keys from the `runtime.exs` prod block added in P2-T2:
  ```elixir
  # REMOVE these two lines — session salts are compile-time only (see endpoint.ex comment).
  # Rotation requires a recompile + restart. Keep LIVE_VIEW_SIGNING_SALT (different config).
  session_signing_salt: System.fetch_env!("SESSION_SIGNING_SALT"),
  session_encryption_salt: System.fetch_env!("SESSION_ENCRYPTION_SALT")
  ```
  Keep `live_view: [signing_salt: System.fetch_env!("LIVE_VIEW_SIGNING_SALT")]` — that key controls
  LiveView payload signing, not HTTP cookie salts, and IS used at runtime.

  Update the comment in `runtime.exs` to explain why session salts are absent:
  ```elixir
  # Session cookie salts are compile-time only (endpoint.ex uses compile_env!).
  # Rotating them requires recompile + restart. Set in config/dev.exs / inject at build time.
  ```

  Update `.env.example` to remove `SESSION_SIGNING_SALT` and `SESSION_ENCRYPTION_SALT` or mark them
  as "not used at runtime — inject at build time".

---

### W3 — Unify `with` else failure reasons in `handle_message/3`

- [x] [P1-T3][code] Unify `with` else to return `:invalid_payload` for all non-nil malformed-input cases — :invalid_uuid → :invalid_payload
  File: `lib/ad_butler/sync/metadata_pipeline.ex`

  **Problem**: `Ecto.UUID.cast/1` failure returns `:invalid_uuid` reason; the other bad-payload branches
  return `:invalid_payload`. Dead-lettered messages from the same malformed-payload root cause have
  inconsistent reasons, making DLQ analysis harder.

  **Fix**: Replace the `:error` else branch:
  ```elixir
  else
    {:ok, _} -> Message.failed(message, :invalid_payload)
    {:error, _} -> Message.failed(message, :invalid_payload)
    :error -> Message.failed(message, :invalid_payload)   # was :invalid_uuid
    nil -> Message.failed(message, :not_found)
  end
  ```

---

### W5 — Fix `parse_budget/1` to not crash processor on bad input

- [x] [P1-T4][code] Replace `String.to_integer/1` with `Integer.parse/1` + fallback in `parse_budget/1` — returns nil on non-integer strings
  File: `lib/ad_butler/sync/metadata_pipeline.ex`

  **Problem**: `String.to_integer("invalid")` raises `ArgumentError`, crashing the Broadway processor
  when Meta returns a non-integer budget string (schema drift, malicious publisher).

  **Fix**:
  ```elixir
  defp parse_budget(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> nil
    end
  end
  ```

---

### W7 — Add `server: true` unconditionally in prod

- [x] [P1-T5][code] Add `server: true` unconditionally inside the prod block of `runtime.exs` — PHX_SERVER conditional retained as optional override
  File: `config/runtime.exs`

  **Problem**: `server: true` currently requires `PHX_SERVER=true` env var. If unset in Fly.io secrets,
  the release boots silently with no HTTP traffic served.

  **Fix**: Inside the final `if config_env() == :prod do` block add:
  ```elixir
  config :ad_butler, AdButlerWeb.Endpoint, server: true
  ```
  Remove or keep the `PHX_SERVER` conditional as an optional override (it does no harm if `server`
  is also set unconditionally).

---

## Phase 2: Security & Config

### W1 — Rename unscoped `get_ad_account/1` to signal internal use

- [x] [P2-T1][code] Rename `get_ad_account/1` → `get_ad_account_for_sync/1`; add `@doc`; update all callers — 1 call site in metadata_pipeline.ex
  Files: `lib/ad_butler/ads.ex`, `lib/ad_butler/sync/metadata_pipeline.ex`

  **Problem**: Public, unscoped sibling of `get_ad_account!/2` (scoped). Near-identical names make it
  easy for a future controller to accidentally call the unscoped version with `params["id"]`.

  **Fix**:
  1. In `ads.ex` rename and add doc:
     ```elixir
     @doc "INTERNAL — bypasses tenant scope. Use get_ad_account!/2 in user-facing code."
     @spec get_ad_account_for_sync(binary()) :: AdAccount.t() | nil
     def get_ad_account_for_sync(id), do: Repo.get(AdAccount, id)
     ```
  2. Update `metadata_pipeline.ex` call site: `Ads.get_ad_account_for_sync(ad_account_id)`.

---

### W2 — Make dev Cloak fallback obviously insecure

- [x] [P2-T2][code] Replace silent fallback with 32-zero-byte guard in `dev.exs` — raises if decoded key != 32 bytes
  File: `config/dev.exs`

  **Problem**: Silent fallback to a real AES key in git. No feedback when env var is unset.

  **Fix**:
  ```elixir
  cloak_key_dev =
    Base.decode64!(
      System.get_env(
        "CLOAK_KEY_DEV",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="  # 32 zero bytes — obviously fake
      )
    )

  if byte_size(cloak_key_dev) != 32 do
    raise "CLOAK_KEY_DEV must decode to exactly 32 bytes"
  end

  config :ad_butler, AdButler.Vault,
    ciphers: [default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: cloak_key_dev}]
  ```

  Note: Use all-zeros as the insecure-but-obvious fallback. Update `.env.example`
  with a generation command.

---

### W6 — Move literal session salts out of `config.exs`

- [x] [P2-T3][code] Move hardcoded session salts from `config.exs` into `dev.exs` and `test.exs` — salts removed from config.exs; dev/test get obvious-fake values
  Files: `config/config.exs`, `config/dev.exs`, `config/test.exs`

  **Problem**: `"yp0B0EBm"`, `"Cfg1C1OwCrAmNkVp"`, `"27ZZYgxL"` are committed in `config.exs` and
  become the compile-time defaults for any release. They leak through git history.

  **Fix**:
  1. Remove from `config.exs`:
     ```elixir
     # Remove:
     config :ad_butler,
       session_signing_salt: "yp0B0EBm",
       session_encryption_salt: "Cfg1C1OwCrAmNkVp"

     # Remove from Endpoint block:
     live_view: [signing_salt: "27ZZYgxL"]
     ```
  2. Add to `dev.exs` and `test.exs`:
     ```elixir
     config :ad_butler,
       session_signing_salt: "dev_signing_salt",
       session_encryption_salt: "dev_encrypt_salt"

     config :ad_butler, AdButlerWeb.Endpoint,
       live_view: [signing_salt: "dev_lv_salt"]
     ```
  3. For prod: salts must be injected at compile/build time. Document in `runtime.exs` comment.

  Note: If `compile_env!` is called before `dev.exs` is loaded, compilation will fail — verify
  that `import_config "#{config_env()}.exs"` runs before `endpoint.ex` is compiled (it does in
  standard Phoenix apps because `config.exs` is evaluated first with `import_config` at end).

---

### W8 — Check and remediate `.envrc` key exposure

- [x] [P2-T4][manual] Verify `.envrc` was never pushed; rotate if pushed; replace with placeholder — never committed; real CLOAK_KEY replaced with placeholder
  File: `.envrc`

  **Problem**: `.envrc:7` contains a real `CLOAK_KEY`. Gitignored but the history must be checked.

  **Steps**:
  1. Run `git log --all -- .envrc` — if any output, the file was committed.
  2. If committed: rotate the `CLOAK_KEY` in prod (`fly secrets set CLOAK_KEY=$(32 |> :crypto.strong_rand_bytes() |> Base.encode64())`), update `runtime.exs` guard, redeploy.
  3. Replace the key value in `.envrc` with a placeholder matching `.env.example` style.

---

## Phase 3: Specs, Polish & Tests

### W4 — Tighten `bulk_upsert_*` specs

- [x] [P3-T1][code] Tighten `bulk_upsert_campaigns/2` and `bulk_upsert_ad_sets/2` return type specs — {non_neg_integer(), [%{id: binary(), meta_id: binary()}]}
  File: `lib/ad_butler/ads.ex`

  **Problem**: `{integer(), [map()]}` prevents Dialyzer from validating `row.meta_id` / `row.id`
  field accesses in `metadata_pipeline.ex`.

  **Fix**:
  ```elixir
  @spec bulk_upsert_campaigns(AdAccount.t(), [map()]) ::
          {non_neg_integer(), [%{id: binary(), meta_id: binary()}]}

  @spec bulk_upsert_ad_sets(AdAccount.t(), [map()]) ::
          {non_neg_integer(), [%{id: binary(), meta_id: binary()}]}
  ```

---

### W9 + S3 — Document scope query cost; add missing `@spec`

- [x] [P3-T2][code] Add comment on scope helpers documenting extra DB round-trip; add `@spec` to `schedule_sync_for_connection/1` — aliased MetaConnection for precise type
  Files: `lib/ad_butler/ads.ex`, `lib/ad_butler/sync/scheduler.ex`

  1. In `ads.ex` above `scope/2` and `scope_ad_account/2`:
     ```elixir
     # Issues one extra SELECT to fetch connection IDs before the main query (2 round-trips
     # per scoped call). Acceptable for single lookups. If calling multiple scoped functions
     # in the same request, hoist list_meta_connection_ids_for_user/1 to the caller.
     ```
  2. In `scheduler.ex` add spec + alias:
     ```elixir
     alias AdButler.Accounts.MetaConnection

     @spec schedule_sync_for_connection(MetaConnection.t()) ::
             {:ok, Oban.Job.t()} | {:error, term()}
     ```

---

### S2 — Add `timeout/1` to `FetchAdAccountsWorker`

- [x] [P3-T3][oban] Add `timeout/1` callback to `FetchAdAccountsWorker` — 5 minute timeout
  File: `lib/ad_butler/workers/fetch_ad_accounts_worker.ex`

  **Problem**: No timeout — a hung Meta API call occupies a `sync` queue slot indefinitely.

  **Fix**: Add after the `@impl Oban.Worker` `perform/1`:
  ```elixir
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)
  ```

---

### S1 — Offset `SyncAllConnectionsWorker` cron

- [x] [P3-T4][code] Change `SyncAllConnectionsWorker` cron from `"0 */6 * * *"` to `"5 */6 * * *"` — avoids simultaneous fire with TokenRefreshSweepWorker
  File: `config/config.exs`

  **Problem**: Both workers fire simultaneously, making dashboard isolation harder.

  **Fix**: Change the crontab entry:
  ```elixir
  {"5 */6 * * *", AdButler.Workers.SyncAllConnectionsWorker}
  ```

---

### S4 — Fill test gaps

- [x] [P3-T5][test] Add: bulk_upsert direct test + empty-connections test; fix redundant count assertions — 110 tests, 0 failures
  File: `test/ad_butler/ads_test.exs`, `test/ad_butler/sync/scheduler_test.exs`

  1. `ads_test.exs` — Add direct test for `bulk_upsert_campaigns/2` on_conflict path:
     ```elixir
     describe "bulk_upsert_campaigns/2" do
       test "upserts on conflict (ad_account_id, meta_id)" do
         aa = insert(:ad_account)
         attrs = [%{meta_id: "c_1", name: "Original", status: "ACTIVE", objective: "OUTCOME_TRAFFIC"}]
         {1, [%{id: id, meta_id: "c_1"}]} = Ads.bulk_upsert_campaigns(aa, attrs)
         {1, [%{id: ^id}]} = Ads.bulk_upsert_campaigns(aa, [%{attrs | name: "Updated"}])
         assert Repo.aggregate(Campaign, :count) == 1
       end
     end
     ```
  2. `scheduler_test.exs` — Add empty-connections case:
     ```elixir
     test "returns :ok with no connections" do
       assert :ok = perform_job(SyncAllConnectionsWorker, %{})
       assert all_enqueued(worker: FetchAdAccountsWorker) == []
     end
     ```
  3. Remove the `Repo.aggregate(:count) == 1` assertions from the upsert idempotency tests — redundant with `first.id == second.id`.

---

## Verification

After each phase:
```
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix test
```
