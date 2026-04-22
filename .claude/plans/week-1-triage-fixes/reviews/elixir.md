# Elixir Code Review: week-01-Day-01-05-Authentication

⚠️ EXTRACTED FROM AGENT MESSAGE (write permission denied)

**Status**: REQUIRES CHANGES  
**Issues**: 2 critical · 3 warnings · 1 suggestion

---

## CRITICAL

### 1. `conn.remote_ip` as rate-limit key — bypassed behind any proxy

**File**: `lib/ad_butler_web/plugs/plug_attack.ex:6`

`conn.remote_ip` is the TCP peer address. Behind Nginx/Fly.io/Render, every request arrives from the proxy IP — all users share one bucket. Fix: add `Plug.RewriteOn` / `remote_ip` library earlier in the pipeline, or read `x-forwarded-for` directly in the rule.

### 2. Session encryption salt committed in plaintext

**File**: `config/config.exs:16-18`

```elixir
session_encryption_salt: "OPFmDMkSLnjk+Qu8"
```

This salt derives the AES cookie-encryption key and is now permanently in git history. Rotate it. Note: `Application.compile_env!` in endpoint.ex means prod salts must be available at **compile time** — either inject them as CI env vars, or switch session opts to `Application.fetch_env!` (runtime evaluation).

---

## WARNINGS

### 3. TokenRefreshSweepWorker — oban_jobs JSON fragment query is fragile + redundant

**File**: `lib/ad_butler/workers/token_refresh_sweep_worker.ex:20-25`

Querying by string worker name with `fragment("?->>'meta_connection_id'", j.args)` is fragile — silent miss on rename, no type safety. The `unique: [period: {23, :hours}]` on `TokenRefreshWorker` already prevents duplicates. The sweep can simply call `schedule_refresh/2` for all qualifying connections and let Oban's uniqueness constraint deduplicate — the exclusion pre-query is redundant and adds the type mismatch bug (text vs uuid).

### 4. `authenticate_via_meta/1` — error context lost at boundary

**File**: `lib/ad_butler/accounts.ex:10-24`

All failures collapse into `{:error, term()}`. Tag errors at each step: `{:error, {:token_exchange, reason}}` vs `{:error, {:db_insert, changeset}}` for meaningful observability.

### 5. `RequireAuthenticated` — no log on orphaned session (deleted user)

**File**: `lib/ad_butler_web/plugs/require_authenticated.ex:16`

When `get_user/1` returns `nil` (user deleted, session still valid) the conn is silently dropped. Add `Logger.warning` — orphaned sessions indicate a data-integrity issue worth surfacing.

---

## SUGGESTION

### 6. Redundant `validate_length` after equivalent regex

**File**: `lib/ad_butler/accounts/user.ex:25`

`~r/^[1-9]\d{0,19}$/` already enforces max 20 chars. `validate_length(:meta_user_id, max: 20)` is redundant and misleading. Remove it.
