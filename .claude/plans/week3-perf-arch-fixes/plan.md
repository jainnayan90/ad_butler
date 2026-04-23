# Week 3 — Performance & Architecture Critical Fixes

## Context

Derived from project health audit 2026-04-23 — score **B (75.9/100)**.
Source: `.claude/audit/summaries/project-health-2026-04-23.md`

6 CRITICAL findings block scaling past ~1000 ad accounts. This plan addresses
all P0 critical items, P1 high-impact performance and security fixes, and the
highest-priority test coverage gaps. Projected score after completion: **A (88+/100)**.

**Explicitly deferred (not in scope):**
- Phoenix 1.8 Scope pattern — separate plan (large refactor)
- `unsafe_get_ad_account_for_sync` module extraction — future plan
- `req ~> 1.0` upgrade — separate compatibility review
- `plug_attack` evaluation/replacement — backlog
- Tidewave compile-time vs runtime guard — extremely low risk, backlog
- T8/T9 factory + ConnCase import — nice-to-have, low impact

---

## Phase 1: Critical Concurrency Fixes [P0]

### 1.1 Fix Publisher GenServer bottleneck — add process pool
**File:** `lib/ad_butler/messaging/publisher.ex`
**Audit finding:** P2-CRITICAL — all 20 Oban sync workers compete on a single
`GenServer.call` mailbox; default 5 s timeout expires before mailbox drains.

- [x] [ecto] Add `pool_size` config key to `:rabbitmq` app env (default 5)
- [x] Create `AdButler.Messaging.PublisherPool` module using `Registry` + `DynamicSupervisor`
      to maintain N `Publisher` worker processes
- [x] Update `publish/1` to select a worker via round-robin from the pool
- [x] Update `AdButler.Application` to start `PublisherPool` instead of bare `Publisher`
- [x] Update `FetchAdAccountsWorker.publisher/0` to call `PublisherPool.publish/1`
- [x] Update `PublisherBehaviour` if signature changes
- [x] Add `await_connected/1` on pool (waits until all workers are connected)
- [x] Test: publish from 20 concurrent tasks simultaneously; assert all succeed without timeout

### 1.2 Remove O(n) changeset validation from Broadway batcher
**File:** `lib/ad_butler/ads.ex:308-326` (`bulk_validate/2`)
**Audit finding:** P1-CRITICAL — `changeset/2` called per row synchronously inside
Broadway batch callback; fully blocks 2 batcher processes on large syncs.

- [x] [ecto] Replace `bulk_validate/2` with `bulk_strip_and_filter/2` that:
      1. Calls `Map.take(attrs, schema_mod.__schema__(:fields))` to strip unknown keys
      2. Drops rows missing any required field (check against `@required` attribute)
      3. Logs dropped rows by meta_id (preserve existing log behaviour)
      — No more `changeset/2` call; data from Meta API is trusted, not user input
- [x] Update callers: `bulk_upsert_campaigns/2`, `bulk_upsert_ad_sets/2`, `bulk_upsert_ads/2`
- [x] Verify required-field lists are accessible (expose `@required` via module attribute or function)
- [x] Test: bulk_upsert with rows missing required fields; assert they are dropped + logged

### 1.3 Batch-load MetaConnections in Broadway handle_batch
**File:** `lib/ad_butler/sync/metadata_pipeline.ex:47-50`
**Audit finding:** P3-CRITICAL — `get_meta_connection!` called once per unique
connection in the batch (N queries where N = distinct connections). Fixable to 1 query.

- [x] [ecto] In `handle_batch/4`, collect all unique `meta_connection_id` values from messages
- [x] Load all connections in a single `Accounts.get_meta_connections_by_ids/1` query
      (add this function to `lib/ad_butler/accounts.ex`)
