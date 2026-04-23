# Test Health Audit — 2026-04-23

**Score: 79/100**

## Issues Found

### MEDIUM — [T1] `AuthControllerTest` missing `set_mox_global` setup
`test/ad_butler_web/controllers/auth_controller_test.exs` uses `expect`/`stub` on `ClientMock` but has neither `setup :set_mox_global` nor `setup :set_mox_from_context`. Works today because the test is `async: false`, but if the controller dispatch ever spawns a process mock lookups will fail silently. Every other `async: false` Mox file uses `setup :set_mox_global`.

### MEDIUM — [T2] Five `Meta.Client` behaviour callbacks have zero unit tests
`list_campaigns/3`, `list_ad_sets/3`, `list_ads/3`, `refresh_token/1`, `get_creative/2` — all implemented in `client.ex` but not tested directly. Rate-limit header parsing in `make_request/3` (used by three of these) is exercised only via `list_ad_accounts/1`.

### MEDIUM — [T3] `MetadataPipeline` — `{:error, :unauthorized}` path untested
`sync_ad_account/2` tests `rate_limit_exceeded` but not `unauthorized` returned from `list_campaigns`/`list_ad_sets`/`list_ads`.

### MEDIUM — [T4] `MetadataPipeline` — orphan ad-set drop path untested
`upsert_ad_sets/3` silently drops ad sets whose `campaign_id` resolves to nil and continues without failing the message. There's a test for orphan ads but not for orphan ad sets.

### MEDIUM — [T5] `MetadataPipeline` — malformed JSON message path untested
`handle_message/3` returns `Message.failed(message, :invalid_payload)` for non-JSON input and JSON missing `ad_account_id`, but neither branch has a test.

### MEDIUM — [T6] `parse_budget/1` edge cases untested
Only the `"1000"` string case is exercised. `nil`, plain integer, and non-numeric string (`"abc"` → `nil`) paths are untested. Silent nil writes into integer columns from malformed API data would go undetected.

### MEDIUM — [T7] `RateLimitStore` GenServer has no tests
The cleanup logic via `handle_info(:cleanup, _)` has no test. A `start_supervised(RateLimitStore)` + manual ETS insert + `send(pid, :cleanup)` + assertion would fully cover it.

### LOW — [T8] Factory association-divergence not guarded by a test
`ad_set_factory` and `ad_factory` warn (via comments) that overriding only `ad_account:` or `ad_set:` diverges FK IDs. No test exercises this to produce a clear error.

### LOW — [T9] `ConnCase` does not import `Factory`
Requires each controller test to repeat `import AdButler.Factory` manually.

## Clean Areas

- `verify_on_exit!` present in all 6 files that use `expect`; no leaked expectations
- `async: false` justified in all Broadway/PlugAttack/global-ETS tests
- `set_mox_from_context` correctly paired with `async: true` in AccountsTest and TokenRefreshWorkerTest
- Oban: `perform_job/2` throughout; no `drain_queue` anti-pattern; `assert_enqueued`/`refute_enqueued` correct
- Broadway: `test_message/2` + `assert_receive {:ack, ^ref, ...}` with 2 s timeout used correctly
- SQL sandbox: `Sandbox.mode(:manual)` + `Sandbox.start_owner!` pattern correct
- Token encryption: raw DB bytes checked to differ from plaintext — genuine verification
- All six OAuth error branches covered in AuthControllerTest
- Rate-limit snooze, unauthorized cancel, and generic retry paths covered in both worker tests
- Integration test correctly tagged `:integration`, excluded from default run, no `Process.sleep`
- `replay_dlq_test.exs` has unit stub test + integration test covering nack-on-publish-failure

| Criterion | Score | Notes |
|---|---|---|
| Coverage >70% | 22/30 | Estimated ~60%; upsert_ad_set/ad missing direct tests |
| No flaky patterns | 15/20 | Process.sleep(100) in replay_dlq_test.exs:33 |
| async: true where possible | 15/15 | All async: false usages justified |
| verify_on_exit! in Mox tests | 15/15 | All 6 Mox modules comply |
| Test duration | 10/10 | No timing issues |
| Error paths | 4/10 | Several missing branches |

## Issues

**[T1] Process.sleep(100) in integration test — test/mix/tasks/replay_dlq_test.exs:33**
Flaky — too short under load, vacuously passes with 0 messages. Pre-existing W10. Replace with AMQP consumer subscription + assert_receive or polling retry with timeout.

**[T2] Sandbox.allow gap — test/ad_butler/sync/scheduler_test.exs**
Pre-existing W8. Scheduler process not covered by test sandbox. Add:
`Ecto.Adapters.SQL.Sandbox.allow(AdButler.Repo, self(), pid)` after start_supervised.

**[T3] metadata_pipeline_test.exs — unknown ad_account_id test missing zero-row assertion**
Success test checks Repo.aggregate count = 0 but failure test doesn't. Inconsistent coverage.

**[T4] fetch_ad_accounts_worker_test.exs:111 — publish payload content never asserted**
Idempotency test expects PublisherMock.publish 2x but never validates payload. Payload regression undetectable.

**[T5] Coverage gap — upsert_ad_set/2, upsert_ad/2 have no direct idempotency tests**
Only covered indirectly via pipeline. Mirror upsert_ad_account/2 test pattern.

**[T6] Coverage gap — get_campaign!/2 success path never directly asserted**

## Clean Areas

factory.ex fully compliant after all fixes. ads_test.exs: async: true, proper isolation, idempotency verified. fetch_ad_accounts_worker_test.exs: all 5 branches covered. metadata_pipeline_test.exs: Broadway test_message pattern, no sleep. scheduler_test.exs: sys.get_state/1 sync, no sleep. Mox discipline: boundary mocks only, all implement behaviours.
