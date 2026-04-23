# Week-3 Post-Review Fixes

**Source**: `.claude/plans/week-3-review-fixes/reviews/week-3-review.md`
**Date**: 2026-04-22
**Decision**: Fix all blockers + warnings + key test gaps from week-3 review

---

## Phase 1: Blockers

- [x] [B1] Fix Oban snooze units + update test — `{:snooze, {15, :minutes}}` tuple syntax; test pattern matches literal
  - **File**: `lib/ad_butler/workers/fetch_ad_accounts_worker.ex:50`,
    `test/ad_butler/workers/fetch_ad_accounts_worker_test.exs:58-70`
  - Change `{:snooze, :timer.minutes(15)}` → `{:snooze, {15, :minutes}}`
    (Oban 2.20+ tuple syntax; we're on 2.21.1)
  - Update test: replace the two-assert pattern with direct pattern match:
    ```elixir
    assert {:snooze, {15, :minutes}} =
             perform_job(FetchAdAccountsWorker, %{meta_connection_id: conn.id})
    ```
  - Update test name to "returns {:snooze, 15 min} and leaves DB unchanged"

- [x] [B2] Add `wget` to runtime Alpine image — Dockerfile line 32
  - **File**: `Dockerfile:36`
  - Change:
    ```dockerfile
    RUN apk add --no-cache libstdc++ openssl ncurses-libs && \
    ```
    To:
    ```dockerfile
    RUN apk add --no-cache libstdc++ openssl ncurses-libs wget && \
    ```

---

## Phase 2: Warnings

- [x] [W1] Remove unused `hackney` direct dependency — removed from mix.exs; added `config :sentry, client: Sentry.HTTPCClient` in config.exs
  - **File**: `mix.exs:85`
  - Remove `{:hackney, "~> 1.8"}` from deps list.
  - Run `mix deps.get` and `mix compile --warnings-as-errors` to verify.
  - Sentry 10 uses httpc by default; hackney is only needed if
    `config :sentry, client: Sentry.HackneyClient` is set (it is not).

- [x] [W2] Remove dead `Oban.insert_all` changeset filter in SyncAllConnectionsWorker — removed Logger alias + dead filter block
  - **File**: `lib/ad_butler/workers/sync_all_connections_worker.ex:21-27`
  - `Oban.insert_all/1` raises on invalid changesets — it never returns
    `%Ecto.Changeset{}` in the result list. The filter always returns 0.
  - Replace entire block with:
    ```elixir
    Oban.insert_all(jobs)
    :ok
    ```
  - Remove the `require Logger` and `Logger` alias if no longer used elsewhere.

- [x] [W3] Log failure reason before nack-and-stop in `drain_dlq/3` — Logger.warning with reason + replayed_so_far
  - **File**: `lib/mix/tasks/ad_butler.replay_dlq.ex:39-43`
  - Current code silently stops draining after the first publish failure.
  - Add a log before returning:
    ```elixir
    {:error, reason} ->
      Logger.warning("DLQ replay: publish failed, stopping drain",
        reason: inspect(reason),
        replayed_so_far: count
      )
      AMQP.Basic.nack(channel, tag, requeue: true)
      count
    ```

- [x] [W4] Document intent of empty `:health_check` pipeline + dead PlugAttack rule — comments in router.ex and plug_attack.ex
  - **File**: `lib/ad_butler_web/router.ex:48-50`,
    `lib/ad_butler_web/plugs/plug_attack.ex` (health rule section)
  - Add comment to empty pipeline explaining it is intentionally plug-free:
    ```elixir
    pipeline :health_check do
      # Intentionally empty: no PlugAttack here. Fly probers share IPs and
      # would trigger the rate limit, causing machine restart loops.
      # The PlugAttack health rule below is kept for future per-IP limiting.
    end
    ```
  - In `plug_attack.ex`, add a comment to the health rate-limit rule noting it
    is currently unreachable (pipeline is empty) and why.

- [x] [W5] Configure Sentry LoggerBackend safely before it reaches prod — level: :error, capture_log_messages: false in prod.exs
  - **File**: `config/prod.exs`
  - The current config sends all log-level messages including Logger.info/warning
    to Sentry, which leaks known sensitive data (access_token in changesets,
    AMQP URLs with credentials). Apply minimal safe config:
    ```elixir
    config :logger, Sentry.LoggerBackend,
      level: :error,
      capture_log_messages: false
    ```
  - `capture_log_messages: false` means only exceptions reach Sentry, not raw
    log strings. `level: :error` limits to error+ events.

---

## Phase 3: Test Coverage

- [x] [T1] Add health controller tests — liveness + readiness happy/sad path; db_ping injected via Application.get_env
  - **File**: `test/ad_butler_web/controllers/health_controller_test.exs` (new file)
  - Create `AdButlerWeb.HealthControllerTest` using `AdButler.ConnCase`.
  - Test liveness: `GET /health/liveness` → 200 "ok"
  - Test readiness happy path: `GET /health/readiness` → 200 "ok" (DB available)
  - Test readiness sad path: mock `SQL.query/4` to return `{:error, :timeout}` → 503
    (use Mox or override via config; check existing test patterns for DB mocking)

- [x] [T2] Add `drain_dlq/3` nack error path test — AMQPBasicStub inline module, amqp_basic injected via Application.get_env; drain_dlq made @doc false public
  - **File**: `test/mix/tasks/ad_butler.replay_dlq_test.exs` (check if exists, else new)
  - Add a test where `AMQP.Basic.publish/5` returns `{:error, :channel_closed}`.
  - Assert the message is nacked (not acked) and the function returns `count` without
    consuming further messages.

- [x] [T3] Add `list_all_active_meta_connections/1` row-limit error path test — 3 inserts, limit 2, CaptureLog asserts error message
  - **File**: `test/ad_butler/accounts_test.exs` (check accounts test file)
  - Insert 3 connections, call `list_all_active_meta_connections(2)`.
  - Assert result has 2 entries (limit respected).
  - Capture log and assert a log entry at `:error` level was emitted
    (use `ExUnit.CaptureLog`).

---

## Phase 4: Suggestions

- [x] [S1] Add `timeout/1` callback to `SyncAllConnectionsWorker` — :timer.minutes(2)
  - **File**: `lib/ad_butler/workers/sync_all_connections_worker.ex`
  - Add after `perform/1`:
    ```elixir
    @impl Oban.Worker
    def timeout(_job), do: :timer.minutes(2)
    ```
  - Prevents unbounded runtime when `list_all_active_meta_connections/0`
    returns a large set.

---

## Verification

- [x] `mix compile --warnings-as-errors`
- [x] `mix format --check-formatted`
- [x] `mix test` — 128 tests, 0 failures, 7 excluded
- [x] `mix credo --strict` — no issues
