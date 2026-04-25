# AdButler v0.1

A Phoenix LiveView application that connects to Meta (Facebook) ad accounts, syncs campaign data via a RabbitMQ pipeline, and tracks LLM usage costs per user.

## Tech Stack

- **Elixir 1.16 / OTP 26**, Phoenix 1.8, Phoenix LiveView 1.1
- **PostgreSQL 16** — primary data store, Ecto 3.13
- **RabbitMQ 3.13** — async sync pipeline (Broadway consumer)
- **Oban 2.18** — background job queue (token refresh, sync workers)
- **Cloak / cloak_ecto** — field-level encryption for OAuth tokens
- **PlugAttack** — rate limiting
- **Bandit** — HTTP server

## Features (v0.1)

- Meta OAuth connection flow — stores encrypted access/refresh tokens
- Background token refresh sweep (Oban) — proactively refreshes expiring tokens
- Ad account sync pipeline — fetches ad accounts from Meta API via RabbitMQ/Broadway
- Dashboard LiveView — connected ad accounts and counts
- Campaigns LiveView — filterable campaign list with status filter
- LLM usage tracking — telemetry-based cost logging per user with encryption
- Rate limiting on auth routes (PlugAttack + ETS)
- Health check endpoint (`GET /health`)
- JSON structured logging (logger_json) in production

## Running Locally

### Option A — Docker (recommended)

```bash
docker compose up
```

Starts postgres, rabbitmq, and the app with live reload. No extra config needed.

```bash
docker compose up --build        # rebuild after Dockerfile.dev changes
docker compose run app mix test  # run tests inside the container
docker compose down -v           # stop and wipe volumes (fresh DB)
```

App: http://localhost:4000  
RabbitMQ management UI: http://localhost:15672 (guest / guest)

### Option B — Native

Prerequisites: Elixir 1.16+, PostgreSQL 16, RabbitMQ 3.13

```bash
mix setup          # deps.get + ecto.create + ecto.migrate + assets
mix phx.server     # or: iex -S mix phx.server
```

App: http://localhost:4000

## Running Tests

```bash
mix test
```

Or inside Docker:

```bash
docker compose run app mix test
```

## Pre-commit Checks

```bash
mix precommit
```

Runs (in test env): `compile --warnings-as-errors`, `deps.unlock --unused`, `format`, `hex.audit`, `test`.

## Environment Variables

Copy `.env.example` to `.env` and fill in values. Never commit `.env`.

| Variable | Required | Description |
|---|---|---|
| `SECRET_KEY_BASE` | prod | `mix phx.gen.secret` |
| `LIVE_VIEW_SIGNING_SALT` | prod | `mix phx.gen.secret 32` |
| `SESSION_SIGNING_SALT` | prod (build-time) | injected as BuildKit secret |
| `SESSION_ENCRYPTION_SALT` | prod (build-time) | injected as BuildKit secret |
| `CLOAK_KEY` | prod | 32-byte key, base64-encoded |
| `DATABASE_URL` | prod | `ecto://user:pass@host/db` |
| `RABBITMQ_URL` | prod | `amqp://user:pass@host` |
| `META_APP_ID` | prod | Meta developer app ID |
| `META_APP_SECRET` | prod | Meta developer app secret |
| `META_OAUTH_CALLBACK_URL` | prod | full redirect URI registered in Meta app |

Dev uses hardcoded safe defaults for all of the above — no `.env` needed locally.

## Production (Docker Compose)

```bash
cp .env.example .env   # fill in all required values

SESSION_SIGNING_SALT=<value> SESSION_ENCRYPTION_SALT=<value> \
  docker compose -f docker-compose.prod.yml --env-file .env up --build
```

The `migrate` service runs `mix ecto.migrate` and exits before the `app` service starts. Mirrors the Fly.io `release_command` pattern.

## Deploying to Fly.io

```bash
fly deploy
```

The `Dockerfile` builds a release image using BuildKit secrets for session salts. `fly.toml` sets the `release_command` to run migrations before the new instance takes traffic.

## Project Structure

```
lib/
  ad_butler/
    accounts/       # User, MetaConnection schemas + context
    ads/            # AdAccount, Campaign, AdSet, Ad, Creative schemas + context
    llm/            # LLM Usage schema + telemetry handler + LLM context
    meta/           # Meta API HTTP client, rate-limit store
    messaging/      # RabbitMQ publisher pool, topology setup
    sync/           # Broadway metadata pipeline, scheduler
    workers/        # Oban workers (token refresh sweep, ad account fetch, sync)
  ad_butler_web/
    live/           # DashboardLive, CampaignsLive
    controllers/    # Auth (OAuth), Health, Page
    plugs/          # RequireAuthenticated, PlugAttack rate limiting
    components/     # DashboardComponents, CoreComponents
```

## Database Schema (v0.1)

- `users` — authenticated users (Meta OAuth)
- `meta_connections` — OAuth tokens (encrypted), status, token expiry
- `ad_accounts` — synced from Meta, linked to connection
- `campaigns`, `ad_sets`, `ads`, `creatives` — full Meta ad hierarchy
- `llm_usage` — per-request cost tracking (model, tokens, cost, status)
- `oban_jobs` — Oban background job queue
