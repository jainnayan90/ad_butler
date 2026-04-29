# Security Audit: week-2-auditor-triage-fixes

⚠️ EXTRACTED FROM AGENT MESSAGE (write was denied)

## Executive Summary

Tenant isolation is solid. No critical/high issues. Two low-severity defense-in-depth gaps in URL parameter validation.

## Critical / High / Medium: None.

## Low

### L1 — Filter params bypass allowlist on direct URL navigation

- **Location**: `lib/ad_butler_web/live/findings_live.ex:42-52`
- `handle_params/3` reads `severity`, `kind`, `ad_account_id` without validation — `filter_changed` event does validate, but direct GET bypasses it. No SQL injection (Ecto pins), no data leak (scope_findings still applies). Inconsistent validation surface.
- **Fix**: Apply same allowlist logic in `handle_params` that `filter_changed` uses.

### L2 — `ad_account_id` URL param not cast as UUID

- **Location**: `lib/ad_butler_web/live/findings_live.ex:44`
- Non-UUID input raises `Ecto.Query.CastError` → 500 / log noise. No data leak.
- **Fix**: `Ecto.UUID.cast/1` in `handle_params` before passing to context.

## Security Posture

- **Tenant scoping**: OK — `scope_findings/2` JOIN is airtight; `ad_account_id` filter is ANDed with scope.
- **`unsafe_get_latest_health_score/1`**: Correctly called only after `get_finding/2` scope-checks ownership.
- **`acknowledge_finding/2`**: Re-fetches via `get_finding!` with `current_user` — server-trusted finding ID.
- **XSS**: OK — HEEx auto-escapes everywhere; `style` width is bounded numeric.
- **SQL injection**: OK — all inputs pinned with `^`.
- **CSRF**: OK — `:protect_from_forgery` + strict CSP.
- **Workers**: No user input; string-keyed args; idempotent.
- **Logging**: Structured metadata only, no PII/tokens.
