# Review: Week-3 Review Fixes

**Date**: 2026-04-22
**Files Reviewed**: 18
**Reviewers**: elixir-reviewer, oban-specialist, testing-reviewer, security-analyzer, deployment-validator

## Summary

| Severity | Count |
|----------|-------|
| Blockers | 2 |
| Warnings | 6 |
| Suggestions | 7 |

**Verdict**: REQUIRES CHANGES

Two production-breaking blockers must be fixed before deploy: the Oban snooze unit bug would cause 10-day job delays instead of 15 minutes, and the missing `wget` in the runtime image means HEALTHCHECK always fails from boot.

---

## Blockers (2)

### 1. Oban snooze passes milliseconds — job delays 10.4 days not 15 minutes

**File**: `lib/ad_butler/workers/fetch_ad_accounts_worker.ex:50`
**Reviewers**: oban-specialist, elixir-reviewer

`:timer.minutes(15)` returns `900_000` in **milliseconds** (Erlang convention). Oban's `{:snooze, integer}` contract treats a bare integer as **seconds** — confirmed in `deps/oban/lib/oban/period.ex`. Passing `900_000` schedules the job ~10.4 days in the future. This is a silent production regression from the week-3 snooze change.

**Current code**:
```elixir
{:snooze, :timer.minutes(15)}
```

**Recommended approach**:
```elixir
# Oban 2.20+ tuple syntax (preferred — self-documenting):
{:snooze, {15, :minutes}}

# Or raw seconds:
{:snooze, 15 * 60}
```

---

### 2. `wget` missing from runtime Alpine image — HEALTHCHECK always fails

**File**: `Dockerfile:36,49`
**Reviewer**: deployment-validator

The runtime stage installs `libstdc++ openssl ncurses-libs` only. Alpine does not include `wget` by default. The HEALTHCHECK `CMD wget -qO- http://localhost:4000/health/liveness || exit 1` will always exit with command-not-found, marking the container unhealthy from first boot and potentially triggering Fly restart loops.

**Current code**:
```dockerfile
RUN apk add --no-cache libstdc++ openssl ncurses-libs && \
    addgroup -S appgroup && adduser -S appuser -G appgroup
```

**Recommended approach**:
```dockerfile
RUN apk add --no-cache libstdc++ openssl ncurses-libs wget && \
    addgroup -S appgroup && adduser -S appuser -G appgroup
```

---

## Warnings (6)

### 1. Sentry LoggerBackend egresses known sensitive data to SaaS

**File**: `config/prod.exs:32`, `config/runtime.exs:23-29`
**Reviewer**: security-analyzer

`Sentry.LoggerBackend` is attached with no `:level` filter, metadata allowlist, or `:before_send` scrubber. Prior audits document known log-leak sites: `Ecto.Changeset` structs logged with `access_token` in `changes`; Req/Mint errors containing Meta OAuth URLs with `access_token=...`; AMQP connection errors containing `amqp://user:pass@host`. `:filter_parameters` only scrubs `Plug.Conn` params — NOT Logger metadata or error struct payloads. Week-3 now egresses those leaks to a third-party SaaS.

**Recommendation**: Add `capture_log_messages: false` and `level: :error` to `Sentry.LoggerBackend` config; add a `before_send` scrubber for sensitive keys before enabling in prod.

---

### 2. `/health/*` rate limiting lost; dead PlugAttack rule

**File**: `lib/ad_butler_web/router.ex:48-49`, `lib/ad_butler_web/plugs/plug_attack.ex:17-25`
**Reviewer**: security-analyzer

The `:health_check` pipeline is now empty. The `readiness/2` action runs `SELECT 1` on the DB pool on every unauthenticated, unthrottled request. The existing PlugAttack "health rate limit" rule is still defined but now unreachable since PlugAttack is no longer in the pipeline — creating a false sense of protection.

