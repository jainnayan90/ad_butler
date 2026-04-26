---
module: "AdButlerWeb.CoreComponents"
date: "2026-04-26"
problem_type: liveview_bug
component: liveview_components
symptoms:
  - "Table rows alternate between very dark (near-black) and faded/blurred backgrounds — text unreadable"
  - "Filter dropdowns visually distorted with wrong background/text contrast"
  - "UI looks correct in light OS mode but breaks in dark OS mode"
root_cause: "DaisyUI component classes (table-zebra, list, list-row) use DaisyUI CSS variables that respond to the active DaisyUI theme (dark/light). When the OS prefers dark mode, DaisyUI's dark theme activates via prefersdark: true, applying very dark base-200/base-300 colors to zebra rows — but page containers use hard-coded Tailwind bg-white/bg-gray-50 that do not respond to DaisyUI themes, causing a high-contrast mismatch."
severity: high
tags: [daisyui, table-zebra, dark-mode, tailwind, core-components, ui-distortion, prefersdark]
---

# DaisyUI `table-zebra` Clashes with Plain Tailwind Page Backgrounds

## Symptoms

- In `DashboardLive` and `CampaignsLive`, the `<.table>` component alternated between
  very dark rows and lighter rows, making text unreadable on dark rows.
- The table appeared correct in some environments but broken in others (OS dark mode).
- Filter `<select>` dropdowns in `CampaignsLive` appeared visually distorted.

## Investigation

1. **Hypothesis: CSS specificity conflict** — checked DaisyUI vs Tailwind utility class order — not the root cause; the styles were applied correctly per their classes.
2. **Hypothesis: missing Tailwind base reset** — checked `app.css` — not the issue.
3. **Root cause found**: `app.css` configures a dark DaisyUI theme with `prefersdark: true`. When the user's OS is in dark mode, DaisyUI automatically activates the dark theme. DaisyUI's `table-zebra` renders alternating rows using `--color-base-200` and `--color-base-300` CSS variables. In the dark theme, these resolve to `oklch(25%)` and `oklch(20%)` — near-black. The page containers (`bg-white`, `bg-gray-50`) are hard-coded Tailwind utilities that **do not** respond to DaisyUI themes, so they stay white/light-gray, creating an ugly mismatch with the near-black zebra rows inside them.

## Root Cause

The project uses DaisyUI's theme system for colors but plain Tailwind utilities for layout/backgrounds. These two systems are incompatible: DaisyUI component classes (`table`, `table-zebra`, `list`, `list-row`) render using DaisyUI CSS variables that shift with the active theme, while the surrounding page markup is pinned to specific Tailwind colors. Any DaisyUI component class placed inside a hard-coded Tailwind container will break in the opposite color mode.

```elixir
# Broken — DaisyUI table-zebra uses theme-aware CSS vars
~H"""
<table class="table table-zebra">
  <thead><tr><th>Name</th></tr></thead>
  <tbody id={@id} phx-update="stream">
    <tr :for={row <- @rows}>...</tr>
  </tbody>
</table>
"""
```

## Solution

Replace all DaisyUI component classes in `core_components.ex` with plain Tailwind utility classes. This makes the component self-contained and immune to DaisyUI theme changes.

```elixir
# Fixed — pure Tailwind, no DaisyUI component classes
~H"""
<div class="overflow-x-auto">
  <table class="min-w-full divide-y divide-gray-200">
    <thead class="bg-gray-50">
      <tr>
        <th
          :for={col <- @col}
          class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider"
        >
          {col[:label]}
        </th>
      </tr>
    </thead>
    <tbody
      id={@id}
      class="bg-white divide-y divide-gray-200"
      phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}
    >
      <tr :for={row <- @rows} id={@row_id && @row_id.(row)} class="hover:bg-gray-50">
        <td
          :for={col <- @col}
          phx-click={@row_click && @row_click.(row)}
          class={["px-6 py-4 text-sm text-gray-900", @row_click && "cursor-pointer"]}
        >
          {render_slot(col, @row_item.(row))}
        </td>
      </tr>
    </tbody>
  </table>
</div>
"""
```

### Files Changed

- [lib/ad_butler_web/components/core_components.ex](lib/ad_butler_web/components/core_components.ex) — Replaced `table table-zebra` with plain Tailwind table utilities

## Prevention

**Rule: Never use DaisyUI component classes in this project.** Only use DaisyUI's theme system for CSS variable definitions (colors, radii). All layout and component markup must use plain Tailwind utility classes.

DaisyUI component classes to avoid: `table`, `table-zebra`, `list`, `list-row`, `list-col-grow`, `btn`, `badge`, `card`, `modal`, `drawer`, `navbar`, `menu`, `tab`, `collapse`, `alert`, `progress`, `loading`, `tooltip`, etc.

- [x] Add to CLAUDE.md prevention rule
- [ ] Add to Iron Laws? (project-specific convention, not a universal Phoenix law)
- [ ] Search `core_components.ex` for remaining DaisyUI classes (`list`, `list-row`) and replace if used in rendered pages

## Related

- `assets/css/app.css` — DaisyUI dark theme configured with `prefersdark: true` — this is the trigger
