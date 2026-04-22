# Week-1 Pass-3 Review

**Branch**: `week-01-Day-01-05-Authentication`  
**Date**: 2026-04-21  
**Verdict**: ⚠️ PASS WITH WARNINGS  
**Tests**: 57/57 passing  

---

## Summary

The pass-3 security and correctness fixes are sound. No critical blockers were confirmed. Two
test coverage gaps should be closed before merging. One code-quality duplication is worth
addressing now while context is fresh.

---

## Findings by Severity

### ⚠️ WARNING (4)

#### W1 — Upsert test stub missing `expires_in`
**File**: `test/ad_butler_web/controllers/auth_controller_test.exs:111`  
The second-callback ("upsert flow") stub returns `%{"access_token" => "fake_access_token_2"}` with
no `"expires_in"`. The `exchange_code/1` fallback log shows a warning but continues. Add
`"expires_in" => 86400` to match the primary happy-path stub — the upsert flow should test the
real code path, not the fallback TTL.

#### W2 — No test for nil-session `verify_state` path
**File**: `test/ad_butler_web/controllers/auth_controller_test.exs`  
`verify_state/2` has a `nil` branch (no session at all, e.g. user hits callback URL cold) that
is untested. The 3-tuple refactor added `delete_session` to this path — verify it works:
```elixir
test "redirects to / when no session state is present", %{conn: conn} do
  conn = get(conn, ~p"/auth/meta/callback", %{"code" => "c", "state" => "any"})
  assert redirected_to(conn) == ~p"/"
  assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Invalid OAuth state"
end
```

#### W3 — `safe_reason/1` duplicated in worker and controller
**File**: `lib/ad_butler/workers/token_refresh_worker.ex`, `lib/ad_butler_web/controllers/auth_controller.ex`  
Both modules define an identical 3-clause private `safe_reason/log_safe_reason` helper. If the
sanitization logic ever needs updating it must be changed in two places. Extract to a shared
module (e.g. `AdButler.ErrorHelpers`).

#### W4 — `{:snooze, 3600}` consumes attempts in standard Oban OSS
**File**: `lib/ad_butler/workers/token_refresh_worker.ex:96`  
With `max_attempts: 5`, five consecutive rate-limit hits will permanently discard the job.
The sweep worker covers this within 6 h, so the risk is acceptable — but add a comment
explaining the intentional design. Consider raising `max_attempts` to 10 if rate-limiting is
expected to be frequent.

---

### 💡 SUGGESTION (5)

#### S1 — `conn` shadowing in `with` success branch
**File**: `lib/ad_butler_web/controllers/auth_controller.ex:37–46`  
`with {:ok, conn} <- verify_state(conn, state)` rebinds `conn` to the verified conn (state
still in session on success). The body uses this inner `conn`, and `clear_session()` correctly
cleans everything. No security risk, but shadowing masks intent. Rename to `verified_conn`
and thread it into the pipe for clarity.

#### S2 — `do_refresh/2` passes redundant `id` parameter
**File**: `lib/ad_butler/workers/token_refresh_worker.ex:37`  
`do_refresh(connection, id)` passes `id` as a separate argument even though `connection.id` is
identical. Remove the redundant parameter to prevent future divergence.

#### S3 — XFF fallback spoofable outside Fly.io
**File**: `lib/ad_butler_web/plugs/plug_attack.ex:23–31`  
`xff_ip/1` trusts `List.first/1` on the XFF header, which is attacker-controlled on any
deployment without a trusted front-proxy stripping/replacing it. On Fly.io `fly-client-ip`
takes priority and this path is never hit in production. Document this assumption or gate XFF
trust behind an explicit runtime flag.

#### S4 — `img-src data:` and no CSP report endpoint
**File**: `lib/ad_butler_web/router.ex:11–14`  
`data:` in `img-src` is not currently exploitable (no `raw/1` usage), but narrows the defense
gap slightly. Consider dropping it if no data-URI images are needed. Also consider adding a
`report-uri` or `report-to` endpoint so CSP violations are visible in production.

#### S5 — `schedule_refresh/2` struct constraint may over-couple
**File**: `lib/ad_butler/workers/token_refresh_worker.ex:31–35`  
The public function only uses `conn.id` but requires a full `%MetaConnection{}`. Any future
caller with only an ID must first load the struct. If `schedule_refresh` needs to stay public,
document the constraint in the typespec comment. (The sweep worker calling `new/1` directly
is unaffected.)

---

## Dismissed / Out-of-Scope

- **Iron Law BLOCKER (session fixation order)**: `clear_session |> configure_session(renew: true)`
  is the current order. Phoenix applies both declaratively at response-write time — pipe order
  within a conn pipeline is irrelevant to the final cookie. Security analyzer confirmed the
  pattern is correct. **Dismissed as false positive.**
- **`Mix.env()` in Tidewave plug**: Plan explicitly states "leave the `if Mix.env() == :dev`
  Tidewave plug unchanged — compile-time conditional is correct there." **Out of scope.**
- **3-tuple return type `{:ok, User, MetaConnection}`**: Pre-existing design decision, not
  changed in this pass.

---

## Security Posture (confirmed clean)

- OAuth state: 32-byte CSPRNG, `secure_compare`, 600 s TTL, deleted on every failure path ✓
- Session renewed on login: correct order confirmed ✓
- Tokens encrypted at rest: Cloak AES-256-GCM, `redact: true` ✓
- `filter_parameters` covers `access_token`, `code`, `token`, `client_secret` ✓
- No `raw/1`, no `String.to_atom` user input, no `fragment` interpolation ✓
- `on_conflict` no longer re-activates revoked connections ✓ (verify this is intentional policy)
- `session_secure_cookie: true` default in prod via `compile_env` ✓

---

## Recommended Next Steps

1. Fix W1 (upsert stub) and W2 (nil-session test) — quick, high value
2. Fix W3 (extract shared helper) — prevents log-sanitization drift
3. Add comment for W4 (snooze + attempt rationale)
4. Commit and merge

Run before merge: `mix sobelow --exit medium && mix deps.audit`
