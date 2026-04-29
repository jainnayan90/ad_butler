# Iron Law Review: week-2-review-fixes-2

⚠️ EXTRACTED FROM AGENT MESSAGE (agent Write access denied)

**Status**: PASS WITH WARNINGS
**Violations**: 1 warning · 1 suggestion

---

## Warnings

### W1 — Unbounded collection assigned as plain list — `ad_accounts_list`
**File**: `lib/ad_butler_web/live/findings_live.ex:213`

```elixir
|> assign(:ad_accounts_list, ad_accounts)
```

`Ads.list_ad_accounts/1` appears unbounded. Feeds a `<select>` dropdown so a stream is inappropriate, but if a tenant has many ad accounts this grows without limit. The findings table itself correctly uses `stream(:findings, ...)` — only the dropdown assign is at risk.

---

## Suggestions

- `handle_event("filter_changed")` and `"paginate"` push URL patches that re-load via `paginate_findings(current_user, opts)` — tenant scope is enforced. Consider adding an explicit `current_user` assertion at the top of each handler for defense-in-depth consistency.

---

## Clean Checks

- **Repo boundary**: All `Repo` calls stay inside `AdButler.Analytics`. LiveViews call only context functions. Clean.
- **`unsafe_get_latest_health_score` in LiveView**: Called only after `get_finding/2` succeeds (tenant scoped). The `unsafe_` prefix and docstring correctly document the invariant. Clean.
- **Oban**: `BudgetLeakAuditorWorker` has correct `unique` config, no struct in args. Clean.
- **Float for money**: `ctr`/`conversion_rate` floats are threshold comparisons only. All monetary values are integers. Clean.
- **connected? guard**: Both LiveViews wrap data loads with `if connected?(socket)`. Clean.
- **Structured logging**: All Logger calls use keyword metadata. Clean.
- **@moduledoc/@doc**: All new public functions documented. Clean.
