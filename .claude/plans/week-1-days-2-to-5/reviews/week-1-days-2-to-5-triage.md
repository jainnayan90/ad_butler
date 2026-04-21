# Triage: Week 1 Days 2–5 Review

**Date**: 2026-04-21  
**Source**: `.claude/plans/week-1-days-2-to-5/summaries/review-consolidated.md`  
**Decision**: Fix all findings (28 total)  
**Approach**: Use exact fixes described in review; no custom guidance

---

## Fix Queue

### BLOCKERs

- [ ] **B1** `token_refresh_worker.ex:16` — Replace `{:ok, _} = Accounts.update_meta_connection(...)` hard match with `case`; return `{:error, :update_failed}` on error, call `schedule_next_refresh` only on success
- [ ] **B2** `meta/client.ex:118` — Thread actual `ad_account_id` through to `parse_rate_limit_header/2` instead of passing `params[:access_token]` as ETS key; add periodic pruning + cap table size in RateLimitStore
- [ ] **B3** `accounts.ex:14-22` — Change upsert `conflict_target:` from `:email` to `:meta_user_id`; upsert should key on `meta_user_id` (unique per Meta account)
- [ ] **B4** `test/ad_butler/accounts_test.exs:52-60` — Fix encryption test: bypass Ecto with `Repo.query!("SELECT encode(access_token, 'escape') FROM meta_connections WHERE id = $1", [conn.id])` and assert result is NOT the plaintext token
- [ ] **B5** `auth_controller.ex:70-76` — Replace `==` with `Plug.Crypto.secure_compare/2` in `verify_state/2`; delete `:oauth_state` from session immediately after verification
- [ ] **B6** `auth_controller.ex:52-54` — Add `configure_session(conn, renew: true) |> clear_session()` before `put_session(:user_id, user.id)`; add `live_socket_id` for force-logout support
- [ ] **B7** `token_refresh_worker.ex:2` — Add `unique: [period: {23, :hours}, keys: [:meta_connection_id]]` to `use Oban.Worker`

### WARNINGs

- [ ] **W1** `token_refresh_worker.ex:19-31` — Return `{:cancel, reason}` for `:unauthorized`/`:token_revoked` errors + update connection status to `:revoked`; return `{:snooze, 3600}` for rate-limit errors
- [ ] **W2** `token_refresh_worker.ex:17` — Replace `get_meta_connection!/1` with `get_meta_connection/1`; return `{:cancel, "connection not found"}` when nil
- [ ] **W3** `auth_controller.ex:47` — Extract `60 * 24 * 60 * 60` to `@meta_long_lived_token_ttl_seconds` module attribute
- [ ] **W4** `config/config.exs` + worker/controller — Add `config :phoenix, :filter_parameters, ["password", "access_token", "client_secret", "code", "fb_exchange_token", "token"]`; replace `inspect(reason)` with structured field extraction
- [ ] **W5** `meta_connection.ex:10` — Add `redact: true` to `field :access_token, AdButler.Encrypted.Binary`
- [ ] **W6** `auth_controller.ex:83,102` — Move `exchange_code_for_token/1` and `fetch_user_info/1` into `AdButler.Meta.Client` as `Client.exchange_code/3` and `Client.get_me/1`; remove raw Req calls from controller
- [ ] **W7** `token_refresh_worker.ex` — Add `@impl Oban.Worker; def timeout(_job), do: :timer.seconds(30)`
- [ ] **W8** `config/config.exs` — Add Oban Lifeline and Pruner plugins to the Oban configuration
- [ ] **W9** `test/.../token_refresh_worker_test.exs:31` — Add `args: %{"meta_connection_id" => conn.id}` to `assert_enqueued`
- [ ] **W10** `test/ad_butler/accounts_test.exs:12` — Replace hardcoded `"test@example.com"` with `sequence(:email, &"test#{&1}@example.com")`

### SUGGESTIONs

- [ ] **S1** `meta/client.ex` + `auth_controller.ex` — Remove duplicated `req_options/0`; consolidate all Req calls in `AdButler.Meta.Client`
- [ ] **S2** `test/support/factory.ex:16` — Rename `:meta_user_id` sequence in `meta_connection_factory` to `:mc_meta_user_id` to avoid collision with `user_factory`
- [ ] **S3** `test/support/factory.ex:19` — Replace `System.unique_integer` with `sequence(:access_token, &"token_#{&1}")` for per-build evaluation
- [ ] **S4** `test/ad_butler/meta/client_test.exs:43` — Add `on_exit(fn -> :ets.delete(@rate_limit_table, "act_999") end)` for ETS cleanup
- [ ] **S5** `test/.../token_refresh_worker_test.exs` — Add `setup :set_mox_from_context` to avoid race conditions with `async: true` + `Mox.expect`
- [ ] **S6** Various test files — Add sad-path tests: duplicate `(user_id, meta_user_id)` constraint; `update_meta_connection/2` invalid attrs; non-existent `meta_connection_id`; token exchange HTTP 4xx/5xx
- [ ] **S7** `accounts.ex:29-33` — Replace `MetaConnection.changeset(Map.put(attrs, :user_id, user.id))` with struct literal `%MetaConnection{user_id: user.id} |> MetaConnection.changeset(attrs)`
- [ ] **S8** `meta/client.ex:154` — Remove `elem_or_nil/2` helper; replace with inline pattern match
- [ ] **S9** `meta/client.ex:161-173` — Collapse duplicate branches in `parse_rate_limit_header/2` `with` statement
- [ ] **S10** `token_refresh_worker.ex` — Add comment/assertion on `expires_in` units (seconds vs milliseconds) in refresh interval math
- [ ] **S11** `token_refresh_worker.ex` — Attach telemetry or Oban hook to alert when job is discarded after all attempts fail

---

## Skipped

None.

## Deferred

None.
