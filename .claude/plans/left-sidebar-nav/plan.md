# Plan: Left Collapsible Sidebar Nav

## Goal
Replace the per-page header pattern with a shared collapsible left sidebar containing:
Connections · Ad Accounts · Campaigns · Ad Sets · Ads.
Connections page shows existing MetaConnection cards + an "Add Connection" button.

---

## Context

| Area | Current state |
|------|--------------|
| Layout | `Layouts.app` has Phoenix boilerplate header; each LiveView renders its own full-page header |
| Routes | `/dashboard` (DashboardLive), `/campaigns` (CampaignsLive) |
| Auth redirect | `AuthController` redirects to `/dashboard` after login |
| Accounts ctx | `list_meta_connections/1` returns active only; no all-status variant |
| LiveView session | `live_session :authenticated` — no explicit layout set |

---

## Breadboard

```
root.html.heex
└── Layouts.app (sidebar shell)
    ├── <aside id="app-sidebar">          ← collapsible, JS only
    │   ├── Logo / "A" monogram
    │   ├── nav_item × 5
    │   └── User footer + Logout
    └── <main>
        ├── flash_group
        └── {inner_block}                 ← each LiveView's content

Routes:
  /connections    → ConnectionsLive      (NEW)
  /ad-accounts    → DashboardLive        (rename from /dashboard)
  /campaigns      → CampaignsLive        (existing)
  /ad-sets        → AdSetsLive           (NEW stub)
  /ads            → AdsLive              (NEW stub)
  /dashboard      → redirect /ad-accounts (backward compat)
```

---

## Collapse Mechanism

Pure client-side — no server round-trip:

```elixir
# Toggle button
phx-click={JS.toggle_class("collapsed", to: "#app-sidebar")}

# Sidebar width
class="w-64 [&.collapsed]:w-16 transition-[width] duration-200 overflow-hidden"

# Nav labels (inside sidebar)
class="ml-3 whitespace-nowrap [.collapsed_&]:hidden"

# Chevron icon rotation
class="transition-transform [.collapsed_&]:rotate-180"
```

`[&.collapsed]` = "this element has class `collapsed`"
`[.collapsed_&]` = "an ancestor has class `collapsed`"

---

## Tasks

### Phase 1 — Accounts context

- [x] [ecto] Add `list_all_meta_connections_for_user/1` to `AdButler.Accounts` — `where user_id == ^user_id`, `order_by desc: :inserted_at`
- [x] [ecto] Add test: two users, assert user B's call returns nothing — 3 tests: all-status return, tenant isolation, order

### Phase 2 — Shared layout with sidebar

- [x] [liveview] Update `Layouts.app` in `lib/ad_butler_web/components/layouts.ex` — sidebar shell with `@inner_content`, private `nav_item/1`, collapse toggle via `JS.toggle_class`, user footer with logout, plain Tailwind only

### Phase 3 — Router

- [x] Add `layout: {AdButlerWeb.Layouts, :app}` to `live_session :authenticated`
- [x] Add new routes: `/connections`, `/ad-accounts`, `/ad-sets`, `/ads` inside live_session
- [x] Add `get "/dashboard", AuthController, :dashboard_redirect` → redirects to `/ad-accounts`

### Phase 4 — ConnectionsLive

- [x] [liveview] Create `lib/ad_butler_web/live/connections_live.ex` — grid of connection cards, status badges, Add Connection + Reconnect links, empty state

### Phase 5 — Update DashboardLive

- [x] [liveview] `lib/ad_butler_web/live/dashboard_live.ex` — stripped header/banner/outer wrapper, added `active_nav: :ad_accounts`, paginate patched to `/ad-accounts`

### Phase 6 — Update CampaignsLive

- [x] [liveview] `lib/ad_butler_web/live/campaigns_live.ex` — stripped header/banner/outer wrapper/back-link, added `active_nav: :campaigns`

### Phase 7 — Stub LiveViews

- [x] [liveview] Create `lib/ad_butler_web/live/ad_sets_live.ex` — heading + "Coming soon"
- [x] [liveview] Create `lib/ad_butler_web/live/ads_live.ex` — heading + "Coming soon"

### Phase 8 — AuthController

- [x] Update `lib/ad_butler_web/controllers/auth_controller.ex` — callback redirects to `/connections`
- [x] Added `dashboard_redirect/2` action for `/dashboard` → `/ad-accounts`

### Phase 9 — Verification

- [x] `mix compile --warnings-as-errors` — clean
- [x] `mix format --check-formatted` — clean
- [x] `mix credo --strict` — 0 issues
- [x] `mix test` — 202/205 pass; 3 pre-existing failures (email nil changeset, Meta client email field)

---

## Iron Law Checks

- All user-facing queries still pass through scope/2 ✓ (ConnectionsLive scopes by `current_user`)
- No DaisyUI component classes ✓ (plain Tailwind only)
- No unbounded list loads ✓ (connections are O(1) per user; stubs don't load data)
- Layout handles nil `current_user` ✓ (unauthenticated pages unaffected)

---

## Risks

1. **Layout nesting**: If `Layouts.app` was already wrapping LiveViews with the Phoenix boilerplate
   header, stripping headers from LiveViews is mandatory — otherwise double-header appears.
   → Verify by checking if `live_session` was using the layout implicitly.

2. **`[&.collapsed]` Tailwind**: Arbitrary variants require Tailwind JIT to scan `.ex`/`.heex` files.
   Check `tailwind.config.js` content globs include `lib/**/*.{ex,heex}`.

3. **`navigate` vs `href`** in nav items: Use `<.link navigate={...}>` for LiveView-to-LiveView
   navigation (same live_session = no full reload). Use `href` only for the "Add Connection"
   button (which goes to `/auth/meta`, a controller route outside the live_session).