- [x] Build a `%{id => connection}` map; pass into `process_batch_group/2`
- [x] Update `process_batch_group/2` to accept the map and look up connection by id
- [x] Handle missing connection: use `Map.get/3` with nil default; call `Message.failed/2`
      per message (fixes the bang-crash-entire-batch bug as a side effect)
- [x] Test: batch with 3 messages from 2 different connections; assert 1 DB query total

---

## Phase 2: Context Boundary Violations [P0]

### 2.1 Remove direct Accounts.get_meta_connection! from MetadataPipeline
**File:** `lib/ad_butler/sync/metadata_pipeline.ex:8,53`
**Audit finding:** A2-CRITICAL + A/HIGH — pipeline calls into `Accounts` context directly;
boundary should be: `Sync` → `Ads` → (Ads may call Accounts internally)

*Note: This is resolved as part of task 1.3 above — the new `get_meta_connections_by_ids/1`
function added to `Accounts` is called from `handle_batch`, keeping the pipeline using
context functions rather than raw Repo. Verify `alias AdButler.Accounts` is only used
for this call; if pipeline also calls Accounts elsewhere, consolidate.*

- [x] Remove `alias AdButler.Accounts` from `metadata_pipeline.ex` if no longer needed
      after task 1.3 lands
- [x] Verify `alias AdButler.Ads.AdAccount` is still needed (it is, for `Message.put_data`)

### 2.2 Fix Ads→Accounts compile-time coupling
**File:** `lib/ad_butler/ads.ex:6` (`alias AdButler.Accounts.{MetaConnection, User}`)
**Audit finding:** A/HIGH — `Ads` recompiles whenever `Accounts.MetaConnection` changes.
The `MetaConnection` alias is used only in a typespec for `upsert_ad_account/2`.

- [x] [ecto] Change `upsert_ad_account/2` typespec to reference `AdButler.Accounts.MetaConnection.t()`
      directly (no alias) — remove `MetaConnection` from the alias tuple
- [x] `User` alias is used in scoping functions (correct cross-context dependency) — keep it
- [x] Verify compile still passes; run `mix xref graph --source lib/ad_butler/ads.ex` to
      confirm `Accounts.MetaConnection` is no longer a compile-time dep

### 2.3 Standardise meta_client injection to one canonical pattern
**File:** multiple (`accounts.ex`, `token_refresh_worker.ex`, `fetch_ad_accounts_worker.ex`,
`metadata_pipeline.ex`)
**Audit finding:** A/HIGH — three different resolution patterns for the same injectable dep.

- [x] Choose canonical form: `AdButler.Meta.Client.client()` (already a function call —
      readable and testable)
- [x] Update `fetch_ad_accounts_worker.ex:110` — replace inline `Application.get_env/3`
      with `Client.client()`
- [x] Update `metadata_pipeline.ex:196` — same replacement
- [x] Verify all four call sites now use `Client.client()`

---

## Phase 3: High-Impact Performance Fixes [P1]

### 3.1 Add status composite indexes on campaigns and ad_sets
**Audit finding:** P/MEDIUM — full scans on `(ad_account_id)` range when `status` filter applied.

- [x] [ecto] Add migration: `CREATE INDEX CONCURRENTLY idx_campaigns_account_status ON campaigns(ad_account_id, status)`
- [x] Add migration: `CREATE INDEX CONCURRENTLY idx_ad_sets_account_status ON ad_sets(ad_account_id, status)`
- [x] Run `mix ecto.migrate` and verify with `\d campaigns` in psql

### 3.2 Tune Broadway pipeline concurrency settings
**File:** `lib/ad_butler/sync/metadata_pipeline.ex:20-34`
**Audit finding:** P5/HIGH — throughput artificially capped at 20 concurrent syncs.

- [x] Raise `batcher_concurrency` from 2 → 5
- [x] Raise `prefetch_count` from 10 → 50
- [x] Raise `batch_size` from 10 → 25 (matches prefetch head-room)
- [x] Document new settings with comment explaining the math
      (`concurrency × batch_size = max in-flight; prefetch ≥ concurrency × batch_size`)

