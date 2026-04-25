# Plan: Health Audit Findings — Apr 23 2026

**Source:** `.claude/audit/summaries/project-health-2026-04-23.md`
**Findings:** ARCH-1, ARCH-2, ARCH-3, ARCH-4, ARCH-5, SEC-1, SEC-2, PERF-1, PERF-2, TEST-1, TEST-2, TEST-3, DEPS-2, DEPS-3
**Branch:** create from `module_documentation_and_audit_fixes` or new branch off main

---

## Phase 1 — Deploy Blockers (SEC-1, PERF-1, ARCH-3, SEC-2, ARCH-2)

These must land before the next production deployment.

- [x] **[SEC-1]** Move Meta Graph API access tokens from URL query params to `Authorization: Bearer` header in `lib/ad_butler/meta/client.ex` — added `auth_header/1`, updated all 6 functions, no test changes needed (Req.Test stubs don't inspect query params)

- [x] **[PERF-1 + ARCH-3]** Fix Broadway `prefetch_count` and stale comment in `lib/ad_butler/sync/metadata_pipeline.ex` — comment corrected, `prefetch_count: 150`

- [x] **[SEC-2]** Tighten OAuth callback rate limit from 10/min to 3/min in `lib/ad_butler_web/plugs/plug_attack.ex` — limit: 3, @moduledoc updated, plug_attack_test.exs updated (3/4 thresholds), auth_controller_test.exs given unique IPs per test to avoid bucket collision

- [x] **[ARCH-2]** Fail the node on permanent RabbitMQ topology failure — `System.stop(1)` added to `do_setup_rabbitmq_topology(0)` with explanatory log

---

## Phase 2 — Architecture (ARCH-1, ARCH-4, ARCH-5)

- [x] **[ARCH-1]** Decouple `scope` helpers from `Accounts` context in `lib/ad_butler/ads.ex` — scope helpers now accept `mc_ids` list; public list functions hoist Accounts call; added `mc_ids` overloads for `list_ad_accounts`, `list_campaigns`, `list_ad_sets`, `list_ads` with function heads for default args

- [x] **[ARCH-4]** Document cross-context intent in `MetadataPipeline` — @moduledoc updated, inline comment added above `Accounts.get_meta_connections_by_ids` call

- [x] **[ARCH-5]** Deduplicate bulk upsert scaffolding in `lib/ad_butler/ads.ex` — extracted `do_bulk_upsert/4`, all three public functions are now thin wrappers

---

## Phase 3 — Performance (PERF-2)

- [x] **[PERF-2]** Replace sequential `Oban.insert/1` loop with `Oban.insert_all/1` in `lib/ad_butler/workers/token_refresh_sweep_worker.ex` — renamed to `schedule_changeset/1`, bulk enqueue via `oban_mod().insert_all/1` (injectable for tests), @moduledoc updated

---

## Phase 4 — Test Coverage (TEST-1, TEST-2, TEST-3)

- [x] **[TEST-1]** Add tests for three untested public `Accounts` functions in `test/ad_butler/accounts_test.exs` — `get_meta_connections_by_ids/1` (4 cases), `stream_active_meta_connections/1` (2 cases), `list_meta_connection_ids_for_user/1` (3 cases)

- [x] **[TEST-2]** Add `{:error, :all_enqueues_failed}` test path in `test/ad_butler/workers/token_refresh_sweep_worker_test.exs` — used `ObanMock` (Mox) via injectable `oban_mod()`, test file changed to async: false

- [x] **[TEST-3]** Add error path tests for `list_ads` in `test/ad_butler/sync/metadata_pipeline_test.exs` — `:unauthorized` and `:rate_limit_exceeded` paths for `list_ads`, rate-limit log assertion via `capture_log`

---

## Phase 5 — Dependencies (DEPS-2, DEPS-3)

- [x] **[DEPS-2]** `broadway_rabbitmq 0.9` does not exist on Hex (latest: 0.8.2) — kept `~> 0.8`, noted as future work when 0.9 is released

- [x] **[DEPS-3]** `req ~> 0.5` already permits `0.6.x` (Elixir `~>` minor semantics: `>= 0.5.0 and < 1.0.0`) — no change needed; `req 0.6` also does not exist yet

---

## Verification

- [x] `mix compile --warnings-as-errors`
- [x] `mix format --check-formatted`
- [x] `mix credo --strict`
- [x] `mix test` — 180 tests, 0 failures, 8 excluded
- [x] Confirm no `access_token=` appears in request params in `client.ex` after SEC-1 (grep check)
- [x] Confirm `prefetch_count: 150` is present in pipeline producer config after PERF-1

---

## Risks

1. **SEC-1** — Meta Graph API must support `Authorization: Bearer` header (it does; this is the documented auth method for server-side calls). Tests using Bypass must be updated to stub the header check instead of query param.
2. **ARCH-2** — `System.stop(1)` on topology failure is intentionally drastic: if RabbitMQ is briefly unavailable at boot, the node will halt. This is correct for production (fail-fast beats silent data loss) but dev boots need RabbitMQ running. Document in dev setup notes.
3. **DEPS-2** — `broadway_rabbitmq 0.9` may require config key changes. Read changelog before breaking.
