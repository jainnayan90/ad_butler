---
module: "AdButlerWeb.FindingDetailLive (and any LiveView using the connected?+nil-assign pattern)"
date: "2026-04-30"
problem_type: anti_pattern
component: liveview
symptoms:
  - "First HTTP paint of a LiveView shows a blank page (or just a navbar) for a fraction of a second before websocket connects and the real content appears"
  - "Users on slow connections / mobile see the blank state long enough to think the page is broken"
  - "Search engines and link previews crawl the blank state — the page looks empty"
  - "`mix test` passes because LV tests run in `connected?/1 == true` mode by default"
root_cause: "The LiveView pattern `if connected?(socket), do: load_data, else: do_nothing` combined with a render template gated `<div :if={@assign}>...</div>` produces an empty render on the disconnected first paint. The static HTML response contains no useful content; only after the websocket upgrade does `handle_params` actually populate the assign. The fix is to render a *deliberate* placeholder (skeleton, loading message, navigation breadcrumb) on the disconnected branch — never let the first paint be blank."
severity: medium
tags: [liveview, ux, disconnected-render, mount, handle-params, ad-butler]
---

# LiveView: Disconnected Render Leaves Page Blank When Assign Is Nil

## Symptoms

A LiveView using this common pattern:

```elixir
def mount(_, _, socket), do: {:ok, assign(socket, :finding, nil)}

def handle_params(%{"id" => id}, _uri, socket) do
  if connected?(socket) do
    case Analytics.get_finding(socket.assigns.current_user, id) do
      {:ok, finding} -> {:noreply, assign(socket, :finding, finding)}
      ...
    end
  else
    {:noreply, socket}        # ← disconnected: do nothing
  end
end

def render(assigns) do
  ~H"""
  <div :if={@finding} class="...">
    {@finding.title}
    ...
  </div>
  """
end
```

Produces a fully-blank `<div>` (or no `<div>` at all) on the first HTTP
response. The user sees a flash of empty page until the websocket upgrades
and `handle_params` re-runs in connected mode.

## Investigation

1. **Read CLAUDE.md "No DB queries in disconnected mount"** — mandates
   guarding DB calls behind `connected?/1`. This is the right rule. The bug
   is in the *render* contract, not the mount contract.
2. **Confirm `mix test` doesn't catch it** — `Phoenix.LiveViewTest.live/2`
   defaults to connected mode. The disconnected-render path needs an
   explicit `live_isolated/2` or a manual GET to the route to surface.
3. **Curl the route or view-source on first paint** — the served HTML for
   the page body is just the wrapping layout chrome. No content, no
   placeholder, no breadcrumb back to the parent index.
4. **The instinct to "just always load in mount"** is wrong — that violates
   the no-DB-in-mount rule and re-introduces the connection-pool exhaustion
   problem `connected?/1` exists to prevent.

## Root Cause

The `if connected?(socket)` guard is a *mount-time* concern (don't burn DB
connections before the websocket is real). The render template is a
*template-time* concern (always produce some useful HTML). Conflating them
by using a single `:if={@assign}` clause makes the render do nothing useful
during the connected/disconnected transition.

The cleanest fix is two render branches: one for "data not yet loaded"
(static-render-friendly placeholder), one for "data loaded" (full page).

## Solution

### Add an explicit "loading" branch to the template

```elixir
def render(assigns) do
  ~H"""
  <div :if={!@finding} class="max-w-4xl mx-auto">
    <div class="mb-6">
      <.link navigate={~p"/findings"} class="text-sm text-blue-600 hover:text-blue-800">
        &larr; Back to Findings
      </.link>
    </div>
    <p class="text-gray-500">Loading finding…</p>
  </div>
  <div :if={@finding} class="max-w-4xl mx-auto">
    ... full page ...
  </div>
  """
end
```

Now the disconnected first paint shows a navigation breadcrumb plus a
"Loading finding…" line. SEO/preview crawlers see meaningful content. The
websocket upgrade swaps in the real page.

### Variants for richer UX

- **Skeleton**: replace the loading line with content-shape divs and a
  `animate-pulse` class (Tailwind) for the duration.
- **Push back to index**: `if !connected?(socket), do: push_navigate(to: ~p"/findings")`
  in `handle_params` — only appropriate when the disconnected page has no
  useful read-only content of its own.

### Tests

Add a disconnected-render test to catch regressions:

```elixir
test "disconnected render shows loading placeholder, not blank page", %{conn: conn} do
  conn = get(conn, ~p"/findings/#{some_id}")
  body = html_response(conn, 200)
  assert body =~ "Loading finding"
  assert body =~ "Back to Findings"
end
```

This runs through the standard `Plug.Conn` pipeline, not LV-connected mode,
so it exercises the disconnected branch.

### Files Changed

- `lib/ad_butler_web/live/finding_detail_live.ex:73-80` — added
  `<div :if={!@finding}>` placeholder branch with back-link + loading text.

## Prevention

- [ ] **For every LiveView that uses `if connected?(socket)` to gate data
      loading, the render template MUST have a non-empty branch for the
      pre-load state.** Verify with `curl <route>` or view-source.
- [ ] **`<div :if={@assign}>` alone is a smell** — it implies the page is
      empty when the assign is nil, which is exactly the disconnected-first-paint
      condition. Pair it with a `<div :if={!@assign}>` placeholder.
- [ ] **Add a disconnected-render test** for any LV that depends on a
      handle_params load. The test is one `get/2` call and a string match.
- [ ] **Don't "fix" by moving the load into mount** — that re-introduces
      the connection-pool risk `connected?/1` exists to prevent.

## Iron Law

Not a numbered Iron Law in CLAUDE.md, but adjacent to:
- "No DB queries in disconnected mount" — this rule is correct; the
  disconnected-render placeholder is its complement.

## Related

- CLAUDE.md "LiveView" + "Pagination" sections
- `lib/ad_butler_web/live/findings_live.ex` — has the same `if connected?(socket), do: send(self(), :reload_on_reconnect)` pattern but with a non-blank initial render (empty stream + filter UI), so it doesn't hit this bug
- Plan: `.claude/plans/week7-fixes/reviews/week7-pass4-triage.md` (W-8 fix)
