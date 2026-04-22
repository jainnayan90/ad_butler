# Plan: Audit Fixes Round 2
**Source**: `.claude/plans/review/reviews/audit-health-fixes-2-triage.md`
**Tasks**: 12 tasks across 4 phases
**Goal**: Fix all must-fix + warning findings from the round-2 audit health review

---

## Phase 1 — Critical Correctness (deploy blockers)

- [x] [P1-T1] Filter nil `ad_set_id` before `bulk_upsert_ads` in `metadata_pipeline.ex` — Enum.split_with orphan guard + Logger.warning
  - File: `lib/ad_butler/sync/metadata_pipeline.ex:72`
  - Use `Enum.split_with(attrs_list, &(not is_nil(&1.ad_set_id)))` — same orphan-guard as ad sets
  - Log dropped orphaned ads: `Logger.warning("Orphaned ads dropped during sync", count: length(orphaned), ad_account_id: ad_account.id)`
  - Pass only `valid` list to `Ads.bulk_upsert_ads/2`

- [x] [P1-T2] Bind `bulk_upsert_ads/2` return value and log DB count — upserted_count in Logger.info
  - File: `lib/ad_butler/sync/metadata_pipeline.ex:73`
  - `{upserted_count, _} = Ads.bulk_upsert_ads(ad_account, valid)`
  - Update `Logger.info` to log `ads: upserted_count` (not raw API `length(ads)`)

- [x] [P1-T3] Handle `Oban.insert_all/1` return in `SyncAllConnectionsWorker` — is_list guard (API returns list, not {:ok,_})
  - File: `lib/ad_butler/workers/sync_all_connections_worker.ex:22`
  - Replace bare `Oban.insert_all(jobs)` with:
    ```elixir
    case Oban.insert_all(jobs) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
    ```

---

## Phase 2 — Security & Validation

- [x] [P2-T1] Sanitize token-exchange error body before it enters logs — extracts code/type/subcode only
  - File: `lib/ad_butler/meta/client.ex:148`
  - At the error-return site, extract only safe fields: `code`, `type`, `error_subcode`
  - Return `{:error, {:token_exchange_failed, %{code: ..., type: ..., subcode: ...}}}` instead of raw body
  - All callers (`fetch_ad_accounts_worker.ex:75,90`, `token_refresh_worker.ex:84`, `metadata_pipeline.ex:91`) already use `inspect(reason)` — with safe struct, no token leaks

- [x] [P2-T2] Add `bulk_validate/2` helper; apply to all `bulk_upsert_*` callers — validates after ad_account_id injected
  - File: `lib/ad_butler/ads.ex`
  - Private helper:
    ```elixir
    defp bulk_validate(attrs_list, schema_mod) do
      {valid, invalid} = Enum.split_with(attrs_list, fn attrs ->
        schema_mod.changeset(struct(schema_mod), attrs).valid?
      end)
      if invalid != [] do
        meta_ids = Enum.map(invalid, & &1[:meta_id])
        Logger.warning("bulk_validate: dropped invalid rows", count: length(invalid), meta_ids: meta_ids)
      end
      valid
    end
    ```
  - Apply before `Repo.insert_all` in `bulk_upsert_campaigns/2`, `bulk_upsert_ad_sets/2`, `bulk_upsert_ads/2`

- [x] [P2-T3] UUID-cast job arg in `FetchAdAccountsWorker` — with/else pattern, run_sync/1 takes connection only
  - File: `lib/ad_butler/workers/fetch_ad_accounts_worker.ex:19`
  - Wrap the `perform/1` head with `Ecto.UUID.cast/1`:
    ```elixir
    def perform(%Oban.Job{args: %{"meta_connection_id" => id}}) do
      with {:ok, uuid} <- Ecto.UUID.cast(id),
           %MetaConnection{} = conn <- Accounts.get_meta_connection(uuid) do
        run_sync(conn)
      else
        :error -> {:cancel, "invalid_meta_connection_id"}
        nil -> {:cancel, "meta_connection_not_found"}
      end
    end
    ```
  - Extract current body into private `run_sync/1`

- [x] [P2-T4] Rename `get_ad_account_for_sync/1` → `unsafe_get_ad_account_for_sync/1` — updated ads.ex, metadata_pipeline.ex, ads_test.exs
  - File: `lib/ad_butler/ads.ex:50` + caller `lib/ad_butler/sync/metadata_pipeline.ex`
  - Makes bypass loud in grep; prevents accidental use from web controllers
  - Update the `@doc` comment to explain bypass

---

## Phase 3 — Test Coverage

- [x] [P3-T1] Add `bulk_upsert_ads/2` tests to `ads_test.exs` — insert + idempotency tests
  - File: `test/ad_butler/ads_test.exs`
  - `describe "bulk_upsert_ads/2"` with:
    - insert test: inserts rows, returns `{count, [%{id, meta_id}]}`
    - idempotency test: second call returns same IDs, updates name/status
    - orphan filter test: nil `ad_set_id` is filtered before reaching this fn (assert the pipeline does this, not the fn itself)

- [x] [P3-T2] Add non-empty ads test to `metadata_pipeline_test.exs` — ads sync + orphan drop tests
  - File: `test/ad_butler/sync/metadata_pipeline_test.exs`
  - Add a test that stubs `list_ads` with 2–3 ad fixtures
  - Assert `bulk_upsert_ads` is called (via `Mox.expect`) and sync returns `:ok`
  - Add a separate test where one ad has no matching ad set → verify orphan dropped, sync still returns `:ok`

- [x] [P3-T3] Fix persistent test issues (W5a/b/c) — removed sleep, captured original env, created AMQPBasicBehaviour
  - **W5a** `replay_dlq_test.exs:70`: Remove `Process.sleep(100)` — the unit-test path is synchronous; verify drain completes without sleep
  - **W5b** `plug_attack_test.exs:44`: Capture original before mutation:
    ```elixir
    original = Application.get_env(:ad_butler, :trusted_proxy)
    on_exit(fn -> Application.put_env(:ad_butler, :trusted_proxy, original) end)
    ```
  - **W5c** `replay_dlq_test.exs` `AMQPBasicStub`: Define `AdButler.AMQPBasicBehaviour` if not already present; add `@behaviour AdButler.AMQPBasicBehaviour` to `AMQPBasicStub`

---

## Phase 4 — Infrastructure

- [x] [P4-T1] Document and verify pool size vs sync queue concurrency — config.exs comment + .env.example POOL_SIZE=25
  - File: `.env.example`, `fly.toml` (if present)
  - Add comment to `config/config.exs` near `queues: [sync: 20]`: "Requires POOL_SIZE >= 25 in prod (sync: 20 concurrency + headroom)"
  - Update `.env.example` to set `POOL_SIZE=25`
  - Verify `fly.toml` or Dockerfile doesn't hardcode a lower value

---

## Verification

Per-phase: `mix compile --warnings-as-errors`
Final gate: `mix test`

---

## Risks

- P2-T2 (`bulk_validate/2`): Schema modules use struct-based changesets; passing `struct(schema_mod)` requires each schema to have a zero-arg struct. All current schemas have embedded defaults — should be fine.
- P2-T3 (UUID cast refactor): `run_sync/1` extraction changes the call signature slightly — ensure `cancel` returns are tested.
- P3-T2 (Mox expect for bulk_upsert): `bulk_upsert_ads` is a context function, not a behaviour — assert by DB state, not Mox.
