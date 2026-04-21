# Consolidated Review Summary

**Strategy**: Compress  
**Input**: 5 files, ~11.5k tokens  
**Output**: ~4.2k tokens (63% reduction)

---

## BLOCKER Findings

### B1. Token refresh worker crashes on DB error instead of retrying
- **File**: `lib/ad_butler/workers/token_refresh_worker.ex:16`
- **Issue**: Hard `{:ok, _} = Accounts.update_meta_connection(...)` match raises `MatchError` on error, preventing graceful retry and blocking `schedule_next_refresh/2` call.
- **Fix**: Wrap in `case` statement; return `{:error, :update_failed}` on failure (from **oban-specialist**)

### B2. Rate-limit ETS storing access token instead of ad_account_id
- **File**: `lib/ad_butler/meta/client.ex:118`
- **Issue**: `parse_rate_limit_header(resp, params[:access_token])` passes access token as ETS key (PII in RAM), making subsequent lookups by actual `ad_account_id` fail and rate limits ineffective. Tokens also leak into `get_rate_limit_usage/1` queries.
- **Fix**: Thread actual `ad_account_id` through; add periodic pruning and cap table size (from **security-analyzer**)

### B3. Account takeover via email collision on upsert
- **File**: `lib/ad_butler/accounts.ex:14-22`
- **Issue**: `conflict_target: :email` with `{:replace, [:meta_user_id, …]}` silently merges two Meta identities with the same email, especially dangerous combined with synthetic `"#{id}@facebook.com"` fallback.
- **Fix**: Upsert keyed on `meta_user_id` (unique per Meta account), not email. Meta email is optional and not guaranteed unique (from **security-analyzer**)

### B4. Encryption assertion proves nothing
- **File**: `test/ad_butler/accounts_test.exs:52-60`
- **Issue**: Reading encrypted field through Ecto auto-decrypts it, making assertion of plaintext always pass regardless of whether encryption is actually working.
- **Fix**: Bypass Ecto: `Repo.query!("SELECT encode(access_token, 'escape') FROM meta_connections WHERE id = $1", [conn.id])` and assert result is NOT the plaintext token (from **testing-reviewer**)

### B5. Timing-unsafe OAuth state comparison allows replay
- **File**: `lib/ad_butler_web/controllers/auth_controller.ex:70-76`
- **Issue**: `verify_state/2` uses `==` (short-circuits on first differing byte) and `:oauth_state` persists in session after verification, allowing token replay attacks.
- **Fix**: Use `Plug.Crypto.secure_compare/2`; **delete** `:oauth_state` from session after verification (from **security-analyzer**)

### B6. No session rotation on authentication (session fixation)
- **File**: `lib/ad_butler_web/controllers/auth_controller.ex:52-54`
- **Issue**: `put_session(:user_id, user.id)` without rotation or clear allows attacker-supplied session cookie to persist.
- **Fix**: `configure_session(renew: true) |> clear_session()` before putting new user ID; add `live_socket_id` for force-logout support (from **security-analyzer**)

### B7. No `unique` constraint on token refresh worker — duplicate chains stack
- **File**: `lib/ad_butler/workers/token_refresh_worker.ex:2`
- **Issue**: Without uniqueness guard, if `perform/1` retries after DB succeeds but before returning `:ok`, two overlapping chains spawn indefinitely.
- **Fix**: Add `unique: [period: {23, :hours}, keys: ["meta_connection_id"]]` to `use Oban.Worker` (from **oban-specialist**)

---

## WARNING Findings

### W1. No differentiation between permanent and transient API errors
- **File**: `lib/ad_butler/workers/token_refresh_worker.ex:19-31`
- **Issue**: `:unauthorized` and `:token_revoked` from Meta API are retried 3 times then silently discarded; connection appears valid but is actually unusable.
- **Fix**: Return `{:cancel, reason}` for known-permanent errors; update connection status to `:revoked`. Return `{:snooze, 3600}` for rate-limit errors (from **oban-specialist**)

### W2. `get_meta_connection!/1` raises on deleted connection instead of cancelling
- **File**: `lib/ad_butler/workers/token_refresh_worker.ex:17`
- **Issue**: Deleted connections raise `Ecto.NoResultsError`, triggering 3 useless retries. Missing connection is permanent.
- **Fix**: Use `get_meta_connection/1` returning `nil`; return `{:cancel, "connection not found"}` (from **oban-specialist**)

### W3. Hardcoded 60-day expiry is magic number
- **File**: `lib/ad_butler_web/controllers/auth_controller.ex:47`
- **Issue**: `60 * 24 * 60 * 60` is not searchable or self-documenting.
- **Fix**: Extract to `@meta_long_lived_token_ttl_seconds` module attribute (from **elixir-reviewer**)

### W4. Sensitive values leak into logs via `inspect(reason)`
- **Files**: `lib/ad_butler/workers/token_refresh_worker.ex:27` and `lib/ad_butler_web/controllers/auth_controller.ex:62`
- **Issue**: `Logger.error(..., reason: inspect(reason))` can include Meta API responses containing tokens and Meta user IDs (PII).
- **Fix**: Add `config :phoenix, :filter_parameters, ["password", "access_token", "client_secret", "code", "fb_exchange_token", "token"]` to `config/config.exs`. Use structured field extraction instead of `inspect()` (from **security-analyzer**)

### W5. Encrypted field lacks `redact: true` — plaintext leaks on inspect/crash
- **File**: `lib/ad_butler/meta_connection.ex:10`
- **Issue**: Decrypted token in memory is visible in `IO.inspect`, crash reports, and Logger metadata including struct.
- **Fix**: Add `redact: true` to field definition (from **security-analyzer**)

