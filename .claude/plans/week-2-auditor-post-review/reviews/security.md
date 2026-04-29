# Security Audit: week-2-auditor-post-review

⚠️ EXTRACTED FROM AGENT MESSAGE (agent denied Write access)

## Summary
Tenant isolation strategy (scope at LiveView boundary, expose `unsafe_*` to internal workers only) is sound. No critical or high vulnerabilities. Two medium defence-in-depth notes plus low/informational items.

---

## Critical / High
None.

---

## Medium

### S-M1 — `unsafe_*` exports protected only by naming convention
`lib/ad_butler/ads.ex:141-149, 663-731`; `lib/ad_butler/analytics.ex:122-136`

All `unsafe_*` functions are public. The only barrier preventing a future controller from calling them with user-controlled args is the prefix — no compile-time guard, no Credo rule, no test.

**Fix:** Add a CI grep / Credo check that `lib/ad_butler_web/**/*.ex` never references `unsafe_` functions. Or move them to `AdButler.Ads.Internal`.

### S-M2 — `acknowledge_finding/2` will need re-auth when multi-user lands
`lib/ad_butler/analytics.ex:73-79`

Today `get_finding!/2` correctly scopes via `scope_findings/2`. Future multi-user-per-tenant scenario is missing role check (read-only cannot acknowledge). Add a TODO comment.

---

## Low / Informational

### S-L1 — `Ecto.UUID.dump!/1` in IN clause is safe
`lib/ad_butler/ads.ex:720` — `dump!/1` flows through Ecto's `^` pin into a parameterised `IN ($1, $2, …)`. No interpolation, no injection. Caveat: a non-UUID input crashes the whole audit run — acceptable since `Map.keys(grouped)` come from Ecto-typed `:binary_id`.

### S-L2 — Verify key shape on `unsafe_list_30d_baselines/1`
`lib/ad_butler/ads.ex:721` — Confirm `Map.get(baselines, ad_id)` matches in tests — possible binary-vs-UUID-string mismatch would silently make every CPA-explosion check skip.

### S-L3 — Migrations reversible
Both `20260427000001` and `20260427000002` are reversible. `execute/2` two-arg form used for raw SQL.
