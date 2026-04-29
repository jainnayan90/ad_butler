# Iron Law Violations: week-2-auditor-post-review

⚠️ EXTRACTED FROM AGENT MESSAGE (agent denied Write access)

## Summary
- Files scanned: 11
- Violations found: 3 real (1 critical, 2 high) + 1 medium documentation concern

---

## Critical Violations (BLOCKER)

### IL-C1 — Unscoped `get_latest_health_score` — implicit tenant verification only
`lib/ad_butler_web/live/finding_detail_live.ex:26`

`health_score = Analytics.get_latest_health_score(finding.ad_id)`

Ownership is verified indirectly because `finding` came from `get_finding!(current_user, id)`. This is a fragile implicit contract — a future refactor reordering calls would silently expose cross-tenant health data.

**Fix:** Either add a scoped `get_latest_health_score/2` joining through `ad_accounts → meta_connections`, OR rename to `unsafe_get_latest_health_score/1` to match the `Ads` module convention and add an explicit comment documenting the ownership proof chain.

---

## High Violations (WARNING)

### IL-H1 — DB queries run on disconnected mount in `FindingDetailLive.handle_params/3`
`lib/ad_butler_web/live/finding_detail_live.ex:23-34`

`handle_params/3` calls `Analytics.get_finding!` and `Analytics.get_latest_health_score` unconditionally — runs on both HTTP (disconnected) and WebSocket (connected) mount.

**Fix:** Wrap the body with `if connected?(socket)` returning `{:noreply, socket}` on the disconnected pass — same pattern `FindingsLive` uses correctly.

### IL-H2 — Raising function called from `handle_params/3` with no rescue/redirect
`lib/ad_butler_web/live/finding_detail_live.ex:25`

`finding = Analytics.get_finding!(current_user, id)`

A not-found or invalid `id` in the URL raises `Ecto.NoResultsError` uncaught from `handle_params/3`, crashing the LiveView process rather than redirecting gracefully. CLAUDE.md: "Never raise in the happy path."

**Fix:** Add non-raising `Analytics.get_finding/2 → {:ok, f} | {:error, :not_found}` and handle error with `push_navigate(socket, to: ~p"/findings")` and a flash.

---

## Medium (Suggestion)

### IL-M1 — `get_latest_health_score/1` not prefixed `unsafe_`
`lib/ad_butler/analytics.ex:122-136`

The function is documented "UNSAFE" but unlike `Ads` module equivalents is not prefixed `unsafe_`. Rename to `unsafe_get_latest_health_score/1` to match the convention — making bypass-of-scope intent visible at every call site.

---

## Clean (no violations)
- Oban workers use string keys correctly
- Both workers have `unique:` constraints
- No `:float` for money — `:decimal` for scores, `:integer` (cents) for spend
- Both migrations are reversible
- No `String.to_atom` with user input
- No DaisyUI component classes
- `FindingsLive` correctly guards behind `connected?(socket)` in `handle_params/3`
- Streams used for findings list
- Pagination correctly implemented
- `BudgetLeakAuditorWorker` never calls `Repo` directly
