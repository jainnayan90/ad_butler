# Review: Week-3 Post-Review Fixes

**Date**: 2026-04-22  
**Verdict**: REQUIRES CHANGES  
**Breakdown**: 2 blockers · 5 warnings · 5 suggestions

---

## BLOCKERS (fix before merge)

### B1: `Sentry.HTTPCClient` does not exist — Sentry event delivery silently broken
**Source**: Elixir Reviewer + Security Analyzer  
**Location**: `config/config.exs:97`

```elixir
config :sentry, client: Sentry.HTTPCClient   # this module does not exist in sentry 10.x
```

`Sentry.HTTPCClient` is not defined anywhere in `deps/sentry/`. The library ships `Sentry.HackneyClient` (default) and `Sentry.HTTPClient` (behaviour only). Sentry starts without crashing — it uses `Code.ensure_loaded?` before calling `child_spec` — but the first event dispatched calls `Sentry.HTTPCClient.post/3` and raises `UndefinedFunctionError` inside `Sentry.Transport.Sender`. Tests pass because no errors fire.

Also: hackney is still transitively present via Sentry's `optional: true` dep declaration — the "no hackney" goal is not actually achieved.

**Fix options:**
1. **Simplest**: drop the `config :sentry, client:` line and re-add `{:hackney, "~> 1.8"}` as a direct dep.
2. **Preferred**: Implement `AdButler.SentryHTTPClient` using Finch (already a transitive dep via Req), following the example in `deps/sentry/lib/sentry/http_client.ex:42-67`. Set `config :sentry, client: AdButler.SentryHTTPClient`.

---

### B2: `async: true` + `Application.put_env` in health controller test — race condition
**Source**: Testing Reviewer  
**Location**: `test/ad_butler_web/controllers/health_controller_test.exs:2,18`

The sad-path readiness test mutates global application env with `Application.put_env(:ad_butler, :db_ping_fn, ...)`. With `async: true`, another test hitting `/health/readiness` concurrently sees the overridden function and returns 503, causing flaky failures.

**Fix**: Change `use AdButlerWeb.ConnCase, async: true` → `async: false`.

---

## WARNINGS

### W1: Oban snooze typespec too broad — `atom()` instead of `Oban.Period.t()`
**Source**: Oban Specialist  
**Location**: `lib/ad_butler/workers/fetch_ad_accounts_worker.ex:18`

```elixir
# Current (wrong):
:ok | {:snooze, {pos_integer(), atom()}} | ...

# Correct:
:ok | {:snooze, Oban.Period.t()} | ...
```

`Oban.Period.t()` is `pos_integer() | {pos_integer(), time_unit()}` — correct, Dialyzer-safe, and also documents the valid integer-seconds form. Side note confirmed by Oban agent: old `{:snooze, :timer.minutes(15)}` = 900_000 ms ≈ 10.4 days of snooze. The fix was critical.

---

### W2: `capture_log_messages: false` necessary but insufficient — exception path still leaks tokens
**Source**: Security Analyzer  
**Location**: `config/prod.exs:34-36`

`capture_log_messages: false` gates only the non-exception `:message` path. Exception events, Oban error reporter, and `Sentry.Context` extras still flow unconditionally. Tokens embedded in changeset inspect output, `Req` error URLs, or struct fields will be exfiltrated via exception stacktraces/extras.

**Fix**: Add `before_send: {AdButler.SentryScrubber, :scrub}` to the Sentry config, and `@derive {Inspect, except: [:access_token, :refresh_token]}` on `AdButler.Accounts.MetaConnection`.

---

### W3: Health readiness endpoint is an unprotected DB pool DoS surface
**Source**: Security Analyzer  
**Location**: `lib/ad_butler_web/controllers/health_controller.ex:12`, `lib/ad_butler_web/router.ex:25-29`

`GET /health/readiness` runs `SELECT 1` on every unauthenticated request. The `:health_check` pipeline is intentionally empty (correct for Fly probers), but this means an attacker can saturate the 10-connection pool (`runtime.exs:90`) with concurrent requests. `timeout: 1_000, queue_target: 200` caps per-call latency but not aggregate concurrency.

