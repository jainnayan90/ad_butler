# Deployment Validation: ad_butler (Week 2)

**Status: REQUIRES CHANGES | 1 Blocker, 7 Warnings**

All prior findings (B2, B3, W3, W4, S1, S2, S3) confirmed fixed.

⚠️ EXTRACTED FROM AGENT MESSAGE (agent could not write to output_file)

---

## Blockers

### B1: PlugAttack rate-limits health check probes — readiness checks can return 429
**`lib/ad_butler_web/router.ex:48-50`; `lib/ad_butler_web/plugs/plug_attack.ex:17-25`**

The `:health_check` pipeline includes `AdButlerWeb.PlugAttack`, which throttles all `/health` paths to 60 req/60s per IP. Fly.io probers from shared internal IPs can exhaust this budget across machines, causing probers to receive HTTP 429. A throttled readiness check marks the machine unhealthy — Fly stops routing to it or restarts it, creating a self-inflicted outage.

**Fix**: Remove PlugAttack from the `:health_check` pipeline entirely, or add an `allow` rule for `/health` paths before the throttle rule in `plug_attack.ex`.

---

## Warnings

### W1: Missing HEALTHCHECK directive in Dockerfile
**`Dockerfile`**

No `HEALTHCHECK` instruction present. Add:
```dockerfile
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD wget -qO- http://localhost:4000/health/liveness || exit 1
```

### W2: No /health/startup endpoint
Only liveness and readiness exist. A startup endpoint allows Fly to distinguish "not yet ready" from "unhealthy" — prevents premature restarts during slow boot.

### W3: ECTO_IPV6 and ERL_AFLAGS missing from fly.toml [env]
**`fly.toml:10-12`**

`runtime.exs` checks `ECTO_IPV6` but the env var is never set in `fly.toml`. Fly's internal Postgres is IPv6-only. Add:
```toml
[env]
  ECTO_IPV6 = "true"
  ERL_AFLAGS = "-proto_dist inet6_tcp"
```

### W4: Session salts are compile-time via ARG/ENV — rotation requires full rebuild
**`Dockerfile:24-27`**

Rotating salts requires a full image rebuild, not just `fly secrets set` + restart. Consider switching to BuildKit secrets (see security review M1) to decouple rotation from the build pipeline.

### W5: No structured (JSON) logging in production
**`config/config.exs:64`**

Plain text format is used. Add a JSON formatter override in `prod.exs` or use `logger_json` for log aggregator compatibility.

### W6: No error tracking configured
No Sentry, AppSignal, or equivalent in `mix.exs` or `runtime.exs`. Crashes in GenServers, Oban workers, and LiveView handlers only surface in logs.

### W7: Recent index migrations are non-concurrent
**`priv/repo/migrations/`**

Any index migrations using `create index(...)` without `concurrently: true` take a full table lock during deploy. Use `@disable_ddl_transaction true` + `@disable_migration_lock true` + `concurrently: true` for future index migrations on large tables.

---

## Passing

- `kill_timeout = 60`, `auto_stop_machines = false`, `min_machines_running = 1` — correct
- Non-root user (`appuser`) — correct
- Multi-stage Docker build — correct
- `release_command = "/app/bin/migrate"` + working overlay script — correct
- All secrets via `fetch_env!`/`|| raise` in `runtime.exs` — correct
- `force_ssl` with HSTS — correct
- Readiness check queries DB with `SELECT 1` — correct
- No destructive migration operations — correct
