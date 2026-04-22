# Elixir Review: Week 1 Auth + Oban Review-Fixes

⚠️ EXTRACTED FROM AGENT MESSAGE (Write access unavailable)

**Status**: Changes Requested | **Issues**: 6 (1 critical, 3 warnings, 2 suggestions)

---

## Critical Issues

**1. `create_meta_connection/2` — no conflict resolution, second OAuth login crashes**
`lib/ad_butler/accounts.ex:32-36`

`Repo.insert/1` has no `on_conflict` option. A returning user hits
`unique_constraint([:user_id, :meta_user_id])` and gets an `{:error, changeset}`,
which propagates as an OAuth failure. The user upsert is handled but the connection is not. Fix:

```elixir
Repo.insert(
  on_conflict: {:replace, [:access_token, :token_expires_at, :scopes, :status, :updated_at]},
  conflict_target: [:user_id, :meta_user_id],
  returning: true
)
```

---

## Warnings

**2. `verify_state/2` uses `if stored && ...` — prefer explicit nil clause**
`lib/ad_butler_web/controllers/auth_controller.ex:80`

`if nil_check && condition` is idiomatic JS, not idiomatic Elixir. Prefer a `case` with an
explicit `nil ->` clause separating "session missing" from "state mismatch".

**3. `{:cancel, reason}` passes atoms where strings are conventional for Oban**
`lib/ad_butler/workers/token_refresh_worker.ex:63-64`

`{:cancel, :unauthorized}` — atoms serialise to strings in JSON. The test asserts `:unauthorized`
(works in-process) but production stores `"unauthorized"`. Prefer string literals in
cancel/error reasons for consistency: `{:cancel, "unauthorized"}`.

**4. `parse_rate_limit_header/2` bare `with` silently swallows decode/shape errors**
`lib/ad_butler/meta/client.ex:228-232`

No `else` clause means a malformed header JSON or unexpected shape is silently discarded.
Add a `:debug` log in `else` or a comment making the intentional swallow explicit.

---

## Suggestions

**5. `Application.fetch_env!` called at request time — inconsistent ownership**
`lib/ad_butler_web/controllers/auth_controller.ex:14-15, 39-40`

Static config values fetched per-request, and inconsistently: `exchange_code/3` also reads
the secret internally. Pick one: either the client always reads from env (remove params from
`exchange_code/3`), or the controller always passes them.

**6. Magic numbers in `schedule_next_refresh/2` need named module attributes**
`lib/ad_butler/workers/token_refresh_worker.ex:77`

`86_400`, `10`, and `1` are unexplained inline. Extract to `@seconds_per_day`,
`@refresh_buffer_days`, and `@min_refresh_days` with brief comments.
