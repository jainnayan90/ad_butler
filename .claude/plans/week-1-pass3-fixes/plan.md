# Week-1 Pass-3 Security & Quality Fixes

Source: `.claude/plans/week-1-security-fixes/reviews/week-1-security-fixes-pass3-triage.md`
Branch: `week-01-Day-01-05-Authentication`

## Phase 1: Security Blockers

- [x] [P1-T1][code] Sanitize error logging in TokenRefreshWorker catch-all
  File: `lib/ad_butler/workers/token_refresh_worker.ex:97-99`
  The catch-all `{:error, reason}` branch logs `reason: reason` verbatim. Apply a safe logger
  helper inline — log only the tag/atom for structured error types, `:unknown` otherwise:
  ```elixir
  {:error, reason} ->
    Logger.error("Token refresh failed",
      meta_connection_id: id,
      reason: safe_reason(reason)
    )
    {:error, reason}
  ```
  Add private helper:
  ```elixir
  defp safe_reason({tag, _}) when is_atom(tag), do: tag
  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason(_), do: :unknown
  ```

- [x] [P1-T2][code] Change `schedule_refresh/2` to accept `%MetaConnection{}` struct
  File: `lib/ad_butler/workers/token_refresh_worker.ex:30-35, 103-119`
  1. Change public function signature to `schedule_refresh(%MetaConnection{} = conn, days)`,
     use `conn.id` as the job arg string.
  2. Update `schedule_next_refresh/2` to take `connection` (the struct) instead of `id`:
     - Call site: `schedule_next_refresh(connection, expires_in)` (pass struct, not .id)
     - Signature: `defp schedule_next_refresh(connection, expires_in_seconds)`
     - Body: `schedule_refresh(connection, days)`
  3. No external callers to update (sweep worker uses `TokenRefreshWorker.new/1` directly).

## Phase 2: Session & HTTP Security

- [x] [P2-T1][code] Replace compile-time `Mix.env()` with `Application.compile_env` for secure cookie
  Files: `lib/ad_butler_web/endpoint.ex:14`, `config/dev.exs`, `config/test.exs`
  1. In `endpoint.ex`: change `secure: Mix.env() == :prod` to
     `secure: Application.compile_env(:ad_butler, :session_secure_cookie, true)`
  2. In `config/dev.exs`: add `config :ad_butler, session_secure_cookie: false`
  3. In `config/test.exs`: add `config :ad_butler, session_secure_cookie: false`
  Leave the `if Mix.env() == :dev` Tidewave plug unchanged (compile-time conditional is correct there).

- [x] [P2-T2][code] Delete OAuth state from session on verify_state failure paths
  File: `lib/ad_butler_web/controllers/auth_controller.ex:64-84`
  Change failure return to include conn with state deleted:
  1. In `verify_state/2`: on all non-success paths, return
     `{:error, :invalid_state, delete_session(conn, :oauth_state)}`
  2. Keep success path as `{:ok, conn}` (clear_session in the happy path handles cleanup).
  3. Update `callback/2` else clause:
     `{:error, :invalid_state, conn} ->` pattern (replaces `{:error, :invalid_state} ->`).

- [x] [P2-T3][code] Expand CSP with missing security directives; fix style-src unsafe-inline
  File: `lib/ad_butler_web/router.ex:11-14`
  Replace the CSP string with:
  ```
  "default-src 'self'; script-src 'self'; style-src 'self'; style-src-attr 'unsafe-inline'; img-src 'self' data:; font-src 'self'; frame-ancestors 'none'; form-action 'self'; base-uri 'self'; object-src 'none'"
  ```
  Note: `style-src-attr 'unsafe-inline'` allows Phoenix LiveView's inline style attributes while
  restricting external stylesheet loading via `style-src 'self'`.

## Phase 3: Worker & Data Correctness