**Fix**: Either a path-keyed PlugAttack rule on `/health/readiness` only (not the full pipeline, avoiding Fly prober issues), or an in-process debounce that caches one `db_ping` result for ~500ms. Also confirm `fly.toml` probers target `/health/liveness`, not `/readiness`.

---

### W4: AMQPBasicStub has no behaviour contract — silent interface divergence risk
**Source**: Testing Reviewer  
**Location**: `test/mix/tasks/replay_dlq_test.exs:7`

Inline `AMQPBasicStub` implements `ack/2` but `AMQP.Basic.ack/3` has an optional third argument. Without a `@behaviour`, this drift is invisible to the compiler. Also, the stub's `get/3` always returns a message — no `{:empty, _}` base case — so `drain_dlq` would loop forever if a future test has publish succeed.

---

### W5: Dead PlugAttack "health rate limit" rule — "re-enable" comment is misleading
**Source**: Elixir Reviewer  
**Location**: `lib/ad_butler_web/plugs/plug_attack.ex:15-25`

The comment says "Re-enable when per-IP health limiting is needed." The rule is already compiled and present; the action needed is "add PlugAttack to `:health_check` pipeline," not change this rule. Also: both rules share the same `plug_attack_storage` ETS bucket keyspace — if accidentally re-enabled, health and OAuth buckets could collide.

**Fix** (minor): Update comment to say "add `plug AdButlerWeb.PlugAttack` to `:health_check` to activate — ensure separate bucket key to avoid OAuth keyspace collision."

---

## SUGGESTIONS

### S1: `Oban.insert_all/1` result silently discarded
**Source**: Elixir + Oban Reviewers  
**Location**: `lib/ad_butler/workers/sync_all_connections_worker.ex:22`

A zero-connection run and a successful enqueue are both silent. Consider:
```elixir
{:ok, inserted} = Oban.insert_all(jobs)
Logger.info("Sync jobs enqueued", count: length(inserted))
:ok
```

### S2: `AMQPBasicStub.get/3` infinite loop risk if publish succeeds
**Source**: Testing + Elixir Reviewers  
**Location**: `test/mix/tasks/replay_dlq_test.exs:13`

Stub never returns `{:empty, _}` — only works because publish always fails. Add an `{:empty, nil}` base case for future test safety.

### S3: drain_dlq unit test starts at count=2 — obscures intent
**Source**: Testing Reviewer  
**Location**: `test/mix/tasks/replay_dlq_test.exs:39`

Starting at 0 with `assert result == 0` makes the "no progress" assertion self-evident.

### S4: `capture_log/1` reliability in accounts test — verify sync emission
**Source**: Testing Reviewer  
**Location**: `test/ad_butler/accounts_test.exs:211`

`capture_log/1` captures only the calling process's logs. The Logger.error in `list_all_active_meta_connections/1` is inline in the same process — safe as-is. Mention this in a comment so future async extraction doesn't silently break the assertion.

### S5: No `/health/startup` endpoint (future-proofing)
**Source**: Deploy Validator  
Not needed for current Fly.io setup. Worth noting for a future Kubernetes migration.

---

## What's Confirmed Fixed (Prior Review)

- ✅ B1 (prior): `:timer.minutes(15)` snooze was ~10 days; now correctly `{15, :minutes}`
- ✅ B2 (prior): PlugAttack removed from `:health_check` pipeline; Fly probers safe
- ✅ W1 (prior): `drain_dlq` nacks on publish failure (was silently losing messages)
- ✅ W4 (prior): Empty `:health_check` pipeline documented with intent comments
- ✅ W5 (prior): Sentry LoggerBackend limited to `:error` + `capture_log_messages: false`
- ✅ T1-T3 (prior): Health controller, drain_dlq nack path, and row-limit tests added
- ✅ S1 (prior): `timeout/1` added to SyncAllConnectionsWorker
- ✅ S2 (prior): hackney removed as direct dep; Sentry HTTPCClient configured (but B1 above — wrong module name)
