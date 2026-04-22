# Elixir Review — Pass 3

## [WARNING] `Mix.env()` in endpoint.ex module attribute is compile-time fragile

File: `lib/ad_butler_web/endpoint.ex:14`

`secure: Mix.env() == :prod` baked into `@session_options` means a dev-compiled binary deployed to prod will send session cookies without the `Secure` flag. Use `Application.compile_env` instead:

```elixir
# config/dev.exs + config/test.exs
config :ad_butler, :session_secure_cookie, false

# endpoint.ex
secure: Application.compile_env(:ad_butler, :session_secure_cookie, true)
```

---

## [WARNING] Scheduling failure causes unnecessary retry of successful token refresh

File: `lib/ad_butler/workers/token_refresh_worker.ex:51-61`

After a successful `update_meta_connection`, if `schedule_next_refresh` fails, the worker returns `{:error, :schedule_failed}` which makes Oban retry the whole job — re-refreshing an already-updated token. The sweep worker (running every 6h) covers missed schedules. Scheduling failure should log and return `:ok`.

---

## [WARNING] `xff_ip/1` takes rightmost XFF entry — returns proxy IP, not client IP

File: `lib/ad_butler_web/plugs/plug_attack.ex:26`

`List.last()` on `X-Forwarded-For` returns the last (rightmost) hop — that's the closest proxy, not the client. Should be `List.first()`. The impact is limited since Fly.io's `fly-client-ip` is tried first, but the XFF fallback is semantically wrong.

---

## [WARNING] `authenticate_via_meta/1` — two Repo writes with no transaction boundary

File: `lib/ad_butler/accounts.ex:10-24`

`create_or_update_user` and `create_meta_connection` are separate calls. If the second fails, the user row exists but no connection is created. The next login attempt will upsert correctly, so this isn't data-corrupting, but it's not atomic. Wrap in `Ecto.Multi` / `Repo.transaction`.

---

## [SUGGESTION] `get_me/1` returns duplicate `id` and `meta_user_id` fields with same value

File: `lib/ad_butler/meta/client.ex:163-170`

The map returns both `id: id` and `meta_user_id: id`. The caller in `accounts.ex:17` reads `user_info[:id]` for the `meta_user_id` field. Pick one canonical key.

---

## [SUGGESTION] Happy-path controller test stub missing `expires_in`

File: `test/ad_butler_web/controllers/auth_controller_test.exs:54`

The stub returns `%{"access_token" => "fake_access_token"}` without `expires_in`, silently exercising the fallback TTL path. Add `"expires_in" => 86400`.

---

## CONFIRMED RESOLVED

All prior pass findings confirmed correct: session fixation prevention, PlugAttack route-discriminated key, sweep uniqueness by `[:worker]`, `verify_state` returning `{:ok, conn}`, dead config keys removed, `restore_or_delete/2` test isolation.
