# Review: Week 2 — Sync Pipeline & Ads Context

**Verdict: REQUIRES CHANGES**
**Date**: 2026-04-22
**Agents**: elixir-reviewer, oban-specialist, testing-reviewer, security-analyzer

---

## Summary

5 BLOCKERS · 10 WARNINGS · 8 SUGGESTIONS

Tenant isolation (`scope/2`) is correctly implemented across all user-facing Ads context functions — no cross-tenant gaps found. SQL injection, atom exhaustion, unsafe deserialization: all clean. Core Oban patterns are structurally sound. Issues are concentrated in Publisher reliability (crash on init, silent channel death), Oban idempotency (missing unique constraint, publish failure swallowed), and test infrastructure (factory inconsistency, Sandbox allow gap).

---

## BLOCKERS

### [B1] Publisher.init/1 crashes GenServer if RabbitMQ is unavailable at boot
**File**: `lib/ad_butler/messaging/publisher.ex:47`
**Agent**: elixir-reviewer

`connect/0` hard-pattern-matches `{:ok, conn} = AMQP.Connection.open(url)`. If the broker is down at node boot (common during deploys), the GenServer crashes, the supervisor retries with backoff, and can escalate to kill the application supervisor.

**Fix**: `init/1` should return `{:ok, %{conn: nil, channel: nil}}` and `send_after(self(), :connect, 0)`. Guard `handle_call({:publish,...})` against nil channel, returning `{:error, :not_connected}`.

---

### [B2] Channel death is silently undetected
**File**: `lib/ad_butler/messaging/publisher.ex:38-41, 49`
**Agent**: elixir-reviewer

`Process.monitor(conn.pid)` monitors the connection but not the channel. If only the channel dies, no `:DOWN` fires. Subsequent `AMQP.Basic.publish` calls silently fail or raise inside `handle_call`, leaving the GenServer with a stale channel. Messages are lost with no signal to callers. The `:DOWN` `handle_info` clause also lacks `@impl GenServer`.

**Fix**: Also `Process.monitor(channel.pid)`. Store both monitor refs in state. Handle `:DOWN` for either. Add `@impl GenServer`.

---

### [B3] AMQP publish failure is silently swallowed — job returns :ok
**File**: `lib/ad_butler/workers/fetch_ad_accounts_worker.ex:42-49`
**Agent**: oban-specialist

`publisher().publish/1` is called inside `sync_account/2`. If publish fails, the function logs a warning and returns. `Enum.each` discards all return values so `perform/1` returns `:ok` — the Oban job is marked `completed` even though downstream Broadway consumers never received the trigger event.

**Fix**: Collect publish results from `sync_account/2`. Return `{:error, reason}` from `perform/1` if any publish fails to trigger Oban retry. Or: enqueue a separate Oban job per account instead of publishing directly, making publish its own retriable unit.

---

### [B4] FetchAdAccountsWorker has no unique constraint — Scheduler creates duplicate jobs
**File**: `lib/ad_butler/workers/fetch_ad_accounts_worker.ex:3` + `lib/ad_butler/sync/scheduler.ex:15-19`
**Agent**: oban-specialist

`use Oban.Worker` has no `unique:` option. `Scheduler.handle_info` fires on every GenServer boot. A process restart or node bounce enqueues duplicate jobs for the same `meta_connection_id`. Duplicate upserts are harmless but each publishes independently to RabbitMQ, causing multiple "full sync" triggers per account per run.

**Fix**: Add `unique: [period: 300, keys: [:meta_connection_id]]` to the `use Oban.Worker` declaration.

---

### [B5] Factory `ad_set_factory` creates structurally inconsistent rows
**File**: `test/support/factory.ex:50-61`
**Agent**: testing-reviewer

