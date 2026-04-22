# Review: Week-2 Review Fixes

**Date**: 2026-04-22
**Verdict**: BLOCKED
**Breakdown**: 3 blockers · 8 warnings · 6 suggestions

All 9 prior findings (C1–C4, W1–W5) are confirmed fixed. Three new blockers were introduced by the implementation.

---

## BLOCKERS (fix before merge)

### B1: `Enum.each(ads, ...)` silently swallows all `upsert_ad/2` errors
**Source**: Elixir Reviewer
**Location**: `lib/ad_butler/sync/metadata_pipeline.ex:71`

`Ads.upsert_ad/2` returns `{:ok, _} | {:error, Ecto.Changeset.t()}`. `Enum.each` discards every result. Any FK violation (nil `ad_set_id`), constraint error, or upsert failure is silently dropped — `sync_ad_account/3` still returns `:ok`, Broadway marks the message succeeded, and ads are partially lost with no log.

**Fix**: Replace with `Enum.map/2` + collect results and propagate any error back:
```elixir
results = Enum.map(ads, &Ads.upsert_ad(ad_account, build_ad_attrs(&1, ad_set_id_map)))
case Enum.find(results, &match?({:error, _}, &1)) do
  nil -> :ok
  error -> error
end
```

---

### B2: `/app/bin/migrate` binary does not exist — every `fly deploy` will fail
**Source**: Deployment Validator
**Location**: `fly.toml:7`

`release_command = "/app/bin/migrate"` — no `rel/overlays/bin/migrate` script and no `AdButler.Release` module exist. `mix release` does not create this binary. Fly runs the release command before promoting the machine; the deploy fails at this step on every attempt.

**Fix**: Create `lib/ad_butler/release.ex`:
```elixir
defmodule AdButler.Release do
  def migrate do
    {:ok, _, _} = Ecto.Migrator.with_repo(AdButler.Repo, &Ecto.Migrator.run(&1, :up, all: true))
  end
end
```
Create `rel/overlays/bin/migrate` (chmod 755):
```bash
#!/bin/sh
/app/bin/ad_butler eval "AdButler.Release.migrate()"
```

---

### B3: Docker ARG values not exported as ENV — build crashes on nil salt
**Source**: Deployment Validator
**Location**: `Dockerfile:23-28`

Docker `ARG` is NOT part of the shell environment for `RUN` steps unless re-exported via `ENV`. `System.get_env("SESSION_SIGNING_SALT")` returns nil during `mix compile`, hits the `raise` in `config/prod.exs`, and the build fails before compilation completes.

**Fix**: Add immediately after ARG declarations in Dockerfile:
```dockerfile
ENV SESSION_SIGNING_SALT=${SESSION_SIGNING_SALT}
ENV SESSION_ENCRYPTION_SALT=${SESSION_ENCRYPTION_SALT}
```
Register as Fly build secrets: `fly secrets set --stage SESSION_SIGNING_SALT=... SESSION_ENCRYPTION_SALT=...`

---

## WARNINGS

### W1: `inspect(reason)` leaks plaintext access_token in logs
**Source**: Security Analyzer
**Location**: `lib/ad_butler/workers/fetch_ad_accounts_worker.ex:57`

When `update_meta_connection` fails, `reason` is an `%Ecto.Changeset{}`. `inspect/1` renders `:data` — the loaded `%MetaConnection{}` which holds the **plaintext `access_token`** at runtime (Cloak decrypts on load). Token ends up in stdout / log aggregators.

**Fix**: `Logger.warning("...", meta_connection_id: connection.id, errors: inspect(cs.errors))`. Also add `@derive {Inspect, except: [:access_token]}` to `MetaConnection` and add `"access_token"` to `:filter_parameters`.

### W2: Empty SESSION_SIGNING_SALT silently accepted
**Source**: Security Analyzer
**Location**: `config/prod.exs:12-18`

`System.get_env("VAR") || raise(...)` raises only on nil. An empty string `""` is truthy. Compilation succeeds with an empty salt, producing weakened cookie HMAC/encryption.

**Fix**: Validate for nil, empty string, and minimum length (8+ chars) before accepting.

### W3: `auto_stop_machines = true` tears down RabbitMQ consumers
**Source**: Deployment Validator
**Location**: `fly.toml`

Machine suspension closes AMQP channels. Broadway consumers crash on resume with no reconnect. Set `auto_stop_machines = false`.

### W4: `kill_timeout` missing — 5s default kills in-flight Oban jobs
**Source**: Deployment Validator
**Location**: `fly.toml`

5s is far too short for Oban workers (up to `timer.minutes(5)`) and Broadway consumer ACKs. Add `kill_timeout = 60`.

### W5: `Task.start/1` for RabbitMQ topology is unsupervised
**Source**: Elixir Reviewer
**Location**: `lib/ad_butler/application.ex:54`

Unlinked process. If all 3 retries exhaust silently, Broadway crashes on its first message (no exchanges/queues declared). Move to `Task.Supervisor.start_child/2` with a `Task.Supervisor` in the child list.

### W6: `/health/readiness` has no rate limiting — DB pool amplification
**Source**: Security Analyzer
**Location**: `lib/ad_butler_web/router.ex:25-28`

No pipelines on the `/health` scope. `GET /health/readiness` runs `SELECT 1` on the main Repo pool per request. An attacker can exhaust the pool and starve real traffic.

**Fix**: Bind to Fly's private network (`[services]` with `internal_port` only), or add a loose throttle pipeline.

### W7: Oban C2 fix still silently drops validation failures
**Source**: Oban Specialist
**Location**: `lib/ad_butler/workers/sync_all_connections_worker.ex:19`

`Oban.insert_all/1` returns `[%Oban.Job{} | %Ecto.Changeset{}]`. Changesets in the list indicate validation failures — the `_jobs = ...` pattern does not inspect them. DB errors raise (handled by retry), but invalid changeset entries are silently discarded.

### W8: `upsert_ad_sets/2` idempotency test missing name assertion
**Source**: Testing Reviewer
**Location**: `test/ad_butler/ads_test.exs`

Test confirms row count stays 1 and ID is stable but never reads back to assert `:name` was updated. The `on_conflict: {:replace, [..., :name, ...]}` path is untested for its actual effect.

---

## SUGGESTIONS

- **S1 (Deploy)**: Add non-root user to Dockerfile runtime stage.
- **S2 (Deploy)**: Health check grace period 10s is too short for cold boots with migrations — increase to 30s.
- **S3 (Deploy)**: Remove `steps: [:tar]` from `mix.exs` releases — Dockerfile copies the unpacked dir, `:tar` unused.
- **S4 (Testing)**: UUID assertion: prefer `assert {:ok, _} = Ecto.UUID.cast(id)` over `match?/2` for cleaner failure messages.
- **S5 (Testing)**: Integration test `fn _payload -> :ok end` should validate UUID payload like the unit test does.
- **S6 (Elixir)**: `length(result)` called twice in `list_all_active_meta_connections` — bind once.
