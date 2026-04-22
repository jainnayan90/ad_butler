# Test Health Audit

**Score: 81/100**

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
