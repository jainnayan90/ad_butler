# Security Review — week-2-auditor-findings
⚠️ EXTRACTED FROM AGENT MESSAGE (agent had no Write permission)

## Summary: 0 BLOCKERs, 2 WARNINGs, 2 SUGGESTIONs. Core security posture: GOOD.

---

## WARNINGs

### Mass assignment in Finding changeset — lifecycle fields castable
**File**: `lib/ad_butler/analytics/finding.ex:39-58`
`Finding.changeset/2` casts both content fields AND lifecycle fields (`:resolved_at`, `:acknowledged_at`, `:acknowledged_by_user_id`) in one permissive list. Today `acknowledge_finding/2` builds attrs server-side, so no real exploit — but the same changeset is shared with `create_finding/1`. A future user-controlled update path could mark findings as resolved or spoof acknowledgements.

Fix: Split into role-specific changesets:
- `create_changeset(f, attrs)` — casts content fields only
- `acknowledge_changeset(f, user_id)` — `change(f, acknowledged_at: ..., acknowledged_by_user_id: user_id)` with no user-supplied attrs map

### `get_latest_health_score/1` is unscoped but lacks `unsafe_` prefix
**File**: `lib/ad_butler/analytics.ex:124-133`, called at `finding_detail_live.ex:24`
Function accepts raw `ad_id` with no tenant scope. Currently safe because callers always derive `ad_id` from a scoped finding. But the project convention uses `unsafe_` prefix for all unscoped reads (`unsafe_get_30d_baseline/1`, etc.) — this naming is inconsistent.

Fix: Rename to `unsafe_get_latest_health_score/1` with a doc warning, OR accept a `%Finding{}` so the type system enforces prior authorization.

---

## SUGGESTIONs

### Unbounded `page` parameter (offset DoS)
**File**: `lib/ad_butler_web/live/findings_live.ex:241-248`
`parse_page/1` accepts any positive integer. `/findings?page=99999999` triggers `OFFSET 4_999_999_950`. Behind auth, but not rate-limited at the route level.
Fix: Cap at `min(n, 10_000)` in `parse_page`, or clamp to `total_pages` after first query.

### `:evidence` JSONB size unvalidated
**File**: `lib/ad_butler/analytics/finding.ex:25,50-58`
Worker-controlled today. If `create_finding/1` becomes reachable from a webhook/API, attackers could store arbitrarily large blobs. Document as worker-only or add size guard in changeset.

---

## PASS (clean items)
- **Auth** — `/findings` and `/findings/:id` behind `[:browser, :authenticated]` and `live_session :authenticated`. PASS.
- **Tenant isolation / IDOR** — `paginate_findings/2` and `get_finding!/2` both route through `scope_findings/2` (MetaConnection join). UUID guessing → 404. `acknowledge_finding/2` re-uses `get_finding!/2` — no bypass. PASS.
- **Input validation** — `severity`/`kind` allowlisted at `findings_live.ex:76-77`. `ad_account_id` parameterised + scope join discards foreign UUIDs. No `String.to_atom/1` on user input. PASS.
- **SQL injection** — all where/fragment clauses use `^` pinning. `raw_jsonb->>'effective_status'` uses column-only placeholder with literal constant. PASS.
- **XSS** — no `raw/1` in either LiveView. HEEx auto-escapes all interpolated data. Strict CSP at `router.ex:23-25`. PASS.
- **CSRF/secrets** — `:protect_from_forgery` + `:put_secure_browser_headers` in `:browser` pipeline. No new secrets. PASS.
