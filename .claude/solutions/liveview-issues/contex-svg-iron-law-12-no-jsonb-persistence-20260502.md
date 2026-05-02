---
module: "AdButlerWeb.ChatLive.Show, AdButlerWeb.Charts, AdButlerWeb.ChatLive.Components"
date: "2026-05-02"
problem_type: anti_pattern
component: liveview_components
symptoms:
  - "Iron Law #12 (`raw/1` with variable — XSS risk) trips when persisting Contex-rendered SVG strings into a JSONB column and reading them back via `Phoenix.HTML.raw/1`"
  - "Plan called for pre-render-and-persist (D-W10-03) to avoid Contex re-render cost on every reconnect; pre-commit hook blocked the implementation"
  - "Reading rendered_svg from JSONB and feeding it to `raw/1` looks safe (we wrote it ourselves) but is exactly the pattern XSS audits flag"
root_cause: "Contex returns SVG as `{:safe, iolist}` directly. Serializing the iolist into a binary string (via `IO.iodata_to_binary/1`) for JSONB storage discards the safe-tuple guarantee — on read it is just an opaque string, indistinguishable from user input, and rendering it requires `Phoenix.HTML.raw/1` with a variable. The cleaner pattern is to keep the safe-tuple inside the render path: render Contex at display time from the persisted *data* (numeric points + metric), not the persisted SVG."
severity: medium
tags: [contex, svg, xss, iron-law-12, raw, jsonb, charts, phoenix-html, safe-tuple, liveview]
---

# Persisting Contex SVG Strings into JSONB Trips Iron Law #12

## Symptoms

The W10D3 plan (D-W10-03) called for:

1. On `:turn_complete`, take the message's `tool_results`, walk it for
   `get_insights_series` entries, render each via `AdButlerWeb.Charts.line_plot/2`,
   serialize the iolist to a binary, and store it back into the `tool_results`
   JSONB column under a `rendered_svg` key.
2. On every subsequent message render, read `rendered_svg` from JSONB and pipe
   it through `Phoenix.HTML.raw/1` to render without escaping.

The PostToolUse Iron Law verifier blocked step 2:

```
Iron Law #12 (line 98): raw/1 with variable — XSS risk. Sanitize input or
use Phoenix.HTML.safe_to_string/1
```

The variable comes from JSONB. Even though we wrote it, the verifier (correctly)
treats any non-literal `raw/1` argument as an XSS vector — DB writes can be
attacker-controlled or get reused for new flows where the trust assumption
no longer holds.

## Investigation

Contex's `Plot.to_svg/1` returns `{:safe, iolist}` — the safe-tuple is
self-documenting and Phoenix's HEEx renders it without escaping and without
`raw/1`. The act of persisting the iolist as a binary string discards the
safe-tuple type and the trust signal that came with it. To put it back, the
read path must re-add safety — and there is no automatic way to assert that
the round-trip preserved the SVG bytes verbatim.

Iron Law #12 exists because `raw/1` with a variable looks safe in every code
review when the data flow is local but routinely leaks XSS when the source
table later acquires a new writer or the renderer is reused with different
inputs. The right escape hatch is "don't store the rendered HTML; store the
data and re-render."

## Solution

Keep the chart render in the safe-tuple lane end-to-end:

1. Persist only the numeric points (already in the tool result schema —
   `result.points: [%{date, value}, ...]`).
2. Render Contex at display time inside the message-bubble component.

```elixir
# AdButlerWeb.Charts (lib/ad_butler_web/charts.ex)
@spec line_plot([map()], keyword()) :: Phoenix.HTML.safe()
def line_plot(points, opts \\ [])
def line_plot([], _opts), do: {:safe, ""}
def line_plot(points, opts) when is_list(points) do
  # ... build dataset from points, return Plot.to_svg/1 → {:safe, iolist}
end
```

```heex
<%!-- AdButlerWeb.ChatLive.Components.chart_block/1 --%>
<div class="bg-white border border-gray-200 rounded-lg p-4 my-2">
  <div :if={@title} class="text-xs font-medium text-gray-700 mb-2">{@title}</div>
  {Charts.line_plot(@points, title: @title, units: @metric)}
</div>
```

Phoenix.HTML auto-detects `{:safe, iolist}` in `{...}` interpolation and
renders without escaping. No `raw/1`. No JSONB SVG. No Iron Law trip.

The Contex cost (~10ms/chart for 30 points) is paid per render. In practice
this is small relative to the diff/patch path and falls inside the LV's
existing render budget. If profiling later shows it as a hotspot, cache
the result *in process* (assign or ETS keyed on points hash) — never
back to JSONB.

## Reverted decision tracking

The plan's D-W10-03 was documented with an explicit reversal escape hatch:
"drop the persistence call and re-render on read — one-line revert." We
took that path on day one when Iron Law #12 fired. Recorded as a dead-end
in `.claude/plans/week-10-chat-ui/scratchpad.md` so future implementers
don't re-attempt persisting SVG-as-string into JSONB.

## Related

- `assets/js/hooks/chat_scroll.js` — preserves viewport on history-prepend
  pagination; orthogonal to chart cost but in the same render path
- `lib/ad_butler/chat.ex#unsafe_update_message_tool_results/2` — kept in
  the public API with the codebase's `unsafe_` prefix convention for
  hypothetical future cache use cases; currently no caller
- Contex: `Contex.Plot.to_svg/1` returns `{:safe, output}` (deps/contex/lib/chart/plot.ex:242)