### W6. AuthController calls Req directly, bypassing Meta.Client wrapper
- **Files**: `lib/ad_butler_web/controllers/auth_controller.ex:83,102` (vs. expected `lib/ad_butler/meta/client.ex`)
- **Issue**: Splits HTTP logic and test-stubbing across two modules; violates Wrap Third-Party APIs Iron Law.
- **Fix**: Move `exchange_code_for_token/1` and `fetch_user_info/1` into `AdButler.Meta.Client` as `Client.exchange_code/3` and `Client.get_me/1` (from **iron-laws-judge**)

### W7. Worker has no `timeout/1` callback for HTTP calls
- **File**: `lib/ad_butler/workers/token_refresh_worker.ex`
- **Issue**: If Meta API hangs, job runs until Oban shutdown grace period.
- **Fix**: Add `@impl Oban.Worker; def timeout(_job), do: :timer.seconds(30)` (from **oban-specialist**)

### W8. Oban queues configured but no Lifeline/Pruner plugins
- **File**: `config/config.exs` (Oban config section)
- **Issue**: Stuck jobs from crashed nodes never rescued; `oban_jobs` table grows unbounded.
- **Fix**: Add Lifeline (rescue stuck executing jobs) and Pruner (prune old jobs) plugins (from **oban-specialist**)

### W9. Test: `assert_enqueued` does not pin args
- **File**: `test/ad_butler/workers/token_refresh_worker_test.exs:31`
- **Issue**: Passes even if enqueued job has wrong `meta_connection_id`.
- **Fix**: Add `args: %{"meta_connection_id" => conn.id}` to assertion (from **testing-reviewer**)

### W10. Hardcoded email in accounts factory collides with parallel tests
- **File**: `test/ad_butler/accounts_test.exs:12`
- **Issue**: Static `"test@example.com"` reuses same address across test runs.
- **Fix**: Use `sequence(:email, &"test#{&1}@example.com")` (from **testing-reviewer**)

---

## SUGGESTION Findings (Grouped by Theme)

### Refactoring: Code Duplication
- **S1**: `req_options/0` duplicated in `Client` and `AuthController` — move all Req calls into `AdButler.Meta.Client` or new `AdButler.Meta.HTTP` module (from **elixir-reviewer**)

### Testing: Factory Issues (Grouped)
- **S2**: Factory `:meta_user_id` sequence name shared between `user_factory` and `meta_connection_factory` — use distinct name `":mc_meta_user_id"` in connection factory (from **testing-reviewer**)
- **S3**: Factory `access_token` uses `System.unique_integer` (evaluated once at load) instead of `sequence/2` for per-build evaluation (from **testing-reviewer**)

### Testing: ETS Cleanup & Async Mocking (Grouped)
- **S4**: Meta client test inserts ETS row not cleaned up in `on_exit` — persists across tests and pollutes state (from **testing-reviewer**)
- **S5**: Token refresh worker test uses `async: true` with `Mox.expect` but missing `set_mox_from_context` — add setup callback to avoid race conditions (from **testing-reviewer**)

### Testing: Sad-Path Coverage Gaps (Grouped)
- **S6**: Missing tests for: duplicate `(user_id, meta_user_id)` constraint error; `update_meta_connection/2` with invalid attrs; `meta_connection_id` referencing non-existent record; token exchange HTTP 4xx/5xx failures from Meta API (from **testing-reviewer**)

### Design: Minor Idiomatic Improvements (Grouped)
- **S7**: Prefer struct literal over `Map.put` for association: `%MetaConnection{user_id: user.id} |> MetaConnection.changeset(attrs)` instead of `Map.put(attrs, :user_id, user.id) |> MetaConnection.changeset(...)` (from **elixir-reviewer**)
- **S8**: Remove unnecessary `elem_or_nil/2` helper; use inline pattern match instead (from **elixir-reviewer**)
- **S9**: Collapse duplicate branches in `parse_rate_limit_header/2` `with` statement (from **elixir-reviewer**)

### Design: API Boundary Clarification
- **S10**: Add comment or assertion on `expires_in` units (seconds vs. milliseconds) in token refresh math, since `div(expires_in_seconds, 86_400) - 10` could produce 0 if units are wrong (from **oban-specialist**)

### Telemetry & Observability
- **S11**: Attach telemetry or Oban hook to alert when token refresh job is discarded after all attempts fail — otherwise revoked/expired token goes completely unnoticed (from **oban-specialist**)

---

## Coverage

| File | Represented | Key Items | Type |
|---|---|---|---|
| elixir.md | Yes | 8 (2 B, 4 W, 2 S) | Code review |
| iron-laws.md | Yes | 6 (1 B, 1 W, dedup) | Iron Law audit |
| security.md | Yes | 13 (3 B, 4 W, merged) | Security audit |
| testing.md | Yes | 14 (1 B, 4 W, 9 S) | Test coverage |
| oban.md | Yes | 9 (1 B, 6 W, 2 S) | Worker specialization |

**All 5 input files represented.** No coverage gaps.

---

## Deconfliction Notes

- **Atom keys in Oban args** (token_refresh_worker.ex:34): Kept iron-laws-judge verdict (definite violation, clear fix) over elixir-reviewer (duplicate issue but less prescriptive).
- **Token refresh hard match crash**: Kept oban-specialist finding (includes context on idempotency and permanent errors) over elixir-reviewer (surface observation only).
- **Email collision & rate-limit ETS**: Kept security-analyzer findings (directly tested impact) over elixir-reviewer (secondary observations).
