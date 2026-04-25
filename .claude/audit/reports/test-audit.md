# Test Health Audit
Date: 2026-04-25

## Score: 80/100

## Issues Found

### 1. Coverage at 65.38% — below 70% threshold
SyncAllConnectionsWorker has no test file. Every other worker has tests. Per-module coverage
is 90-100% where tests exist; the missing worker drags the aggregate below threshold.
Fix: Add test/ad_butler/workers/sync_all_connections_worker_test.exs.

### 2. Process.sleep in integration test
`test/mix/tasks/replay_dlq_test.exs:186`

wait_for_queue_depth/4 polling helper uses Process.sleep(20) in a loop. Repeated sleeps
against a RabbitMQ broker are a flaky-test risk under CI load.

### 3. `usage_handler_test.exs` could run async
The telemetry handler is registered under static key "llm-usage-logger". Generating a
unique key per test (e.g. "llm-usage-logger-#{make_ref()}") would make this module safe
for async: true.

### 4. LiveView tests cover happy paths only
`test/ad_butler_web/live/dashboard_live_test.exs`
`test/ad_butler_web/live/campaigns_live_test.exs`

Missing: error branch on DashboardLive data load failure; malformed/nil ad_account_id
in CampaignsLive filter handler.

### 5. Sync-heavy test suite — 52.4s / 56.1s total is synchronous
14 of 24 modules run async: false. Most are justified. Usage_handler fix (issue 3) would
help. Watch the trend as test count grows.

## Clean Areas
All 7 Mox-using test files correctly call setup :verify_on_exit!. Every async: false
decision is documented with an inline comment. Factory coverage across all major schemas.
198 tests passing, 0 failures.

## Score Breakdown

| Criterion | Score | Max | Notes |
|-----------|-------|-----|-------|
| Coverage >70% | 25 | 30 | 65.38% — SyncAllConnectionsWorker untested |
| No flaky test patterns | 15 | 20 | 1x Process.sleep in integration polling loop |
| async: true where possible | 13 | 15 | usage_handler_test could be async |
| verify_on_exit! in Mox tests | 15 | 15 | All 7 Mox files compliant |
| Reasonable test duration | 7 | 10 | 56s total, 52s sync |
| Error paths tested | 5 | 10 | Worker/context layer good; LiveView happy-path only |