**Recommendation**: Either restore `plug AdButlerWeb.PlugAttack` to `:health_check` (the original blocker was Fly prober IPs sharing addresses, not the rule itself — consider a looser limit) OR explicitly delete the dead rule and document that Fly proxy handles throttling.

---

### 3. `Oban.insert_all` changeset-filtering in SyncAllConnectionsWorker is dead code

**File**: `lib/ad_butler/workers/sync_all_connections_worker.ex:22-26`
**Reviewers**: oban-specialist, elixir-reviewer

`Oban.insert_all/1` raises `Ecto.InvalidChangesetError` on invalid changesets — it never returns `%Ecto.Changeset{}` in the result list. The `match?(%Ecto.Changeset{}, &1)` filter always returns `0`; the warning log never fires. The intent (surface validation failures) is not achieved.

**Recommendation**: Remove the dead filter and comment. Real failures raise and are handled by Oban retry. If the intent is to catch validation errors explicitly, wrap in `try/rescue` instead.

---

### 4. `drain_dlq/3` stops silently after first publish failure

**File**: `lib/mix/tasks/ad_butler.replay_dlq.ex:39-43`
**Reviewer**: elixir-reviewer

When `AMQP.Basic.publish/5` returns `{:error, _reason}`, the message is nacked (correct) but `drain_dlq/3` immediately returns `count`, abandoning all remaining DLQ messages in that run with no log or indication to the operator.

**Recommendation**: Log the failure reason before returning, e.g.:
```elixir
{:error, reason} ->
  Logger.warning("DLQ replay: publish failed, stopping drain", reason: inspect(reason))
  AMQP.Basic.nack(channel, tag, requeue: true)
  count
```

---

### 5. Unnecessary `hackney` direct dependency

**File**: `mix.exs:86`
**Reviewer**: security-analyzer

`sentry ~> 10.0` has `hackney` as an optional dep, only needed if `Sentry.HackneyClient` is explicitly configured. It is not configured here. The direct dep pulls hackney + `idna` + `ssl_verify_fun` + `parse_trans` into the release for no benefit.

**Recommendation**: Remove `{:hackney, "~> 1.8"}` from deps, or explicitly set `config :sentry, client: Sentry.HackneyClient` if it is needed.

---

### 6. Collapsed RUN step degrades Docker build cache

**File**: `Dockerfile:23-27`
**Reviewer**: deployment-validator

`mix assets.deploy && mix compile && mix release` in one RUN layer means any Elixir code change re-runs asset compilation. Previously separate steps allowed each to cache independently. No correctness issue — strictly a CI build time regression.

**Recommendation**: Consider splitting: `RUN mix assets.deploy` followed by the secret-mounted `RUN --mount=... mix compile && mix release`.

---

## Suggestions (7)

### 1. Health controller has zero test coverage

**File**: `lib/ad_butler_web/controllers/health_controller.ex`
**Reviewer**: testing-reviewer

New public route with no test file. Both the 200-ok and 503 paths are untested, including the new `timeout: 1_000, queue_target: 200` options.

---

### 2. `list_all_active_meta_connections/1` row-limit error path untested

**File**: `lib/ad_butler/accounts.ex:93-100`
**Reviewer**: testing-reviewer

No test exercises the `Logger.error` path (the data-loss risk path). A unit test with `limit: 2` and 3 rows would cover it.

---

### 3. `drain_dlq/3` error path untested

**File**: `lib/mix/tasks/ad_butler.replay_dlq.ex`
**Reviewer**: testing-reviewer

The nack-on-publish-failure branch has no test. A mock returning `{:error, :channel_closed}` from `AMQP.Basic.publish/5` would cover it.

---

### 4. Snooze test uses runtime call instead of literal

**File**: `test/ad_butler/workers/fetch_ad_accounts_worker_test.exs:68`
**Reviewer**: testing-reviewer