- [x] [P3-T1][oban] Return `:ok` on schedule-only failure in TokenRefreshWorker
  File: `lib/ad_butler/workers/token_refresh_worker.ex:51-61`
  When token update succeeded but scheduling the next job failed, do not return `{:error, :schedule_failed}`
  (that causes Oban to retry and re-refresh the already-updated token). The sweep worker covers
  missed schedules every 6 hours.
  Change:
  ```elixir
  {:error, reason} ->
    Logger.error("Token re-schedule failed", meta_connection_id: id, reason: reason)
    :ok   # was: {:error, :schedule_failed}
  ```

- [x] [P3-T2][ecto] Wrap `authenticate_via_meta/1` in `Ecto.Multi` transaction
  File: `lib/ad_butler/accounts.ex:10-24`
  Currently two separate Repo calls. Wrap in a transaction:
  ```elixir
  def authenticate_via_meta(code) do
    with {:ok, %{access_token: token, expires_in: expires_in}} <- Meta.Client.exchange_code(code),
         {:ok, user_info} <- Meta.Client.get_me(token) do
      result =
        Ecto.Multi.new()
        |> Ecto.Multi.run(:user, fn _repo, _changes ->
          create_or_update_user(user_info)
        end)
        |> Ecto.Multi.run(:conn_record, fn _repo, %{user: user} ->
          create_meta_connection(user, %{
            meta_user_id: user_info[:meta_user_id],
            access_token: token,
            token_expires_at: DateTime.add(DateTime.utc_now(), expires_in, :second),
            scopes: ["ads_read", "ads_management", "email"]
          })
        end)
        |> Repo.transaction()

      case result do
        {:ok, %{user: user, conn_record: conn_record}} -> {:ok, user, conn_record}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    end
  end
  ```
  Note: `user_info[:meta_user_id]` (not `user_info[:id]`) after S5 fix.

## Phase 4: Code Quality

- [x] [P4-T1][code] Fix `xff_ip/1` to use `List.first()` instead of `List.last()`
  File: `lib/ad_butler_web/plugs/plug_attack.ex:26`
  `List.last()` returns the rightmost (closest proxy) hop; the client IP is the leftmost entry.
  Change: `|> List.last()` → `|> List.first()`

- [x] [P4-T2][ecto] Remove `:status` from `create_meta_connection` on_conflict replace list
  File: `lib/ad_butler/accounts.ex:57-59`
  Current: `on_conflict: {:replace, [:access_token, :token_expires_at, :scopes, :status, :updated_at]}`
  Fix:     `on_conflict: {:replace, [:access_token, :token_expires_at, :scopes, :updated_at]}`
  Prevents a new OAuth exchange from silently re-activating a user-revoked connection.

- [x] [P4-T3][code] Regenerate dev Cloak key with correct 32-byte random value
  File: `config/dev.exs:98`
  The current key decodes to 27 bytes ("ad_butler_dev_key_for_local") — AES-256-GCM requires 32.
  Generate a new key:
    `elixir -e ':crypto.strong_rand_bytes(32) |> Base.encode64() |> IO.puts()'`
  Replace `Base.decode64!("YWRfYnV0bGVyX2Rldl9rZXlfZm9yX2xvY2Fs")` with the new value.
  (Test key at test.exs:51 decodes to 32 bytes — leave it alone.)

- [x] [P4-T4][code] Remove duplicate `id` field from `get_me/1` return map; update caller
  Files: `lib/ad_butler/meta/client.ex:163-170`, `lib/ad_butler/accounts.ex:17`
  1. In `client.ex`: remove `id: id` from the return map (keep `meta_user_id: id`).
  2. In `accounts.ex:17`: change `meta_user_id: user_info[:id]` to `meta_user_id: user_info[:meta_user_id]`.

- [x] [P4-T5][code] Add `expires_in` to auth controller test happy-path stub
  File: `test/ad_butler_web/controllers/auth_controller_test.exs:54` (approximate line)
  Find the stub for `oauth/access_token` response in the happy-path test and add `"expires_in" => 86400`
  to the JSON response map, so the test exercises the real code path instead of the fallback TTL.

## Verification

After all phases, run:
```
mix compile --warnings-as-errors && mix test
```
