# Test Health Audit — 2026-04-23

**Score: 82/100**

Deductions: -5 coverage gap (3 untested public accounts.ex functions), -5 flakiness risk (polling sleep in integration test), -5 missing error-path test (sweep worker), -3 partial filter coverage.

## Issues Found

### [T1] `wait_for_queue_depth` 500ms deadline may be too tight for CI
`test/mix/tasks/replay_dlq_test.exs` ~line 178.
Busy-polls with 20ms sleep up to a 500ms deadline. Under CI load RabbitMQ routing may exceed 500ms → flaky `assert main_count == 3`. Test is `@moduletag :integration` so excluded from default suite, but risk is real in integration CI. Raise deadline to 2000ms. -5 pts.

### [T2] Three public `Accounts` context functions have zero tests
- `get_meta_connections_by_ids/1` — returns a map keyed by ID; never tested. Edge cases: empty list.
- `stream_active_meta_connections/1` — streaming path has no coverage.
- `list_meta_connection_ids_for_user/1` — only exercised indirectly through Ads scoping.
-5 pts.

### [T3] `TokenRefreshSweepWorker` `{:error, :all_enqueues_failed}` path untested
`test/ad_butler/workers/token_refresh_sweep_worker_test.exs`
Branch has no test. -5 pts.

### [T4] `list_ads/2` with `:ad_set_id` filter untested
`test/ad_butler/ads_test.exs`
Only user-isolation tested. `:ad_set_id` filter in `apply_ad_filters/2` has no test. -3 pts.

### [T5] `MetadataPipeline` — `list_ads` error paths untested
`test/ad_butler/sync/metadata_pipeline_test.exs`
`list_campaigns` and `list_ad_sets` unauthorized/rate-limit paths tested; `list_ads` returning `{:error, :unauthorized}` or `{:error, :rate_limit_exceeded}` has no test.

### [T6] `setup` ordering in `MetadataPipelineTest` — minor
`setup :verify_on_exit!` appears before `setup :set_mox_global`. Canonical Mox ordering is global-mode first. Harmless but inconsistent.

## Suggestions

- `list_expiring_meta_connections/2` has no direct test (only exercised via sweep worker).
- `ConnCase` does not import `AdButler.Factory` — repeated manual imports.
- `bulk_strip_and_filter/2` drop-log path has only indirect coverage via pipeline orphan test.

## Clean (one line each)

- async safety: all `async: false` usages justified (Broadway, ETS, global Mox, Application.put_env). ✓
- Mox discipline: `verify_on_exit!` in all 5 Mox modules; both mocks implement defined behaviours. ✓
- Factory quality: `sequence/2` on all unique fields; FK-consistent associations; all required fields present. ✓
- Oban testing: `use Oban.Testing` + `perform_job/2`; string-keyed args; `assert_enqueued` correct. ✓
- Broadway testing: `Broadway.test_message/2` + `assert_receive {:ack, ...}, 2_000` correct; no sleep in Broadway tests. ✓
- SQL Sandbox: `Sandbox.mode(:manual)` + `Sandbox.start_owner!/2` with `shared: not tags[:async]` correct. ✓
- Auth coverage: all 7 OAuth branches covered including truncation test. ✓
- Worker error paths: rate-limit snooze, unauthorized cancel, token-revoked cancel, invalid UUID cancel all tested. ✓
- Integration test hygiene: `@moduletag :integration` excludes; AMQP connections closed in on_exit; queues purged. ✓
- Encryption verification: raw DB bytes asserted different from plaintext. ✓
