# Pass 3 Triage — All Findings Approved

## Fix Queue

- [ ] B1 — Access token leak via verbatim error logging
  - `lib/ad_butler/workers/token_refresh_worker.ex:98` — apply `log_safe_reason/1` on catch-all branch
  - `lib/ad_butler/meta/client.ex` — strip `access_token` from error bodies before returning

- [ ] B2 — `schedule_refresh/2` accepts raw ID with no authorization scope
  - `lib/ad_butler/workers/token_refresh_worker.ex:30-35` — change signature to `schedule_refresh(%MetaConnection{} = conn, days)`, add UUID guard, update callers

- [ ] W1 — `secure:` cookie uses compile-time `Mix.env()`
  - `lib/ad_butler_web/endpoint.ex:14` — use `Application.compile_env(:ad_butler, :session_secure_cookie, true)`
  - `config/dev.exs` + `config/test.exs` — add `config :ad_butler, session_secure_cookie: false`

- [ ] W2 — OAuth state not deleted from session on verify failure
  - `lib/ad_butler_web/controllers/auth_controller.ex:64-84` — `delete_session(conn, :oauth_state)` on all failure paths

- [ ] W3 — CSP missing `frame-ancestors`, `form-action`, `base-uri`, `object-src`
  - `lib/ad_butler_web/router.ex:11-14` — add directives

- [ ] W4 — `style-src 'unsafe-inline'`
  - `lib/ad_butler_web/router.ex:13` — split to `style-src-attr 'unsafe-inline'; style-src 'self'`

- [ ] W5 — Worker retries full job on schedule-only failure
  - `lib/ad_butler/workers/token_refresh_worker.ex:51-61` — log scheduling failure and return `:ok`

- [ ] S1 — `xff_ip/1` uses `List.last()` (returns proxy, not client)
  - `lib/ad_butler_web/plugs/plug_attack.ex:26` — change to `List.first()`

- [ ] S2 — `authenticate_via_meta/1` missing transaction boundary
  - `lib/ad_butler/accounts.ex:10-24` — wrap in `Ecto.Multi` / `Repo.transaction`

- [ ] S3 — `on_conflict` revives revoked `MetaConnection`s
  - `lib/ad_butler/accounts.ex:54-62` — remove `:status` from replace list

- [ ] S4 — Dev/test Cloak keys are human-readable ASCII; verify 32 bytes
  - `config/dev.exs`, `config/test.exs` — regenerate with `:crypto.strong_rand_bytes(32) |> Base.encode64()`; verify 32-byte decode

- [ ] S5 — `get_me/1` returns duplicate `id` and `meta_user_id` fields
  - `lib/ad_butler/meta/client.ex:163-170` — pick one canonical key, update callers

- [ ] S6 — Auth controller test happy-path stub missing `expires_in`
  - `test/ad_butler_web/controllers/auth_controller_test.exs:54` — add `"expires_in" => 86400`

## Skipped

None.

## Deferred

None.
