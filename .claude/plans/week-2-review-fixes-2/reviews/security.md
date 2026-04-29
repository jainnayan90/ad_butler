# Security Audit: week-2-review-fixes-2

⚠️ EXTRACTED FROM AGENT MESSAGE (agent Write access denied)

**Status**: PASS WITH SUGGESTIONS
**Issues**: 1 low-severity suggestion · 3 informational

---

## Low Severity

### L1 — `unsafe_get_latest_health_score/1` invariant is doc-only

The doc names the precondition but nothing in the type system enforces it. Current sole caller honours the invariant (gated inside `{:ok, finding}` branch). A future caller taking `ad_id` from params could leak cross-tenant health scores. The `unsafe_` prefix is the only structural defense.

**Suggestion**: expose `get_health_score_for_finding(user, finding_id)` that bundles both lookups behind one scope boundary.

---

## Informational (Verified Safe)

- **`acknowledge_finding/2` `with` passthrough**: Tenant scope holds. `get_finding/2 → scope_findings/2` joins Finding→AdAccount on `aa.meta_connection_id in ^mc_ids`. `acknowledge_changeset/2` uses `change/2` not `cast/3` — no client input reaches it. Safe.
- **`handle_event("acknowledge")` nil-guard TOCTOU**: Button only rendered inside `:if={@finding}`. ID was already authorized at mount. If higher-impact actions land here later, re-fetch user/connection state per event.
- **`handle_params/3` validation**: Bypass vectors considered and rejected — empty string, type confusion, case-folding, UUID with embedded content, negative page. `apply_finding_filters/2` further guards with `is_binary` + `^` pinning. Double-validation is good defense-in-depth.

---

## Pre-existing (Not In Diff)

- W1 PERSISTENT: `inspect(reason)` leaks access_token in `fetch_ad_accounts_worker.ex`
- W2 PERSISTENT: Empty SESSION_SIGNING_SALT accepted
- W6 PERSISTENT: `/health/readiness` no rate limiting
