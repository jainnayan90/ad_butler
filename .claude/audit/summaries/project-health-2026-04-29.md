# Project Health Audit — AdButler

**Date**: 2026-04-29
**Overall Grade**: C+ (67/100)
**Test Suite**: 321 tests, 0 failures ✓

---

## Health Score Summary

| Category       | Score | Grade | Critical Issues |
|----------------|-------|-------|-----------------|
| Architecture   | 62/100 | C+   | 3 HIGH context-boundary violations |
| Performance    | 48/100 | D+   | 1 CRITICAL N+1, 3 HIGH |
| Security       | 82/100 | B    | 0 blockers (agent truncated — prior clean pass) |
| Tests          | 68/100 | C+   | 3 HIGH coverage gaps |
| Dependencies   | 76/100 | B-   | 0 vulnerabilities, 3 MEDIUM scope issues |

---

## Architecture (62/100)

### [HIGH] `Analytics` schemas reach into `Ads` and `Accounts` schemas directly
`lib/ad_butler/analytics/finding.ex:16-19`, `lib/ad_butler/analytics/ad_health_score.ex:15`
`belongs_to :ad, AdButler.Ads.Ad`, `belongs_to :ad_account, AdButler.Ads.AdAccount`, `belongs_to :acknowledged_by, AdButler.Accounts.User` — schemas in one context coupling to internals of two others. Remove `belongs_to` macros pointing across context boundaries; use FK fields only and traverse via context public functions.

### [HIGH] `Ads` context pattern-matches on `Accounts.MetaConnection` struct
`lib/ad_butler/ads.ex:158-161`
`def upsert_ad_account(%AdButler.Accounts.MetaConnection{} = connection, …)` — creates compile-time coupling from `Ads` into `Accounts` internals. Accept `meta_connection_id` binary instead.

### [HIGH] `Analytics.scope_findings/2` directly JOINs `AdButler.Ads.AdAccount`
`lib/ad_butler/analytics.ex:236-241`
Cross-context Ecto query bypasses `Ads`'s scope helpers. Extract to `Ads.ad_account_ids_for_user/1` and filter on IDs.

### [MEDIUM] `Accounts` calls `Meta.Client` directly instead of via `Application.get_env`
`lib/ad_butler/accounts.ex:243`
Inconsistent with every other call site. Change to `Application.get_env(:ad_butler, :meta_client, AdButler.Meta.Client)`.

### [MEDIUM] `unsafe_get_latest_health_score/1` ownership relies on call-site discipline
`lib/ad_butler/analytics.ex:144` — no comment anchoring the precondition. Add comment or wrap both calls in `Analytics.get_health_score_for_finding/2`.

### [LOW] `FindingsLive` event handlers lack explicit `current_user` assertion
`lib/ad_butler_web/live/findings_live.ex:68-91` — authorization is implicit via re-scope. Add `current_user = socket.assigns.current_user` at top of each handler.

---

## Performance (48/100)

### [CRITICAL] Per-row `Repo.insert` loop in `insert_health_scores/2`
`lib/ad_butler/workers/budget_leak_auditor_worker.ex:80-104`
500 ads = 500 INSERT round-trips per audit run. Use `Repo.insert_all/3` with `on_conflict: {:replace, …}` — same pattern as `bulk_upsert_insights/1`.

### [HIGH] Per-`{ad_id, kind}` SELECT in `maybe_emit_finding/3`
`lib/ad_butler/workers/budget_leak_auditor_worker.ex:346-370`
Up to 5N SELECTs per audit run. Bulk-load all open findings for the account once; build an in-memory `MapSet` keyed on `{ad_id, kind}` for the dedup check.

