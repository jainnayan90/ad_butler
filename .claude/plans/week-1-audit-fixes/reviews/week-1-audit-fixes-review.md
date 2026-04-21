# Review: Week-1 Audit Fixes

**Verdict**: REQUIRES CHANGES
**Date**: 2026-04-21
**Tests**: 69/69 passing

---

## Finding Summary

| Severity | Count |
|----------|-------|
| Blocker  | 1     |
| Warning  | 6     |
| Suggestion | 4  |

---

## Blocker

### B1: Non-exhaustive `case` in `token_refresh_worker.ex` — `CaseClauseError` on unexpected DB error
**File**: `lib/ad_butler/workers/token_refresh_worker.ex:68`

```elixir
{:error, %Ecto.Changeset{} = changeset} ->
  Logger.error(...)
  {:error, :update_failed}
# ← no catch-all
```

`Repo.update/1` spec is `{:ok, _} | {:error, Ecto.Changeset.t()}`, so exhaustive in normal operation. But if a DB connection is lost, middleware injects a bare atom, or a mock in tests returns an unexpected shape, this raises `CaseClauseError`. Oban rescues, retries, then discards after 5 attempts — silent token refresh failure.

**Fix**: add a catch-all after the changeset arm:
```elixir
{:error, reason} ->
  Logger.error("Token refresh update failed (unexpected)",
    meta_connection_id: id,
    reason: inspect(reason)
  )
  {:error, :update_failed}
```

---

## Warnings

### W1 (Security): Session salts remain static in VCS — runtime override impossible
**File**: `config/config.exs:15-17,27`

The plan intended to move production salts to runtime env vars. The actual outcome: prod-specific overrides removed from `prod.exs` ✓, but `endpoint.ex` still uses `Application.compile_env!` (module attribute), freezing the `config.exs` defaults at build time. `runtime.exs` env vars cannot override them.

**Impact**: Low cryptographic risk (salts are not secret keys), but the structural ability to rotate salts without a code change + redeploy is absent. Session rotation requires a new build.

**Full fix** (out of scope for this pass): Replace `@session_options` module attribute in `endpoint.ex` with a function, use `Application.fetch_env!` inside it, wire `runtime.exs` with `System.fetch_env!("SESSION_SIGNING_SALT")`.
**Minimal fix** (document the limitation): Add a comment in `config.exs` that these salts are shared dev/test/prod and rotation requires a rebuild.

### W2 (Oban): 500-row sweep limit is silent when hit
**File**: `lib/ad_butler/accounts.ex` — `list_expiring_meta_connections/2`

When 500+ connections need refresh, the overflow is invisible. The 501st is picked up next sweep (6h), so no tokens are permanently lost, but you'd never know the limit is routinely hit.

**Fix**: `if length(connections) == limit, do: Logger.warning("Sweep hit limit #{limit}; some connections deferred")`

### W3 (Elixir): `list_expiring_meta_connections/2` non-deterministic under limit
No `order_by` before `limit(^limit)`. If >500 connections are expiring, arbitrary rows are returned — the most urgent (soonest-expiring) may be skipped.

**Fix**: `|> order_by([mc], asc: mc.token_expires_at)` before `|> limit(^limit)`

### W4 (Security): `plug_attack.ex` IP extraction unsafe outside Fly.io
`client_ip/1` trusts `fly-client-ip` header. Safe on Fly (edge strips attacker-supplied values). Unsafe behind Nginx/Cloudflare/bare ELB — attacker can rotate the header to bypass rate limiting.

**Fix**: Document Fly.io coupling explicitly, or make the trusted header configurable via `runtime.exs`.

### W5 (Elixir): `meta_client/0` duplicated in `Accounts` and `TokenRefreshWorker`
Identical private helper defined in two modules. Inconsistency risk if the config key or default changes.

**Fix**: Expose as `AdButler.Meta.client/0` (public function in the boundary module) and call it from both places.

### W6 (Testing): `accounts_authenticate_via_meta_test.exs` unnecessarily `async: false`
`stub/3` works in serialised mode but the test could run async. Missing `setup :set_mox_from_context` blocks safe upgrade.

**Fix**: Add `setup :set_mox_from_context` + change to `async: true`.

---

## Suggestions

### S1 (Oban): Add `timeout/1` to `TokenRefreshSweepWorker`
Up to 500 sequential `Oban.insert/1` calls with no timeout is risky under DB load.
**Fix**: `def timeout(_job), do: :timer.minutes(2)`

### S2 (Oban): `Enum.each/2` in sweep discards all enqueue errors
If every insert fails, the sweep job still returns `:ok` — Oban's retry machinery never fires.
**Fix**: Track failures and return `{:error, :all_enqueues_failed}` when count > 0.

### S3 (Testing): Prefer `expect/3` over `stub/3` for happy-path authenticate tests
`stub/3` allows zero or many calls. `expect(ClientMock, :exchange_code, 1, fn ... end)` asserts exactly one invocation, catching regressions where calls are accidentally skipped.

### S4 (Testing): Add case-sensitivity test for `get_user_by_email/1`
No test documents whether the lookup is case-sensitive. Add a test with mixed-case email to establish the contract.