### 3.3 Implement cursor-based batching for active connections list
**File:** `lib/ad_butler/accounts.ex`
**Audit finding:** P6/HIGH — connections beyond 1000 permanently skipped every sweep.

- [x] [ecto] Add `stream_active_meta_connections/1` that yields connections in pages of 500
      using keyset pagination (cursor on `id` — binary_id is orderable)
- [x] Update `SyncAllConnectionsWorker.perform/1` to use `Enum.chunk_every/2` + paginated
      stream, calling `Oban.insert_all/1` per chunk of 200
- [x] Keep `list_all_active_meta_connections/1` for tests that need a full list; update its
      doc to reflect it is capped and not for production sweep use
- [x] Test: mock 1001 active connections; assert all 1001 get a job enqueued

### 3.4 Fix await_connected/1 busy-poll in Publisher
**File:** `lib/ad_butler/messaging/publisher.ex:133-146`
**Audit finding:** A/MEDIUM — 20 `GenServer.call` per second while waiting; contends with
`:connect` message during startup.

*Note: If task 1.1 (publisher pool) is implemented first, `await_connected` must be updated
to work with the pool — wait until ALL pool workers are connected.*

- [x] Replace `do_await_connected/1` poll loop with a proper `{:await_connected, from}`
      GenServer message: store `from` in state; reply when `:connect` callback sets channel
- [x] If already connected when `await_connected/1` is called, reply immediately
- [x] Test: call `await_connected/1` before AMQP is up; assert it blocks then returns `:ok`
      once connected (use `Broadway.DummyProducer` pattern for test isolation)

### 3.5 Narrow list_expiring_meta_connections window from 70→14 days
**File:** `lib/ad_butler/accounts.ex`
**Audit finding:** P/LOW — 70-day window schedules refresh jobs for ~every active connection
every sweep; Oban unique constraint suppresses duplicates but query+insert still runs.

- [x] Change `@sweep_days_ahead` default from 70 to 14 in `TokenRefreshSweepWorker`
      *(the default in `Accounts.list_expiring_meta_connections` is 70; the sweep worker
      passes its own `@sweep_days_ahead` constant which is already 15 — verify this is the
      correct constant to change)*
- [x] Verify: `Accounts.list_expiring_meta_connections/2` default arg (70) is only called
      from sweep worker; update caller and remove the misleading default

---

## Phase 4: Security Fixes [P1]

### 4.1 Guard OAuth error_description in flash
**File:** `lib/ad_butler_web/controllers/auth_controller.ex:50`
**Audit finding:** S/MEDIUM — arbitrary length/content string injected into flash; phishing risk.

- [x] Truncate `description` to 200 chars before interpolation:
      `String.slice(description, 0, 200)`
- [x] Log the raw (untruncated) value at `:warning` level before truncation
- [x] Test: pass a 500-char error_description; assert flash contains ≤200 chars

### 4.2 Switch refresh_token from GET to POST
**File:** `lib/ad_butler/meta/client.ex:95-118`
**Audit finding:** S/MEDIUM — access token appears in proxy/CDN logs as a query param.

- [x] Change `Req.request(..., method: :get, params: [...fb_exchange_token: access_token])` 
      to `Req.post(url, req_options() ++ [form: [...fb_exchange_token: access_token]])`
- [x] Update test stub / Mox expectation for `refresh_token/1` if HTTP method is asserted
- [x] Test: assert token does not appear in the URL params of the outbound request

### 4.3 Raise session salt minimum validation to 32 bytes
**File:** `config/prod.exs` (or wherever the runtime validation lives)
**Audit finding:** S/LOW — prod guard only requires 8 bytes; Phoenix recommends 32.

- [x] Find the salt length validation (grep for `byte_size` or salt guard in runtime.exs)
- [x] Raise minimum from 8 → 32 bytes for both `session_signing_salt` and
      `session_encryption_salt`
