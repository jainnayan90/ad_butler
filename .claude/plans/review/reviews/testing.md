# Test Review: ad_butler test suite (Week 2)

**Status: PASS WITH WARNINGS | 0 Critical, 7 Warnings, 3 Suggestions**

All prior findings (T-C1–T-C4, T-W3, W8, S4, S5) confirmed fixed. Iron Laws clean.

⚠️ EXTRACTED FROM AGENT MESSAGE (agent could not write to output_file)

---

## Iron Law Violations

None.

---

## Warnings

### W1: `Process.sleep(100)` in DLQ replay test — race condition
**`test/mix/tasks/replay_dlq_test.exs:36`**

Races against RabbitMQ message routing; intermittently causes `dlq_count` to be non-zero. Replace with publisher confirms or a polling helper.

### W2: `get_campaign!/2` missing happy-path test
**`test/ad_butler/ads_test.exs:156`**

Only the cross-tenant error case is tested. No test asserts a user can retrieve their own campaign. Compare `get_ad_account!/2` which tests both paths.

### W3: `get_ad_set!/2` and `get_ad!/2` missing happy-path tests
**`test/ad_butler/ads_test.exs:358,376`**

Same asymmetry as W2 — only the cross-tenant raise is exercised.

### W4: `list_ads/2` missing filter-option tests
**`test/ad_butler/ads_test.exs:429`**

`list_campaigns/2` and `list_ad_sets/2` cover filter opts. If `list_ads/2` accepts opts, those paths are uncovered.

### W5: PublisherTest leaks AMQP connection on mid-test failure
**`test/ad_butler/messaging/publisher_test.exs:25`**

Raw `AMQP.Connection` opened for verification has no `on_exit` close guard. `start_supervised` only tears down the `Publisher` GenServer. Add `on_exit(fn -> AMQP.Connection.close(conn) end)`.

### W6: `SyncAllConnectionsWorker` test doesn't assert string-key job args
**`test/ad_butler/sync/scheduler_test.exs:33`**

`all_enqueued(worker: FetchAdAccountsWorker)` only checks count. Should add `assert_enqueued(args: %{"meta_connection_id" => conn.id})` for each job to guard against atom-key regression.

### W7: Integration test name is misleading
**`test/integration/sync_pipeline_test.exs:20`**

Named "full sync flow: fetch → publish → Broadway consumes → upserts campaigns" but `PublisherMock` returns `:ok` without routing to Broadway. Broadway consumption is tested separately in `metadata_pipeline_test.exs`. Rename to avoid confusion.

---

## Suggestions

### S1: `upsert_campaign/2` describe missing field assertion on insert
**`test/ad_butler/ads_test.exs:173`**

First call result `{:ok, _}` is matched but no field is asserted. Add `assert campaign.meta_id == "campaign_001"`.

### S2: `ad_set_factory/1` uses `struct/2` bypassing ExMachina attribute merging
**`test/support/factory.ex:50`**

`struct(AdSet, %{...})` skips `merge_attributes/2`. Unknown keys passed as overrides are silently dropped.

### S3: `upsert_creative/2` tests omit `ad_account_id` assertion
**`test/ad_butler/ads_test.exs:301`**

Both tests check `meta_id`/`name` but not `creative.ad_account_id == aa.id`.
