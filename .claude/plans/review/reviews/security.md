# Security Audit: ad_butler (Week 2 — New Sync Pipeline + Ads Context)

**Status: REQUIRES CHANGES | 1 High, 2 Medium, 4 Low**

All prior findings (W1, W2, S1) confirmed fixed.

⚠️ EXTRACTED FROM AGENT MESSAGE (agent could not write to output_file)

---

## High Severity

### H1: Broadway consumer not wired to configured RabbitMQ URL
**`lib/ad_butler/sync/metadata_pipeline.ex:190-198`**

Producer spec passes only `queue:` and `qos:`, omitting `connection:`. `BroadwayRabbitMQ.Producer` defaults to `"amqp://guest:guest@localhost:5672"`, so consumption silently diverges from the broker used by `RabbitMQTopology.setup/0` and `Messaging.Publisher`, both of which correctly use `Application.fetch_env!(:ad_butler, :rabbitmq)[:url]`.

**Fix**:
```elixir
url = Application.fetch_env!(:ad_butler, :rabbitmq)[:url]
{BroadwayRabbitMQ.Producer,
 queue: @queue, connection: url, qos: [prefetch_count: 10]}
```
**OWASP**: A05 Security Misconfiguration

---

## Medium Severity

### M1: Session salts baked into Docker image layers
**`Dockerfile:24-27`**

`ARG SESSION_SIGNING_SALT` + `ENV SESSION_SIGNING_SALT=${…}` persists salts in image layer metadata. Anyone with image read access can extract via `docker history --no-trunc`.

**Fix**: Use BuildKit secrets so values never land in a layer:
```dockerfile
# syntax=docker/dockerfile:1.4
RUN --mount=type=secret,id=session_signing_salt \
    --mount=type=secret,id=session_encryption_salt \
    SESSION_SIGNING_SALT="$(cat /run/secrets/session_signing_salt)" \
    SESSION_ENCRYPTION_SALT="$(cat /run/secrets/session_encryption_salt)" \
    mix compile && mix release
```
**OWASP**: A02 Cryptographic Failures

### M2: /health/readiness query has no timeout — DB pool exhaustion risk
**`lib/ad_butler_web/controllers/health_controller.ex:11-16`**

`SQL.query(Repo, "SELECT 1", [])` uses default 15s timeout. PlugAttack allows 60 req/min/IP; with `pool_size: 10`, ~20 IPs can hold the pool and starve real traffic.

**Fix**: `SQL.query(Repo, "SELECT 1", [], timeout: 1_000, queue_target: 200)` and tighten health rate limit to 10-20/min/IP.

---

## Low Severity

### L1: `get_ad_account_for_sync/1` bypasses tenant scope
**`lib/ad_butler/ads.ex:49-51`**

Documented; used only after `Ecto.UUID.cast/1` validation. Consider renaming to `unsafe_get_ad_account_for_sync/1` to make the bypass loud at call sites.

### L2: `handle_message/3` only validates `ad_account_id`
**`lib/ad_butler/sync/metadata_pipeline.ex:29-42`**

Safe today; add allow-list if future code branches on `sync_type`.

### L3: `raw_jsonb` fields store untrusted Meta Graph responses
**`lib/ad_butler/ads/*.ex`**

Safe under HEEx auto-escape but must never be passed to `raw/1`. Team convention needed.

### L4: `apply_*_filters/2` silently swallows unknown filter keys
**`lib/ad_butler/ads.ex:182-188, 232-238, 271-277`**

Tenant isolation still enforced by outer `scope/2`. Consider `raise ArgumentError` on unknown keys in dev.

---

## Security Posture — Passing

- Tenant isolation: all user-facing reads go through `scope/2`/`scope_ad_account/2`
- SQL injection: all queries use `^` pins, no `fragment("…#{}…")`
- XSS: no `raw/1` in `lib/`
- CSRF: `:protect_from_forgery` + CSP in router
- Atom exhaustion: no `String.to_atom/1` on user input
- Session cookies: `http_only`, `secure`, `same_site: "Lax"`
- Secrets: `:filter_parameters` extended, `@derive {Inspect, except: [:access_token]}` on MetaConnection
- Oban args: string keys throughout