- [x] Verify dev/test salts are ≥32 bytes (or document that shorter salts are acceptable
      in non-prod with a comment)

---

## Phase 5: Test Coverage Gaps [P2]

### 5.1 AuthControllerTest — add set_mox_global
**File:** `test/ad_butler_web/controllers/auth_controller_test.exs`
**Audit finding:** T1/MEDIUM — Mox private mode; will break if dispatch spawns a process.

- [x] Add `setup :set_mox_global` to the top of `AuthControllerTest`
- [x] Verify all existing tests still pass

### 5.2 Meta.Client — unit tests for 5 untested callbacks
**File:** `test/ad_butler/meta/client_test.exs`
**Audit finding:** T2/MEDIUM — `list_campaigns/3`, `list_ad_sets/3`, `list_ads/3`,
`refresh_token/1`, `get_creative/2` have zero direct tests.

- [x] Test `list_campaigns/3`: 200 with data, 200 without data key, 401, 429, 500
- [x] Test `list_ad_sets/3`: 200, 401, rate-limit
- [x] Test `list_ads/3`: 200, 401, rate-limit
- [x] Test `refresh_token/1`: 200 success, 401 revoked, network error
- [x] Test `get_creative/2`: 200, 404, timeout

### 5.3 MetadataPipeline — unauthorized + orphan ad-set paths
**File:** `test/ad_butler/sync/metadata_pipeline_test.exs`
**Audit finding:** T3/MEDIUM, T4/MEDIUM

- [x] Add test: `list_campaigns` returns `{:error, :unauthorized}` → message failed
- [x] Add test: `list_ad_sets` returns `{:error, :unauthorized}` → message failed
- [x] Add test: ad set's `campaign_id` not in campaign_id_map → orphan ad set dropped,
      message still succeeds (verify count logged)

### 5.4 MetadataPipeline — malformed JSON + missing ad_account_id
**File:** `test/ad_butler/sync/metadata_pipeline_test.exs`
**Audit finding:** T5/MEDIUM

- [x] Add test: `Broadway.test_message(MetadataPipeline, "not-json")` → message failed
      with `:invalid_payload`
- [x] Add test: `Broadway.test_message(MetadataPipeline, ~s({"wrong_key": "abc"}))` →
      message failed with `:invalid_payload`

### 5.5 parse_budget/1 edge cases
**File:** `test/ad_butler/sync/metadata_pipeline_test.exs` (or a dedicated unit test)
**Audit finding:** T6/MEDIUM — nil, integer, non-numeric string paths untested.

- [x] Test `parse_budget(nil)` → `nil`
- [x] Test `parse_budget(1000)` → `1000` (integer passthrough)
- [x] Test `parse_budget("2500")` → `2500`
- [x] Test `parse_budget("abc")` → `nil`
- [x] Test `parse_budget("12abc")` → `nil` (partial parse rejected)

### 5.6 RateLimitStore — GenServer + cleanup
**File:** `test/ad_butler/meta/rate_limit_store_test.exs` (new file)
**Audit finding:** T7/MEDIUM

- [x] Test: `start_supervised(RateLimitStore)` creates `:meta_rate_limits` ETS table
- [x] Test: insert stale entry (ts > 1 h ago), send `:cleanup` message, assert entry deleted
- [x] Test: insert fresh entry, send `:cleanup` message, assert entry still present

---

## Phase 6: Architecture Hygiene [P3]

### 6.1 Add write_concurrency to RateLimitStore ETS table
**File:** `lib/ad_butler/meta/rate_limit_store.ex:23`
**Audit finding:** P/MEDIUM — global table lock on writes serializes concurrent HTTP writers.

- [x] Add `write_concurrency: true` to `:ets.new/2` options
      (`:auto` on OTP 26+ is preferred; check OTP version in `.tool-versions` / `mix.exs`)

