# Triage: Week-1 Audit Fixes
Date: 2026-04-21 | Source: week-1-audit-fixes-review.md | Decision: Fix all (11/11)

---

## Fix Queue

### Blocker

- [ ] [B1] Add catch-all after `%Ecto.Changeset{}` arm in `token_refresh_worker.ex:68`
  File: `lib/ad_butler/workers/token_refresh_worker.ex`
  Add after the changeset branch:
  ```elixir
  {:error, reason} ->
    Logger.error("Token refresh update failed (unexpected)", meta_connection_id: id, reason: inspect(reason))
    {:error, :update_failed}
  ```

### Warnings

- [ ] [W1] Refactor `endpoint.ex` session options to use `init/2` callback (full runtime salt fix)
  Files: `lib/ad_butler_web/endpoint.ex`, `config/runtime.exs`
  Replace `@session_options` module attribute with a `session_opts/0` function called from `init/2`.
  Use `Application.fetch_env!/2` inside the function. Wire `runtime.exs` with `System.fetch_env!("SESSION_SIGNING_SALT")` etc.
  Rotate salts once env vars are wired (invalidates active sessions — plan accordingly).

- [ ] [W2] Log warning when sweep hits the 500-row limit
  File: `lib/ad_butler/accounts.ex` — `list_expiring_meta_connections/2`
  After `Repo.all()`, if `length(connections) == limit`, emit `Logger.warning("Sweep hit connection limit ...")`.

- [ ] [W3] Add `order_by` before `limit` in `list_expiring_meta_connections/2`
  File: `lib/ad_butler/accounts.ex`
  Add `|> order_by([mc], asc: mc.token_expires_at)` before `|> limit(^limit)`.

- [ ] [W4] Document Fly.io coupling in `plug_attack.ex` (or make header configurable)
  File: `lib/ad_butler_web/plugs/plug_attack.ex`
  Minimal: add a comment that `fly-client-ip` trust is Fly-specific.
  Better: make the trusted header name configurable via `Application.get_env`.

- [ ] [W5] Consolidate `meta_client/0` into a single shared location
  Files: `lib/ad_butler/accounts.ex`, `lib/ad_butler/workers/token_refresh_worker.ex`
  Options: (a) add `AdButler.Meta.client/0` public function, or (b) keep private but document the intentional duplication.

- [ ] [W6] Make `accounts_authenticate_via_meta_test.exs` async: true
  File: `test/ad_butler/accounts_authenticate_via_meta_test.exs`
  Add `setup :set_mox_from_context` and change to `async: true`.

### Suggestions

- [ ] [S1] Add `timeout/1` to `TokenRefreshSweepWorker`
  File: `lib/ad_butler/workers/token_refresh_sweep_worker.ex`
  Add: `def timeout(_job), do: :timer.minutes(2)`

- [ ] [S2] Return error from sweep worker when all enqueues fail
  File: `lib/ad_butler/workers/token_refresh_sweep_worker.ex`
  Replace `Enum.each/2` with `Enum.reduce/3` tracking failures; return `{:error, :all_enqueues_failed}` if zero succeed.

- [ ] [S3] Use `expect/3` over `stub/3` in happy-path authenticate tests
  Files: `test/ad_butler/accounts_authenticate_via_meta_test.exs`, `test/ad_butler_web/controllers/auth_controller_test.exs`
  Change happy-path tests to `expect(ClientMock, :exchange_code, 1, fn ... end)` and `expect(ClientMock, :get_me, 1, fn ... end)`.

- [ ] [S4] Add case-sensitivity test for `get_user_by_email/1`
  File: `test/ad_butler/accounts_test.exs`
  Add a test with mixed-case email to document/assert the case-sensitivity contract.

---

## Skipped

None.

## Deferred

None.
