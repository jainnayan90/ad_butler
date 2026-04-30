# LiveView Review — Pass 5

**Verdict:** PASS WITH WARNINGS

> Note: written by parent after agent returned findings inline.

---

## finding_detail_live.ex (W-8)

**Shape is correct.** Two-branch `<div :if={!@finding}>` / `<div :if={@finding}>` pattern serves a back-link + "Loading finding…" line on disconnected first paint. SEO/preview crawlers see navigable markup.

**Skeleton suggestion (S):** Replace `<p class="text-gray-500">Loading finding…</p>` with two `animate-pulse` placeholder divs mirroring the two-column grid shape. Prevents layout shift on slow connections. Not blocking.

**`assign_async` not needed.** The load is synchronous and gated behind `connected?/1` in `handle_params/3`. `assign_async` adds complexity without benefit.

**No `phx-update` concern.** No stream on this page; the two `:if` branches toggle a single scalar assign.

**WARNING — disconnected-render test missing.** Solution doc + CLAUDE.md both call for a `get/2`-based test. `FindingDetailLiveTest` has no such test; the blank-page regression could return silently.

---

## findings_live.ex (S-9)

**Assignment order is correct.** `assign(:ad_accounts_list, ad_accounts)` runs before `load_findings(socket)` — the assign is present when the filter dropdown renders.

**Filter/page handle_params flow is correct.** `handle_params/3` calls `load_findings(socket)` which never touches `:ad_accounts_list`. Dropdown data is stable for the session lifetime.

**Stale-dropdown edge case — acceptable, document it.** If a user adds an ad account in another tab, the dropdown won't reflect it until the next reconnect (which triggers `:reload_on_reconnect`). Worth a one-line comment so future readers don't "fix" it back.

**Memory risk — negligible.** `Ads.list_ad_accounts/1` is scoped to one user's meta connections; tens to low hundreds at most.

**WARNING — no test that ad_accounts loads once.** No test verifies `:reload_on_reconnect` populates `:ad_accounts_list`, nor that filter changes don't re-query it. Recommended: assert dropdown option present after connect; assert it persists across `render_change` filter event.

---

## Missing Tests

| Gap | Severity | Recommended fix |
|-----|----------|----------------|
| Disconnected-render test for `FindingDetailLive` | WARNING — mandated by CLAUDE.md + solution doc | `get(conn, ~p"/findings/#{id}")` → assert `"Loading finding"` + `"Back to Findings"` |
| `:reload_on_reconnect` populates ad_accounts | SUGGESTION | Assert dropdown option present after LV connect; assert no re-query on `filter_changed` |
| Stale-dropdown comment | SUGGESTION | One-line `@doc` or inline comment on `handle_info(:reload_on_reconnect, ...)` |
