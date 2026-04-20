# D0004: Server-rendered charts via Contex for MVP

Date: 2026-04-20
Status: accepted

## Context

The chatbot and the findings inbox both render charts (CPM over time, CTR trends, spend breakdowns by placement, etc.). Two architectural choices:

1. **Server-rendered SVG** via an Elixir charting library (e.g., Contex) — chart markup is part of the LiveView response.
2. **Client-rendered** via a JS library (ApexCharts, Chart.js, uPlot) wired through a LiveView hook.

## Decision

Server-rendered SVG using Contex for MVP.

- Chart rendering is a pure function in a `AdFluxWeb.Charts` module: series data in, SVG string out.
- LiveView assigns the SVG to a chart component and sends it over the wire.
- Inline in chat: LLM emits a structured `render_chart` directive; the chat component fetches the series via a read tool and renders.

## Consequences

- **Fewer moving parts.** No JS hook, no client bundle, no separate state sync for chart data.
- **First paint is fast.** SVG is present in the first LiveView response; no loading spinner pattern.
- **Export is trivial.** A chart is just SVG — "download this chart" is one line. "Email this chart" likewise.
- **Interactivity is limited.** Hover tooltips, zoom, click-to-filter all require JS. Not in MVP; we commit to swapping in a client-rendered layer if users ask.
- **Rendering cost is on the server.** Contex is cheap; a dozen charts per LiveView response is negligible at MVP scale. Revisit if charts become a bottleneck (unlikely).

## When to revisit

- Users explicitly request interactive features (zoom, pan, hover-scrub, cross-filter).
- Chart density per page exceeds what's comfortable as static SVG (e.g., 50+ data points × 10 series × 5 charts on one page).
- We want to animate transitions (live-update as new insights arrive).

At that point, introduce a `ClientChart` LiveView component backed by a hook + ApexCharts or uPlot. Keep the `Charts` module's series-shaping code — only the rendering layer swaps.

## Alternatives considered

- **ApexCharts / Chart.js from day one** — nicer UX but adds JS build complexity and a second rendering path. Overkill for MVP.
- **Vega-Lite spec pushed to client** — elegant but introduces a new mental model for a team that doesn't need it yet.
- **Plot as PNG server-side** — strictly worse than SVG for this workload (no crispness, no responsive resizing, no selective styling).