`ad_set_factory` calls `campaign = build(:campaign)` then sets `ad_account: campaign.ad_account`. When callers override `ad_account: aa` and `campaign: c`, the resulting row has `ad_set.ad_account_id = aa.id` but `campaign.ad_account_id != aa.id` — silent data inconsistency. All `insert_ad_set_for/2` calls in `ads_test.exs` hit this path. Tests pass today only because there is no FK constraint enforcing campaign↔ad_account consistency.

**Fix**: The helper `insert_ad_set_for(aa, campaign)` must ensure the campaign belongs to the same ad_account. Rebuild the campaign from the given `aa` inside the factory call, or document the constraint explicitly.

---

## WARNINGS

### [W1] Scheduler fires once and never reschedules
**File**: `lib/ad_butler/sync/scheduler.ex:22-33`
**Agent**: elixir-reviewer

`init/1` sends `:schedule_all` once after 5 seconds. `handle_info` does not re-send. Connections created after startup are never synced until node restart. No log, no error — silent correctness gap.

**Recommendation**: If one-shot is intentional, replace with an `Oban.Plugin.Cron` entry and remove the GenServer. If periodic sync is needed, add `Process.send_after(self(), :schedule_all, @interval)` at the end of `handle_info`.

---

### [W2] N+1 DB query in handle_batch — one connection load per message
**File**: `lib/ad_butler/sync/metadata_pipeline.ex:64`
**Agent**: elixir-reviewer

`sync_ad_account/1` calls `Accounts.get_meta_connection!` per message. A batch of 10 messages sharing the same connection executes 10 identical queries, negating the batching benefit.

**Recommendation**: In `handle_batch/4`, collect unique `meta_connection_id` values, load all in one `Repo.all(where: id in ^ids)`, pass map into `process_batch_group`.

---

### [W3] `:cancel` on first 401 is too aggressive
**File**: `lib/ad_butler/workers/fetch_ad_accounts_worker.ex:29-31`
**Agent**: oban-specialist

A single `:unauthorized` response immediately marks the connection `"revoked"` and permanently cancels the job. Meta's API can return transient 401s. The app already has a `TokenRefreshSweepWorker` acknowledging tokens can go temporarily stale.

**Recommendation**: Return `{:error, :unauthorized}` on early attempts; only `update_meta_connection` + `{:cancel, ...}` when `job.attempt >= 3`.

---

### [W4] `handle_message/3` passes unvalidated `ad_account_id` to `Repo.get/2`
**File**: `lib/ad_butler/sync/metadata_pipeline.ex:29-45`
**Agent**: security-analyzer

`ad_account_id` from `Jason.decode` is passed straight to `Repo.get(AdAccount, id)`. If the value is not UUID-shaped (integer, nil, malformed string), `Repo.get/2` raises `Ecto.Query.CastError` — a processor crash that retries until DLQ. A single malformed message stalls a processor partition.

**Recommendation**: Validate with `Ecto.UUID.cast(id)` before the DB lookup; on failure, `Message.failed(message, :invalid_uuid)`.

---

### [W5] `parse_budget/1` raises on non-integer strings from Meta API
**File**: `lib/ad_butler/sync/metadata_pipeline.ex:152-154`
**Agent**: security-analyzer

`String.to_integer/1` raises on `"1.50"`, `""`, `"unlimited"`, etc. One malformed budget field crashes the batch group and re-enqueues the whole batch.

**Recommendation**: Use `Integer.parse/1` returning `nil` on `:error`, plus a catch-all `defp parse_budget(_), do: nil`.

---

### [W6] `list_all_active_meta_connections/0` is unbounded — thundering herd at scale
**File**: `lib/ad_butler/accounts.ex:83-88` / `lib/ad_butler/sync/scheduler.ex:29`
**Agents**: security-analyzer, elixir-reviewer (noted in risks)

No `LIMIT`, no pagination, no streaming. At 10k+ connections this materialises the full row set in RAM and floods Oban within one tick (no jitter), creating a thundering herd on Meta's rate limits.

