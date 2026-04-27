# Testing Review

## BLOCKER

- `test/ad_butler/workers/insights_conversion_worker_test.exs` — Missing test for "inactive ad accounts are not included". `InsightsSchedulerWorkerTest` covers this at line 51; the structurally identical `InsightsConversionWorkerTest` does not. The worker calls `list_ad_accounts_internal/0` which filters by status — an untested code-path in a new worker.

- `test/ad_butler/workers/insights_conversion_worker_test.exs` and `test/ad_butler/workers/insights_scheduler_worker_test.exs` — Neither test covers the publish-failure path where `perform/1` should return `{:error, reason}`. The worker has this logic explicitly (worker lines 34–41); it is uncovered in both new files.

## WARNING

- `test/ad_butler/ads/ads_insights_test.exs` — `get_7d_insights/1` and `get_30d_baseline/1` have no tenant isolation tests. Both accept an unscoped `ad_id`. If callers pass ad IDs derived from user input, CLAUDE.md requires a two-user cross-tenant assertion.

- `test/ad_butler/sync/insights_pipeline_test.exs` — No cross-tenant assertion. Only one ad_account is used per test; there is no check that rows for a different account are not written or not returned.

- `test/ad_butler/workers/mat_view_refresh_worker_test.exs:27–37` — The `"passes the period to the refresh fn"` test calls `Application.put_env` directly without a per-test `on_exit`. Relies on module-level `on_exit` from `setup do`. Safe with `async: false` today but fragile.

- `test/ad_butler/workers/partition_manager_worker_test.exs:22–38` — `create_old_partition/0` derives partition name from `old_date.year`, but `:calendar.iso_week_number/1` returns `{iso_year, week}` where `iso_year` can differ from calendar year near year boundaries. The computed `partition_name` and actual partition bounds can diverge silently.

## SUGGESTION

- `test/ad_butler/llm_test.exs:28` — `insert_usage!/1` named with `!` bang but returns `:ok` rather than raising. The `!` convention means "raises on error". Rename to avoid confusion.

- `test/ad_butler/ads/ads_insights_test.exs:16–29` — `insert_insight_row/3` manually binary-encodes UUIDs for raw `insert_all`. A comment explaining why (`insights_daily` has no Ecto schema) would prevent future maintainers from "fixing" it incorrectly.

- `test/mix/tasks/replay_dlq_test.exs:179–192` — `wait_for_queue_depth/4` using `receive/after` instead of `Process.sleep` is correct and matches CLAUDE.md. Good pattern.

## PRE-EXISTING

- `test/ad_butler_web/controllers/auth_controller_test.exs` — `async: false` + `set_mox_global` + per-test unique remote IP for PlugAttack isolation; predates this branch.
- `test/ad_butler/meta/client_test.exs` — Direct `:ets.insert/2` and `:ets.delete/2` in tests without encapsulation; predates this branch.
