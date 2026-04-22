# Plan: Week-1 Security & Quality Fixes

**Source**: `.claude/plans/week-1-triage-fixes/reviews/week-1-triage-fixes-triage.md`
**Findings**: 5 criticals · 5 warnings · 3 suggestions (13 total)
**Phases**: 3 · **Tasks**: 13

---

## Phase 1: Security & Runtime Correctness [5 tasks]

- [x] [P1-T1] **C1** Restore `clear_session()` before `put_session` in login flow
  File: `lib/ad_butler_web/controllers/auth_controller.ex`
  In `callback/2` (the `code`/`state` branch), add `|> clear_session()` before
  `configure_session(renew: true)`. Current code rotates the cookie ID but leaves the
  payload intact — session fixation attack vector. Final chain:
  `conn |> clear_session() |> configure_session(renew: true) |> put_session(:user_id, ...) |> put_session(:live_socket_id, ...) |> redirect(...)`

- [x] [P1-T2] **C2+S1** Simplify sweep worker — remove buggy `pending_ids` pre-query
  File: `lib/ad_butler/workers/token_refresh_sweep_worker.ex`
  Delete the entire `pending_ids` Oban.Job query and the `mc.id not in ^pending_ids` filter.
  `TokenRefreshWorker` already has `unique: [period: {23, :hours}, keys: [:meta_connection_id]]` —
  Oban deduplicates automatically. The pre-query is also a runtime crash:
  `fragment("?->>'meta_connection_id'", j.args)` returns PostgreSQL `text` vs uuid column.
  Simplified query: `from(mc in MetaConnection, where: mc.status == "active" and mc.token_expires_at < ^threshold)`
  Also remove the `Oban.Job` alias (unused after this change).

- [x] [P1-T3] **S2** Add jitter to sweep worker orphan enqueue
  File: `lib/ad_butler/workers/token_refresh_sweep_worker.ex`
  Replace `TokenRefreshWorker.schedule_refresh(conn.id, 1)` with a jittered version.
  Since `schedule_refresh/2` accepts `days`, add an overload or inline using `Oban.Worker.new/2`
  directly with `schedule_in: :rand.uniform(86_400)` (0–24h random jitter in seconds).
  This prevents thundering herd after extended downtime. Simplest approach — add a private helper:
  ```elixir
  defp schedule_with_jitter(meta_connection_id) do
    jitter = :rand.uniform(86_400)
    %{"meta_connection_id" => meta_connection_id}
    |> TokenRefreshWorker.new(schedule_in: jitter)
    |> Oban.insert()
  end
  ```
  Call `schedule_with_jitter(conn.id)` instead of `TokenRefreshWorker.schedule_refresh(conn.id, 1)`.

- [x] [P1-T4] **C4** Fix `conn.remote_ip` proxy bypass in PlugAttack
  File: `lib/ad_butler_web/plugs/plug_attack.ex`
  Replace `conn.remote_ip` as the throttle key with the real client IP from `x-forwarded-for`.
  Behind Fly.io/Nginx, `conn.remote_ip` is the proxy IP — all users share one bucket.
  ```elixir
  rule "oauth rate limit", conn do
    client_ip =
      case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
        [forwarded | _] -> forwarded |> String.split(",") |> List.first() |> String.trim()
        [] -> conn.remote_ip |> :inet.ntoa() |> to_string()
      end
    throttle(client_ip, period: 60_000, limit: 10,
      storage: {PlugAttack.Storage.Ets, :plug_attack_storage})
  end
  ```

- [x] [P1-T5] **C3** Rotate session salts
  Files: `config/config.exs`, `config/prod.exs`
  Generate fresh salts: `mix phx.gen.secret 8` (signing_salt, live_view_signing_salt) and
  `mix phx.gen.secret 16` (encryption_salt). Update all three in `config/config.exs` (dev/test
  defaults) and all three in `config/prod.exs` (prod values). This invalidates all current sessions
  and renders the committed values useless. Note: salts are derivation inputs, not secrets — the
  actual secret is `SECRET_KEY_BASE` which is already in env vars.

---

## Phase 2: Test Coverage & Hygiene [5 tasks]

