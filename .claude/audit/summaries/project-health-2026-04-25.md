# AdButler Project Health Report
Date: 2026-04-25
Branch: module_documentation_and_audit_fixes

---

## Overall Health Score: 84/100 — Grade B (Good)

| Category | Score | Weight | Weighted |
|----------|-------|--------|---------|
| Architecture | 87 | 20% | 17.4 |
| Performance | 72 | 25% | 18.0 |
| Security | 88 | 25% | 22.0 |
| Test Quality | 80 | 15% | 12.0 |
| Dependencies | 97 | 15% | 14.6 |
| **Overall** | **84** | | **84.0** |

---

## Critical / Immediate Action Items

### [P0 — FUNCTIONAL BUG] Filter dropdown always empty on CampaignsLive initial load
`lib/ad_butler_web/live/campaigns_live.ex:39-61`

The B2 fix (connected? guard in mount) emptied the mount but handle_params was never
updated to load ad_accounts_list. The filter dropdown iterates @ad_accounts_list which
stays [] until a WebSocket reconnect fires handle_info. This is a regression introduced
in the current session's triage fixes.

Fix: Populate ad_accounts_list in handle_params/3 or send a separate :load_ad_accounts
message in connected mount alongside :reload_on_reconnect.

### [P1 — SECURITY] Meta API access tokens in GET query strings
`lib/ad_butler/meta/client.ex:21-72`

All Meta GET calls pass access_token as a URL query parameter, visible in router logs
and proxy access logs. POST calls (token exchange, refresh) are correct.

Fix: Switch GET calls to use Authorization: Bearer header.

---

## High Priority

### Missing composite index `meta_connections(user_id, status)`
Hot query path called on every Ads list function. Only single-column indexes exist.
Add: `create index(:meta_connections, [:user_id, :status])`

### Missing status index on `ads` table
Campaigns and ad_sets have composite (ad_account_id, status) indexes; ads was skipped.
Add: `create index(:ads, [:ad_account_id, :status])`

### `AdButler.LLM` context module missing
Schema and handler exist but no top-level context module. Callers will bypass the
context boundary when an LLM client is wired up.

### `SyncAllConnectionsWorker` has no tests
Only worker without test coverage — drags overall coverage to 65.38% (below 70%).

---

## Medium Priority

| Issue | File | Notes |
|-------|------|-------|
| Double mc_ids query on reconnect | campaigns_live.ex:181-192 | Two redundant SELECT queries per reconnect |
| @ad_accounts_list plain assign duplicates stream | campaigns_live.ex:33 | Serialize on every diff |
| list_ad_accounts + list_campaigns load raw_jsonb | ads.ex:48,145 | Add select: clause |
| OAuth callback rate limit too coarse | plug_attack.ex:18-26 | 10/min → 3/min for /auth/meta/callback |
| Ads→Accounts cross-context undocumented | ads.ex:13 | Document in @moduledoc |
| Dev Cloak zero-key fallback | dev.exs:106 | Raise if CLOAK_KEY_DEV unset |
| Process.sleep in replay_dlq_test | replay_dlq_test.exs:186 | Flaky-test risk |
| usage_handler_test.exs could be async | usage_handler_test.exs | Use make_ref() key |

---

## Low Priority / Long-term

- `Ads.AdAccount` belongs_to crossing into Accounts namespace
- `LLM.Usage` missing required_fields/0 schema convention
- LiveView tests missing error-path coverage
- logger_json 1 major version behind (6.x → 7.x available)
- dev_routes guard implicit (add `&& config_env() == :dev`)

---

## What's Strong

- **Auth + tenant isolation**: rock-solid. `live_session :authenticated` + on_mount +
  `RequireAuthenticated` + query-level `meta_connection_id` scoping. No data leaks possible.
- **No security regressions**: zero `String.to_atom`, zero `raw()`, no SQL interpolation,
  production secrets exclusively from env vars.
- **Oban workers**: all idempotent, string keys in args, proper supervision.
- **Broadway pipeline**: batch-efficient, no N+1 in bulk upsert paths.
- **Test discipline**: 7/7 Mox files have verify_on_exit!, every async:false documented.
- **Dependencies**: 27/28 deps fully up-to-date, no security advisories.
- **Money types**: consistently _cents integers throughout — no float leakage.

---

## Action Plan

### Immediate (this session / before merge)
1. Fix empty ad_accounts_list in CampaignsLive handle_params [P0 regression]
2. Switch Meta GET calls to Authorization: Bearer header [P1 security]

### Short-term (next sprint)
3. Add migration: composite index meta_connections(user_id, status)
4. Add migration: ads(ad_account_id, status) index
5. Add AdButler.LLM context module
6. Add SyncAllConnectionsWorker test file
7. Fix OAuth callback rate limit (3/min for /auth/meta/callback)

### Long-term
8. Select-specific columns in list_ad_accounts and list_campaigns (exclude raw_jsonb)
9. Migrate logger_json to 7.x
10. Add error-path LiveView tests