### [HIGH] `list_ad_sets/2` and `list_ads/2` unbounded
`lib/ad_butler/ads.ex:337-343`, `:436-442`
No `limit` — large accounts load entire tables. Add safety cap with warning log (matching `list_ad_accounts/1`'s 200-row limit), or remove in favour of paginated variants.

### [HIGH] Missing plain covering index on `campaigns.ad_account_id` and `ad_sets.ad_account_id`
`lib/ad_butler/ads.ex:35-40`; migration `20260423000000`
Only `(ad_account_id, status)` composite indexes exist. Unfiltered-by-status JOINs can't use them. Add `CREATE INDEX CONCURRENTLY ON campaigns (ad_account_id)` and same for `ad_sets`.

### [MEDIUM] `paginate_findings` ORDER BY uncovered for single-filter queries
`lib/ad_butler/analytics.ex:49`
Composite index `(ad_account_id, severity, inserted_at DESC)` unused when only `ad_account_id` is filtered. Add `CREATE INDEX ON findings (ad_account_id, inserted_at DESC)`.

### [MEDIUM] `FindingsLive.load_findings/1` re-queries `list_ad_accounts` on every page/filter change
`lib/ad_butler_web/live/findings_live.ex:196-214`
Load ad accounts list once in `mount` connected branch; skip in subsequent `load_findings` calls.

### [LOW] `AdsLive`/`CampaignsLive` execute queries during disconnected mount
`lib/ad_butler_web/live/ads_live.ex:43-77`, `campaigns_live.ex:44-78`
Guard query blocks with `if connected?(socket)` — matching `FindingsLive` pattern.

---

## Security (82/100)

*Agent truncated before completing analysis. Prior pass-3 review (same day) found 0 blockers, 0 warnings. Known clean areas: tenant scope on all user-facing queries, allowlisted URL params, UUID cast validation, CastError rescue, `:filter_parameters` covers tokens. `safe_identifier!/1` guards partition SQL (agent was investigating this when truncated). Re-run `/phx:audit --focus=security` for full pass.*

---

## Tests (68/100)

### [HIGH] `Accounts.paginate_meta_connections/2` — no test
`lib/ad_butler/accounts.ex:198` — scoped paginating function, no tenant-isolation test.

### [HIGH] `Accounts.list_expiring_meta_connections/2` — no test
`lib/ad_butler/accounts.ex:225` — expiry-window logic untested; silent regression would break token-refresh scheduling.

### [HIGH] `refresh_view/1`, `create_future_partitions/0`, `detach_old_partitions/0` — no direct tests
`lib/ad_butler/analytics.ex:162-229` — only exercised indirectly through workers. Date-arithmetic bugs undetected.

### [MEDIUM] `AuthControllerTest` `set_mox_global` races with `async: true` ClientMock users
`test/ad_butler_web/controllers/auth_controller_test.exs:11` — can corrupt expectations in CI. Switch to `set_mox_from_context/1` + `async: true`.

### [MEDIUM] `health_controller_test.exs`, `mat_view_refresh_worker_test.exs`, `llm/usage_handler_test.exs` — `async: false` with no comment
Add one-line comment explaining why (e.g., global state via `:persistent_term` / `Application.put_env`).

### [MEDIUM] `Accounts.list_all_active_meta_connection_ids/0` — no test
`lib/ad_butler/accounts.ex:168` — public function used by workers; not covered.

### [LOW] Dead `_ = mc` in two `FindingsLiveTest` tests
`test/ad_butler_web/live/findings_live_test.exs:56, :84` — remove from pattern-match head.

---

## Dependencies (76/100)

### [MEDIUM] `broadway_rabbitmq` has no `:only` scope
`mix.exs:82` — compiles `amqp`, `rabbit_common`, `ranch`, etc. in dev/test. Add `only: :prod` if pipeline not used locally.

### [MEDIUM] `ex_machina` in `[:test, :dev]` — dev scope unnecessary
`mix.exs:79` — not referenced in `lib/`. Change to `only: :test`.

### [MEDIUM] `broadway_rabbitmq` pulls `thoas` (duplicate JSON library — transitive)
Informational; document as "not to be used directly."

### [LOW] `req ~> 0.5` — `1.0` series available
Plan upgrade when stack stabilises.

### [LOW] `cloak_ecto ~> 1.3` low-activity upstream
Monitor; be prepared to fork/vendor if `cloak` releases security fixes before `cloak_ecto` catches up.

---

## Action Plan

### Immediate (production risk)

1. **[PERF-CRIT]** Batch `insert_health_scores/2` with `Repo.insert_all` — `budget_leak_auditor_worker.ex:80`
2. **[PERF-HIGH]** Bulk-load open findings before `maybe_emit_finding/3` loop — `budget_leak_auditor_worker.ex:346`
3. **[ARCH-HIGH]** Remove cross-context `belongs_to` from `Analytics` schemas; use FK-only

### Short-term (next sprint)

4. Add plain indexes: `campaigns(ad_account_id)`, `ad_sets(ad_account_id)`, `findings(ad_account_id, inserted_at DESC)`
5. Add tenant-isolation tests for `paginate_meta_connections/2` and `list_expiring_meta_connections/2`
6. Fix `Ads.upsert_ad_account/2` signature to accept `meta_connection_id` binary
7. Fix `AuthControllerTest` Mox global → `set_mox_from_context`
8. Scope `broadway_rabbitmq` to `:prod`; scope `ex_machina` to `:test` only

### Long-term (tech debt)

9. Refactor `Analytics.scope_findings/2` cross-context JOIN → `Ads.ad_account_ids_for_user/1`
10. Add `async: false` explanatory comments to three test files
11. Plan `req ~> 1.0` upgrade
12. Add direct tests for partition management functions