- [x] [P2-T1] **C5** Add test file for `TokenRefreshSweepWorker`
  Create: `test/ad_butler/workers/token_refresh_sweep_worker_test.exs`
  ```elixir
  defmodule AdButler.Workers.TokenRefreshSweepWorkerTest do
    use AdButler.DataCase, async: false
    use Oban.Testing, repo: AdButler.Repo
    import AdButler.Factory

    alias AdButler.Workers.TokenRefreshSweepWorker

    describe "perform/1" do
      test "returns :ok with no qualifying connections" do
        assert :ok = perform_job(TokenRefreshSweepWorker, %{})
      end

      test "enqueues refresh job for active connection expiring within 70 days" do
        conn = insert(:meta_connection, status: "active",
          token_expires_at: DateTime.add(DateTime.utc_now(), 30 * 86_400, :second))
        assert :ok = perform_job(TokenRefreshSweepWorker, %{})
        assert_enqueued worker: AdButler.Workers.TokenRefreshWorker,
          args: %{"meta_connection_id" => conn.id}
      end

      test "does not enqueue for connections expiring beyond 70 days" do
        insert(:meta_connection, status: "active",
          token_expires_at: DateTime.add(DateTime.utc_now(), 100 * 86_400, :second))
        assert :ok = perform_job(TokenRefreshSweepWorker, %{})
        refute_enqueued worker: AdButler.Workers.TokenRefreshWorker
      end

      test "does not enqueue for inactive connections" do
        insert(:meta_connection, status: "revoked",
          token_expires_at: DateTime.add(DateTime.utc_now(), 1 * 86_400, :second))
        assert :ok = perform_job(TokenRefreshSweepWorker, %{})
        refute_enqueued worker: AdButler.Workers.TokenRefreshWorker
      end
    end
  end
  ```

- [x] [P2-T2] **W1** Add explicit 1000ms timeout to `assert_receive` in logout test
  File: `test/ad_butler_web/controllers/auth_controller_test.exs:180`
  Change:
  ```elixir
  assert_receive %Phoenix.Socket.Broadcast{topic: "users_sessions:" <> ^user_id, event: "disconnect"}
  ```
  To:
  ```elixir
  assert_receive %Phoenix.Socket.Broadcast{topic: "users_sessions:" <> ^user_id, event: "disconnect"}, 1000
  ```

- [x] [P2-T3] **W2** Fix `on_exit` in `client_test.exs` to restore env rather than delete
  File: `test/ad_butler/meta/client_test.exs`
  In `setup`, capture original values before overwriting; in `on_exit`, restore them.
  Replace `Application.delete_env/2` calls with `Application.put_env/3` (or delete if original was nil).
  Add a private `restore_or_delete/2` helper to the test module:
  ```elixir
  defp restore_or_delete(key, nil), do: Application.delete_env(:ad_butler, key)
  defp restore_or_delete(key, val), do: Application.put_env(:ad_butler, key, val)
  ```

- [x] [P2-T4] **W3** Scope `Repo.aggregate` count to user in accounts_test
  File: `test/ad_butler/accounts_test.exs` around line 105 (upsert test)
  Change `Repo.aggregate(AdButler.Accounts.MetaConnection, :count) == 1` to:
  ```elixir
  import Ecto.Query, only: [from: 2]
  assert Repo.aggregate(
    from(mc in AdButler.Accounts.MetaConnection, where: mc.user_id == ^user.id),
    :count
  ) == 1
  ```

- [x] [P2-T5] **W4** Add test for `Accounts.authenticate_via_meta/1`
  File: `test/ad_butler/accounts_test.exs`
  Add `describe "authenticate_via_meta/1"` block. Use `Mox` stub for `AdButler.Meta.ClientMock`
  (already defined in `test/support/mocks.ex`). Set up `AdButler.Meta.ClientMock` as the client
  via `Application.put_env(:ad_butler, :meta_client, AdButler.Meta.ClientMock)`. Test:
  happy path returns `{:ok, %User{}, %MetaConnection{}}` for new user.

---

## Phase 3: Config Cleanup [3 tasks]

- [x] [P3-T1] **W5** Restrict meta credentials guard to prod only
  File: `config/runtime.exs`
  Change line `if config_env() != :test do` to `if config_env() == :prod do`.
  This stops requiring `META_APP_ID`, `META_APP_SECRET`, `META_OAUTH_CALLBACK_URL` env vars in dev.
  Dev uses values set in `Application.put_env` calls in test/dev setups.

- [x] [P3-T2] **S3** Remove redundant `validate_length` in `user.ex`
  File: `lib/ad_butler/accounts/user.ex:25`
  Delete `|> validate_length(:meta_user_id, max: 20)`.
  The regex `~r/^[1-9]\d{0,19}$/` already enforces max 20 characters; the length validation is
  misleading (implies it adds a check that isn't there).

- [x] [P3-T3] Write scratchpad notes for session salt architecture decision
  File: `.claude/plans/week-1-security-fixes/scratchpad.md`
  Document: salts are derivation inputs not secrets; `SECRET_KEY_BASE` is the actual secret.
  To move prod salts fully out of git in future: switch `endpoint.ex` from `compile_env!` to
  a runtime wrapper plug, then source from `runtime.exs` env vars.

---

## Verification

After Phase 1: `mix compile --warnings-as-errors && mix format --check-formatted`
After Phase 2: `mix test test/ad_butler/ test/ad_butler_web/controllers/auth_controller_test.exs`
Final: `mix test`