`assert snooze_ms == :timer.minutes(15)` — once the blocker is fixed to `{:snooze, 900}` or `{:snooze, {15, :minutes}}`, pin the expected value as a literal so the test is self-documenting.

---

### 5. Empty `:health_check` pipeline should have an intent comment

**File**: `lib/ad_butler_web/router.ex:48-49`
**Reviewer**: elixir-reviewer

An empty pipeline body invites accidental additions. A short comment explains it is intentionally plug-free.

---

### 6. `SyncAllConnectionsWorker` missing `timeout/1` callback

**File**: `lib/ad_butler/workers/sync_all_connections_worker.ex`
**Reviewer**: oban-specialist

`list_all_active_meta_connections/0` with no row limit can run indefinitely. Consider `def timeout(_job), do: :timer.minutes(2)`.

---

### 7. `length(result)` in `list_all_active_meta_connections/1` is O(n) double-traversal

**File**: `lib/ad_butler/accounts.ex:93`
**Reviewer**: elixir-reviewer

Benign at the 1,000-row cap but `Repo.all` already traverses once; `length/1` traverses again. Worth noting for when the cap is raised.

---

## Pre-Existing (not counted in verdict)

| Finding | File | Status |
|---------|------|--------|
| Session salts baked into compiled release at compile time via `compile_env!` | `config/prod.exs:12-23`, `lib/ad_butler_web/endpoint.ex` | Pre-existing; acknowledged in existing comments ("Rotation requires recompile + restart"). BuildKit change reduces layer leakage but doesn't address BEAM binary storage. |

---

## Findings Table

| # | Finding | Severity | Reviewer | File | New? |
|---|---------|----------|----------|------|------|
| 1 | Oban snooze passes ms not seconds → 10.4 day delay | BLOCKER | oban-specialist, elixir-reviewer | `fetch_ad_accounts_worker.ex:50` | Yes |
| 2 | wget missing — HEALTHCHECK always fails | BLOCKER | deployment-validator | `Dockerfile:36,49` | Yes |
| 3 | Sentry LoggerBackend egresses sensitive log data | WARNING | security-analyzer | `config/prod.exs:32` | Yes |
| 4 | /health/* rate limiting lost; dead PlugAttack rule | WARNING | security-analyzer | `router.ex:48-49` | Yes |
| 5 | Oban.insert_all changeset filter is dead code | WARNING | oban-specialist, elixir-reviewer | `sync_all_connections_worker.ex:22-26` | Yes |
| 6 | drain_dlq stops silently after first failure | WARNING | elixir-reviewer | `replay_dlq.ex:39-43` | Yes |
| 7 | Unnecessary hackney direct dep | WARNING | security-analyzer | `mix.exs:86` | Yes |
| 8 | Docker build cache regression from collapsed RUN | WARNING | deployment-validator | `Dockerfile:23-27` | Yes |
| 9 | Health controller: zero test coverage | SUGGESTION | testing-reviewer | `health_controller.ex` | Yes |
| 10 | Row-limit error path untested | SUGGESTION | testing-reviewer | `accounts.ex:93` | Yes |
| 11 | drain_dlq error path untested | SUGGESTION | testing-reviewer | `replay_dlq.ex` | Yes |
| 12 | Snooze test uses runtime call not literal | SUGGESTION | testing-reviewer | `fetch_ad_accounts_worker_test.exs:68` | Yes |
| 13 | Empty health_check pipeline lacks intent comment | SUGGESTION | elixir-reviewer | `router.ex:48` | Yes |
| 14 | SyncAllConnectionsWorker missing timeout/1 | SUGGESTION | oban-specialist | `sync_all_connections_worker.ex` | Yes |
| 15 | length(result) O(n) double-traversal | SUGGESTION | elixir-reviewer | `accounts.ex:93` | Yes |
| 16 | Session salts baked at compile time | — | deployment-validator | `config/prod.exs:12-23` | Pre-existing |