**Recommendation**: Use `Repo.stream/2` inside `Repo.transaction/1`, or cursor-paginate. Add `schedule_in: :rand.uniform(600)` to jitter Oban fan-out.

---

### [W7] AMQP credentials may leak via `inspect(reason)` on connection failure
**File**: `lib/ad_butler/messaging/publisher.ex:39`
**Agent**: security-analyzer

Some `AMQP.Connection` failure terms embed the connection URL — including the password from `amqp://user:pass@host`. `:filter_parameters` only scrubs Plug params, not Logger metadata.

**Recommendation**: Sanitize `reason` before logging, or use the `username`/`password` keyword options of `AMQP.Connection.open/2` instead of an inline URL with credentials.

---

### [W8] `:sys.get_state/1` sync doesn't guarantee Oban DB write is visible to the test
**File**: `test/ad_butler/sync/scheduler_test.exs:34`
**Agent**: testing-reviewer

`:sys.get_state(pid)` ensures `handle_info` returned, but `Oban.insert/1` writes to the DB from the GenServer process. Under Ecto Sandbox `:manual` mode that process must be explicitly allowed — otherwise the insert fails silently or writes to a connection the test process cannot see.

**Recommendation**: Add `Ecto.Adapters.SQL.Sandbox.allow(AdButler.Repo, self(), pid)` in setup after `start_supervised`.

---

### [W9] DLQ replay blindly re-publishes poison messages
**File**: `lib/mix/tasks/ad_butler.replay_dlq.ex:32-42`
**Agent**: security-analyzer

`drain_dlq/3` re-publishes every DLQ payload with no validation. A message DLQ'd for being malformed (e.g., non-UUID `ad_account_id`) gets resurrected and stalls the pipeline again.

**Recommendation**: Decode + shape-validate each payload before republishing. Add an `x-replay-count` header; drop after N replays. Log payload hash per replayed message for audit.

---

### [W10] `Process.sleep(100)` in integration test
**File**: `test/mix/tasks/replay_dlq_test.exs:33`
**Agent**: testing-reviewer

A bare sleep waits for RabbitMQ to route fanout messages. Too short under load (vacuously passes with 0 messages), too long otherwise.

**Recommendation**: Poll `AMQP.Queue.declare(channel, @dlq, passive: true)` in a loop until `message_count == 3` with a max-wait timeout.

---

## SUGGESTIONS

| # | Area | Finding |
|---|------|---------|
| S1 | Elixir | `application.ex` `++` chain with inline `if` — extract named variable `messaging_children` for clarity |
| S2 | Elixir | Ads with unresolved `ad_set_id` silently inserted as orphans — replace `Enum.each` with error-collecting reduce |
| S3 | Oban | `:snooze` consumes an attempt in standard Oban — verify Oban Pro Smart Engine; if not used, raise `max_attempts` to 10 |
| S4 | Testing | Integration `SyncPipelineTest` first test is a duplicate of the unit test — use real Publisher or remove it |
| S5 | Testing | Missing `upsert_ad_set/2` and `upsert_ad/2` idempotency tests — mirror the `upsert_campaign/2` test pattern |
| S6 | Testing | `Repo.aggregate(..., :count)` in idempotency tests — replace with scoped `Ads.list_campaigns(user)` assertions |
| S7 | Security | `get_ad_account_by_meta_id/2` — rename or `@doc false` to prevent future misuse as a user-facing query |
| S8 | Security | Status `validate_inclusion` missing on `Ad`, `AdSet`, `Creative` — mirror the `Campaign` pattern |

---

## Pre-existing Issues (not introduced in this diff)

- `[F]` credo nesting violation in `lib/ad_butler_web/plugs/plug_attack.ex:23` — pre-existing
- `[D]` nested module alias suggestions across test files — cosmetic, pre-existing pattern

---

## Files Not Covered

Integration tests (`@moduletag :integration`) require live RabbitMQ and were not run. Dialyzer not run.
