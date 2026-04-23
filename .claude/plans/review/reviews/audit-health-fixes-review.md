# Review: Audit Health Fixes — 2026-04-22
**Verdict: REQUIRES CHANGES**
**Issues**: 2 must-fix, 9 warnings, 4 suggestions

---

## Must Fix

### MF-1. `SyncAllConnectionsWorker.perform/1` silently swallows insert errors
`lib/ad_butler/workers/sync_all_connections_worker.ex:14-18`

`Enum.each` discards `{:ok, _}` / `{:error, _}` from `Oban.insert/1`. Any insert failure returns `:ok` — Oban marks the job succeeded, connections are silently skipped, no log evidence.

Fix: use `Oban.insert_all/1` (one DB round-trip, propagates errors):
```elixir
connections
|> Enum.map(fn c -> FetchAdAccountsWorker.new(%{"meta_connection_id" => c.id}) end)
|> Oban.insert_all()
:ok
```

### MF-2. Session-salt mismatch between HTTP plug and LiveView socket — verify before release
`config/runtime.exs:50-60`, `lib/ad_butler_web/endpoint.ex:13-14`

`@session_options` in `endpoint.ex` is built with `compile_env!` (frozen at build time). The HTTP `:session` plug uses `fetch_env!` (runtime). In a release with rotated salts, the LiveView socket tries to verify cookies using compile-time defaults from `config.exs:18-19` — the cookie cannot be decrypted and the LiveView session silently fails.

**Required**: Build a release with different salt values than the `config.exs` defaults, sign in, open a LiveView, confirm session assigns carry through. Do not deploy until verified.

---

## Warnings

**W1** `lib/ad_butler/ads.ex:46-47` — `get_ad_account/1` is **public + unscoped** (IDOR foot-gun). Public sibling of the scoped `get_ad_account!/2` — a future controller can call it with `params["id"]` and bypass tenant isolation. Rename to `get_ad_account_for_sync/1` with a docstring marking it internal. (OWASP A01:2021)

**W2** `config/dev.exs:103` — Real AES-GCM key committed to git as fallback. Dev-only, but anyone with repo access can decrypt dev DB tokens. The current implementation is acceptable short-term (the plan accepted this), but note it in team onboarding.

**W3** `lib/ad_butler/sync/metadata_pipeline.ex:37-40` — `with` else branches produce `:invalid_uuid` vs `:invalid_payload` inconsistently for what are all malformed-payload situations. Dead-lettered messages will have inconsistent reasons.

**W4** `lib/ad_butler/ads.ex:72,104` — `@spec` for `bulk_upsert_*` returns `{integer(), [map()]}`. Dialyzer can't validate `row.meta_id` / `row.id` field accesses in the pipeline. Tighten to `{non_neg_integer(), [%{id: binary(), meta_id: binary()}]}`.

**W5** `lib/ad_butler/sync/metadata_pipeline.ex:154` — `parse_budget/1` uses `String.to_integer/1`. A non-integer budget string from Meta raises `ArgumentError` and crashes the Broadway processor. Use `Integer.parse/1` with a fallback.

**W6** `config/config.exs:18-19,29` — Literal salts (`"yp0B0EBm"` etc.) are committed and become compile-time defaults for any release built from this tree. Move to `dev.exs`/`test.exs` or inject at release-build time.

**W7** `runtime.exs:43-45` — `server: true` is conditional on `PHX_SERVER` env var. If unset in Fly.io secrets, the release boots silently with no HTTP. Add `server: true` unconditionally in the prod block.

**W8** `.envrc:7` — Contains a real `CLOAK_KEY`. Gitignored but verify: `git log --all -- .envrc`. Rotate if ever pushed.

**W9** `lib/ad_butler/ads.ex:14-26` — Every scoped read (`list_*`, `get_*!`) issues an extra `SELECT id` query before the main query. Document on the private helpers. For multiple scoped calls in the same request, hoist the IDs fetch to the caller.

---

## Suggestions

**S1** Both Oban cron workers fire at `"0 */6 * * *"` — offset one by a few minutes for cleaner dashboard isolation.

**S2** `FetchAdAccountsWorker` has no `timeout/1` callback — a hung HTTP call blocks a `sync` queue slot indefinitely. Add `def timeout(_job), do: :timer.minutes(5)`.

**S3** `Scheduler.schedule_sync_for_connection/1` missing `@spec` after GenServer removal.

**S4** Test gaps: (a) no `bulk_upsert_*` direct conflict-resolution test, (b) no empty-connections test for `SyncAllConnectionsWorker`, (c) unscoped `Repo.aggregate(:count)` assertions in upsert tests are redundant alongside the `first.id == second.id` assertion.

---

## Pre-Deploy Checklist
- [ ] Fix MF-1 (`Oban.insert_all`)
- [ ] Verify MF-2 (session-salt round-trip test in a release build)
- [ ] `fly secrets set SESSION_SIGNING_SALT=... SESSION_ENCRYPTION_SALT=... LIVE_VIEW_SIGNING_SALT=...`
- [ ] Confirm `PHX_SERVER=true` in Fly.io secrets
- [ ] `git log --all -- .envrc` — rotate `CLOAK_KEY` if pushed
- [ ] Verify all prod vars from `.env.example` in `fly secrets list`