### 6.2 Chunk Oban.insert_all in SyncAllConnectionsWorker
**File:** `lib/ad_butler/workers/sync_all_connections_worker.ex:22-29`
**Audit finding:** P/MEDIUM — 1000-row single INSERT causes latency spikes.

- [x] After task 3.3 (cursor batching), `Oban.insert_all` is already called in chunks of 200
      — verify this task is satisfied by 3.3 or add explicit `Enum.chunk_every(200)` here

### 6.3 Wire AMQPBasicBehaviour into Publisher or remove it
**File:** `lib/ad_butler/amqp_basic_behaviour.ex`, `lib/ad_butler/messaging/publisher.ex`
**Audit finding:** A/LOW — behaviour defined, never injected; misleading dead code.

- [x] Option A (preferred): Add `@amqp_basic Application.get_env(:ad_butler, :amqp_basic, AMQP.Basic)`
      to `Publisher` and route `AMQP.Basic.publish/5` through it — enables mock in tests
- [x] Option B: Delete `amqp_basic_behaviour.ex` if injection is not desired
- [x] If Option A: add `amqp_basic` key to test config; update publisher tests to use mock

### 6.4 Fix RequireAuthenticated hardcoded redirect path
**File:** `lib/ad_butler_web/plugs/require_authenticated.ex:22,31`
**Audit finding:** A/LOW — `"/"` bypasses compile-time route verification.

- [x] Replace `redirect(to: "/")` with `redirect(to: ~p"/")` (two occurrences)
- [x] Verify `import Phoenix.VerifiedRoutes` or `use AdButlerWeb, :controller` provides `~p`

### 6.5 Run mix hex.audit and document result
**Audit finding:** Deps/HIGH — Bash permission denied during audit; CVE status unverified.

- [x] Run `mix hex.audit` and confirm 0 CVEs / 0 retired packages
- [x] Add `mix hex.audit` to the `precommit` alias in `mix.exs` so it runs automatically

---

## Phase 7: Verification

- [x] `mix precommit` — compile, format, test (all 133+ tests pass)
- [x] `mix credo --strict` — fix the 2 pre-existing implicit-try warnings in `publisher.ex`
      while editing that file in Phase 1
- [x] `mix hex.audit` — 0 vulnerabilities
- [x] Manual smoke test: trigger `SyncAllConnectionsWorker.perform/1` in dev; verify
      RabbitMQ message flow end-to-end
- [x] Review `mix xref graph --source lib/ad_butler/ads.ex` — confirm `Accounts.MetaConnection`
      no longer appears as compile-time dependency

---

## Task Summary

| Phase | Tasks | Priority | Est. Effort |
|-------|-------|----------|-------------|
| 1 — Critical concurrency | 13 | P0 | 6–8 h |
| 2 — Boundary violations | 8 | P0 | 2–3 h |
| 3 — High-impact perf | 14 | P1 | 4–5 h |
| 4 — Security | 6 | P1 | 1–2 h |
| 5 — Test coverage | 18 | P2 | 3–4 h |
| 6 — Hygiene | 8 | P3 | 1–2 h |
| 7 — Verification | 5 | — | 0.5 h |
| **Total** | **72** | | **17–25 h** |

## Risks

1. **Publisher pool changes break test isolation** — `Publisher` is currently started only
   in non-test env; pool adds complexity. Use `Broadway.DummyProducer` pattern: gate pool
   behind `env != :test` in Application.
2. **bulk_validate removal** — Data comes from Meta API (trusted), but `Map.take` by
   known fields is still essential. If `@required` is a module attribute (not a function),
   it won't be accessible at runtime — expose it via `required_fields/0` function or
   pattern-match the field list from the schema.
3. **Phase 1.3 (batch MetaConnections) + Phase 2.1 (remove Accounts alias) must land together**
   — removing the alias before the batch-load refactor would leave the pipeline broken.
   Implement 1.3 first, then 2.1 as a cleanup pass.
