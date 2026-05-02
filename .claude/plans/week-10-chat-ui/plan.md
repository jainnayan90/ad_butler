# Plan: Week 10 — Chat UI + Streaming + Charts

**Window**: 5 working days (W10D1–W10D5)
**Branch**: `week-10-chat-ui` (current)
**Supersedes**: Week 10 section of [.claude/plans/v0.3-creative-fatigue-chat-mvp/plan.md:244-281](../v0.3-creative-fatigue-chat-mvp/plan.md) — drafted before W9 shipped; this plan reflects W9-built reality.
**Decisions log**: [scratchpad.md](scratchpad.md)

---

## Goal

Ship the chat UI on top of the W9-built backend agent. By end of W10:

- A user can land on `/chat`, see their sessions, start a new one, and converse with the agent.
- Assistant content streams character-by-character into a live "in-flight" bubble; the bubble becomes a stable stream item on `:turn_complete`.
- A `get_insights_series` tool result renders an inline Contex SVG chart inside the assistant message bubble.
- Tool calls render as collapsible blocks (name + args + truncated result).
- Page survives reconnect, browser refresh, and multi-tab on the same conversation without state loss.

Out of scope: write tools (`PauseAd` / `UnpauseAd`), confirmation UI, billing quotas, eval harness — all Week 11.

---

## What Already Exists (W9 baseline — do NOT redesign)

| Component | File | Notes |
|---|---|---|
| `AdButler.Chat` context with `paginate_sessions/2`, `paginate_messages/2`, `send_message/3`, `ensure_server/2`, `append_message/1`, `create_session/1`, `get_session/2`, `unsafe_flip_streaming_messages_to_error/1` | [lib/ad_butler/chat.ex](../../../lib/ad_butler/chat.ex) | Tenant scope via `user_id`; CLAUDE.md compliant |
| `Chat.Server` (per-session GenServer, `:via Registry`, lazy-started under `Chat.SessionSupervisor`, hibernates after 15min) | [lib/ad_butler/chat/server.ex](../../../lib/ad_butler/chat/server.ex) | `send_user_message/2` is **blocking** with `:infinity` timeout |
| Streaming over PubSub on topic `"chat:#{session_id}"` — events: `{:chat_chunk, sid, text}`, `{:tool_result, sid, name, :ok\|:error}`, `{:turn_complete, sid, msg_id}`, `{:turn_error, sid, reason}` | [lib/ad_butler/chat/server.ex:510](../../../lib/ad_butler/chat/server.ex#L510) | Server-side coalescing already in agent (D0012) |
| 5 read tools (`GetAdHealth`, `GetFindings`, `GetInsightsSeries`, `CompareCreatives`, `SimulateBudgetChange`) registered in `Chat.Tools.read_tools/0` | [lib/ad_butler/chat/tools/](../../../lib/ad_butler/chat/tools/) | All return `{:ok, payload}` with tenant scope re-checks |
| `GetInsightsSeries` returns `%{ad_id, metric, window, points: [%{date, value}, ...], summary}` | [lib/ad_butler/analytics.ex:503](../../../lib/ad_butler/analytics.ex#L503) | Drives chart rendering |
| `chat_messages.tool_calls` and `tool_results` JSONB columns | [priv/repo/migrations/](../../../priv/repo/migrations/) | Persisted on `:turn_complete` already |
| Sidebar layout with `<.nav_item>` + `active_nav` atom | [lib/ad_butler_web/components/layouts.ex:141](../../../lib/ad_butler_web/components/layouts.ex#L141) | Six entries; add `:chat` |
| `<.pagination page total_pages>` component (auto-hides at 1) | [lib/ad_butler_web/components/core_components.ex:340](../../../lib/ad_butler_web/components/core_components.ex#L340) | Emits `phx-click="paginate" phx-value-page={n}` |
| `Contex 0.5.0` and `req_llm`, `jido`, `jido_ai` pinned | [mix.exs:84-88](../../../mix.exs#L84) | |
| `mix check.tools_no_repo` alias enforces Repo boundary in chat tools | [mix.exs:117](../../../mix.exs#L117) | Will extend coverage to `lib/ad_butler_web/live/chat_*` (D-W10-04) |

---

## What Does NOT Exist Yet (this plan adds)

- `AdButlerWeb.ChatLive.Index` and `AdButlerWeb.ChatLive.Show` LiveViews
- `Chat.subscribe/1` (PubSub topic encoding wrapper) and `Chat.get_message!/1` (single-message read for `:turn_complete` handler)
- `Chat.update_message_tool_results/2` (persist server-rendered chart SVG)
- `AdButlerWeb.Charts` (pure-function Contex wrapper) and `ChatLive.Components.{message, chart_block, tool_call, streaming_bubble}`
- `ChatScroll` JS hook (auto-scroll + prepend-position-preservation)
- `:chat` route in router; `:chat` nav entry in sidebar
- Disconnected-render placeholder + `Plug.Conn` test for both LiveViews

---

## Decisions (Week 10 specific)

- **D-W10-01 — `start_async/3` for sending.**
  `Chat.Server.send_user_message/2` is blocking. The LiveView calls it inside `start_async/3` and watches `handle_async/3` for cleanup; PubSub drives all interim UI updates. Cast was rejected (no failure path); raw `Task.Supervisor` was rejected (`start_async` is the LiveView-native version of the same thing).
  *Why:* Multi-tab support — both tabs `start_async`, both subscribe; the GenServer serialises calls, both tabs see chunks via PubSub.

- **D-W10-02 — Streaming bubble is an assign, not a stream item.**
  `streaming_chunk: nil | String.t()` accumulates `{:chat_chunk, ...}` deltas. On `{:turn_complete, _, msg_id}`, fetch via `Chat.get_message!/1`, `stream_insert(:messages, msg)`, and clear `streaming_chunk`. Avoids the awkward `stream_delete + stream_insert` swap that placeholder-stream-items would require.

- **D-W10-03 — Pre-render Contex SVG on `:turn_complete` and persist into `tool_results` JSONB.**
  Chart data is historical (immutable closed window). Rendering on every page load redundantly pays Contex cost on every reconnect / multi-tab / pagination prepend. Render once in the LiveView at `:turn_complete` time, persist via `Chat.update_message_tool_results/2`. Subsequent reads return strings. Storage cost ~4–8 KB per chart is acceptable.
  *Reversal*: drop the persistence call and re-render on read — one-line revert.

- **D-W10-04 — `data-no-repo` boundary for ChatLive.**
  Extend the existing `mix check.tools_no_repo` alias to also reject `Repo.` calls in `lib/ad_butler_web/live/chat_*`. LiveView talks to `Chat` context only.

- **D-W10-05 — `ChatScroll` hook owns scroll lifecycle.**
  Single hook on the scroll container handles: (a) auto-scroll-to-bottom on new chunks if user is within 50px of bottom, (b) preserve viewport on history-prepend via `beforeUpdate` capturing `scrollHeight - scrollTop`. No separate "scroll lock" assign.

- **D-W10-06 — DaisyUI audit before merge.**
  CLAUDE.md mandate: `theme_toggle/1` in [layouts.ex:207](../../../lib/ad_butler_web/components/layouts.ex#L207) currently uses `class="card"` — pre-existing leak in unused helper. If chat surface touches it, replace with plain Tailwind. If not, leave for a separate cleanup task and note in scratchpad.

---

## Breadboard

```
Sidebar (existing)
├── Connections | Ad Accounts | Campaigns | Ad Sets | Ads
├── Findings    (existing)
└── Chat        (NEW — :chat active_nav, hero-chat-bubble-left-right)

/chat                        → ChatLive.Index    (sessions list, paginated, "+ New chat")
/chat/:id                    → ChatLive.Show     (message thread + compose)

ChatLive.Show wiring:
  mount/3
    ├─ assign(current_user, session=nil, streaming_chunk=nil, sending=false, page=1, total_pages=1)
    ├─ if connected?(socket): send(self(), {:load, id})
    └─ stream(:messages, [])         # so :stream wrapper renders empty container
  handle_info({:load, id})
    ├─ Chat.get_session(current_user.id, id)  → halt+redirect on :not_found
    ├─ Chat.subscribe(id)                      # wrapper: PubSub.subscribe(AdButler.PubSub, "chat:#{id}")
    ├─ Chat.paginate_messages(session, page: 1, per_page: 50)
    └─ stream(:messages, msgs, reset: true)
  handle_event("send_message", %{"body" => body})
    └─ start_async(:send_turn, fn -> Chat.send_message(user_id, session_id, body) end)
                                # context.send_message/3 ensures server is alive then forwards
  handle_info({:chat_chunk, _, text})       → streaming_chunk = (current || "") <> text
  handle_info({:tool_result, _, name, :ok}) → assign(:tool_indicator, name) (transient)
  handle_info({:turn_complete, _, msg_id})  →
    msg = Chat.get_message!(msg_id)         # NEW context fn
    msg = maybe_render_charts_into_tool_results(msg)
    if msg_changed, do: Chat.update_message_tool_results(msg.id, msg.tool_results)  # NEW
    stream_insert(:messages, msg) + clear streaming_chunk
  handle_info({:turn_error, _, reason})     → clear streaming_chunk + flash error
  handle_async(:send_turn, {:ok, :ok})      → assign(:sending, false)
  handle_async(:send_turn, {:exit, _})      → flash(error) + clear sending
  handle_event("paginate", %{"page" => p})  → push_patch(?page=p)
  handle_params(%{"page" => p})             → load older 50, prepend at: 0
```

---

## Tasks

### Day 1 — Routing, Sidebar, Context Helpers, Sessions Index

- [ ] [W10D1-T1][ecto] Add two helpers to `AdButler.Chat`: (a) `subscribe/1` wrapping `Phoenix.PubSub.subscribe(AdButler.PubSub, "chat:" <> session_id)` (returns `:ok | {:error, term()}`); (b) `get_message!/1` returning a `Chat.Message` by id (raises if not found — used in PubSub handler where we just persisted the row, so it MUST exist). Add `@doc` for both per CLAUDE.md. [lib/ad_butler/chat.ex](../../../lib/ad_butler/chat.ex)
- [ ] [W10D1-T2][ecto] Add `Chat.update_message_tool_results/2` — `(message_id, tool_results)` returns `{:ok, message} | {:error, changeset}`. Single-field changeset, validates list. Used by `ChatLive.Show` to persist server-rendered chart SVG (D-W10-03). [lib/ad_butler/chat.ex](../../../lib/ad_butler/chat.ex)
- [ ] [W10D1-T3] Tests for the three new context fns: `subscribe/1` returns `:ok` and the calling process receives a broadcast; `get_message!/1` raises on bad id and returns a message on good id; `update_message_tool_results/2` writes JSONB and rejects non-list values. [test/ad_butler/chat_test.exs](../../../test/ad_butler/chat_test.exs)
- [ ] [W10D1-T4][liveview] Routes — add `live "/chat", AdButlerWeb.ChatLive.Index` and `live "/chat/:id", AdButlerWeb.ChatLive.Show` inside the existing `:authenticated live_session` block (after the `/findings/:id` line). [lib/ad_butler_web/router.ex:64](../../../lib/ad_butler_web/router.ex#L64)
- [ ] [W10D1-T5][liveview] Sidebar — add `<.nav_item href={~p"/chat"} icon="hero-chat-bubble-left-right" label="Chat" active={@active_nav == :chat} />` immediately after the Findings entry. [lib/ad_butler_web/components/layouts.ex:79-84](../../../lib/ad_butler_web/components/layouts.ex#L79)
- [ ] [W10D1-T6][liveview] `AdButlerWeb.ChatLive.Index` — mounts with `:active_nav, :chat`, gates load behind `connected?/1` via `send(self(), :load)`. `handle_info(:load, …)` calls `Chat.paginate_sessions(current_user.id, page: page, per_page: 50)`, populates a `:sessions` stream + `:total_pages`. Renders a paginated list (most recent first) with title, last_activity_at, and a "+ New chat" button at top-right. Disconnected render shows back-to-Findings link + "Loading…" placeholder. NO DaisyUI classes. [lib/ad_butler_web/live/chat_live/index.ex](../../../lib/ad_butler_web/live/chat_live/index.ex) (new)
- [ ] [W10D1-T7][liveview] "+ New chat" — `phx-click="new_chat"`, calls `Chat.create_session(%{user_id: current_user.id, title: "New chat"})`, then `push_navigate(to: ~p"/chat/#{session.id}")`. On `{:error, changeset}`, flash error; do not navigate.
- [ ] [W10D1-T8] Tests for `ChatLive.Index`: (a) tenant isolation — user B cannot see user A's sessions; (b) "+ New chat" creates a session row + navigates; (c) pagination event patches the URL and updates the stream; (d) disconnected `Plug.Conn` test — `get(conn, ~p"/chat")` returns 200 with "Loading" + back link. [test/ad_butler_web/live/chat_live/index_test.exs](../../../test/ad_butler_web/live/chat_live/index_test.exs) (new)

### Day 2 — ChatLive.Show Skeleton, History Pagination, Disconnected Render

- [ ] [W10D2-T1][liveview] `ChatLive.Show` mount — assigns `current_user, session: nil, streaming_chunk: nil, sending: false, page: 1, total_pages: 1, active_nav: :chat`. Initialises empty `stream(:messages, [])` so the disconnected render doesn't blow up on the `phx-update="stream"` container. If `connected?/1`, `send(self(), {:load, id})`. [lib/ad_butler_web/live/chat_live/show.ex](../../../lib/ad_butler_web/live/chat_live/show.ex) (new)
- [ ] [W10D2-T2][liveview] `handle_info({:load, id}, …)` — `Chat.get_session(current_user.id, id)` (NOT the bang version — handle `:not_found` by `push_navigate(to: ~p"/chat") |> put_flash(:error, "Session not found")`). On success, `Chat.subscribe(id)`, then `Chat.paginate_messages(session, page: 1, per_page: 50)`, then `stream(:messages, msgs, reset: true)` and assign session/total_pages.
- [ ] [W10D2-T3][liveview] `ChatLive.Components.message_bubble/1` — renders one message based on `role`:
   - `"user"`: right-aligned, `bg-blue-600 text-white rounded-2xl px-4 py-2 max-w-2xl`
   - `"assistant"`: left-aligned, `bg-gray-100 text-gray-900` (light) — content rendered as plain text for now, charts/tool_calls in W10D4
   - `"tool"`: collapsed by default — full rendering W10D4 (`tool_call` component); for D2, show one-line summary `Tool: get_findings`
   - `"system_error"`: amber pill `bg-amber-50 text-amber-900 border border-amber-200`, full width
  Plain Tailwind only. No DaisyUI. [lib/ad_butler_web/live/chat_live/components.ex](../../../lib/ad_butler_web/live/chat_live/components.ex) (new)
- [ ] [W10D2-T4][liveview] Older-page pagination — `handle_event("paginate", %{"page" => p}, …)` does `push_patch(to: ~p"/chat/#{id}?page=#{p}")`; `handle_params(%{"page" => p}, _, …)` loads page `p` via `Chat.paginate_messages` and either `reset: true` (page 1) or `Enum.reduce(msgs, socket, &stream_insert(&2, :messages, &1, at: 0))` (older pages). URL stays in sync.
- [ ] [W10D2-T5][liveview] Disconnected-render placeholder — `:if={is_nil(@session)}` block with `<.link navigate={~p"/chat"}>← Back</.link>` + `<p class="text-gray-400 text-sm">Loading…</p>`. Per CLAUDE.md.
- [ ] [W10D2-T6] Tests: (a) tenant isolation — user B mounting `~p"/chat/#{user_a_session.id}"` is redirected with flash; (b) disconnected `Plug.Conn` test asserting `html =~ "Loading"` and `html =~ "Back"`; (c) connected mount populates the stream from existing messages; (d) older-page `push_patch` prepends rather than replaces. [test/ad_butler_web/live/chat_live/show_test.exs](../../../test/ad_butler_web/live/chat_live/show_test.exs) (new)

### Day 3 — Streaming, Compose Form, ChatScroll Hook

- [ ] [W10D3-T1][liveview] Compose form at the bottom of `ChatLive.Show` — plain `<form phx-submit="send_message">` with `<.input type="textarea" name="body" value="" rows="3" placeholder="Ask anything about your campaigns…" />` and a submit button. Disabled when `@sending` true. [lib/ad_butler_web/live/chat_live/show.ex](../../../lib/ad_butler_web/live/chat_live/show.ex)
- [ ] [W10D3-T2][liveview] `handle_event("send_message", %{"body" => body}, …)` — trims body, ignores empty strings, sets `assign(:sending, true)` and `assign(:streaming_chunk, "")`, then `start_async(:send_turn, fn -> Chat.send_message(user_id, session_id, body) end)`. The `Chat.send_message/3` context fn already handles `ensure_server` + forwarding; no LV-side `Chat.Server` knowledge required.
- [ ] [W10D3-T3][liveview] `handle_async(:send_turn, {:ok, :ok}, …)` clears `:sending`. `handle_async(:send_turn, {:ok, {:error, reason}}, …)` clears `:sending` and flashes "Send failed" — log structured `Logger.warning("chat: send failed", session_id: …, reason: reason)`. `handle_async(:send_turn, {:exit, _}, …)` same as `{:error, _}` plus `assign(:streaming_chunk, nil)` (the GenServer crashed mid-turn).
- [ ] [W10D3-T4][liveview] PubSub handlers:
   - `handle_info({:chat_chunk, _sid, text}, …)` → append to `:streaming_chunk` assign
   - `handle_info({:tool_result, _sid, _name, _status}, …)` → no-op for D3 (transient indicator added in D4)
   - `handle_info({:turn_complete, _sid, msg_id}, …)` → fetch via `Chat.get_message!/1`, `stream_insert(:messages, msg)`, clear `:streaming_chunk`. Chart pre-render added in D4 — D3 just stream_inserts the raw message.
   - `handle_info({:turn_complete, _sid, :error}, …)` → cap-hit case, just clear `:streaming_chunk` (system_error row already in DB; will be re-fetched on next mount, so it doesn't appear until reload — acceptable for cap edge case)
   - `handle_info({:turn_error, _sid, reason}, …)` → clear `:streaming_chunk`, log structured warning, flash "Agent error"
- [ ] [W10D3-T5][liveview] `ChatLive.Components.streaming_bubble/1` — renders `@streaming_chunk` with a blinking cursor span (`<span class="animate-pulse">▋</span>`). Same styling as assistant bubble. Rendered with `:if={@streaming_chunk}` outside the `phx-update="stream"` container so it doesn't interfere with stream IDs.
- [ ] [W10D3-T6] `ChatScroll` JS hook — file `assets/js/hooks/chat_scroll.js`. Tracks `this.atBottom` from a `scroll` listener (within 50px of bottom). On `mounted`, scrolls to bottom. On `updated`, only scrolls to bottom if `atBottom`. Wired in `assets/js/app.js` Hooks object. [assets/js/hooks/chat_scroll.js](../../../assets/js/hooks/chat_scroll.js) (new), [assets/js/app.js](../../../assets/js/app.js)
- [ ] [W10D3-T7][liveview] HEEx wiring — wrap `<div id="messages" phx-update="stream">…</div>` and `<div :if={@streaming_chunk}>…</div>` inside `<div id="chat-scroll" phx-hook="ChatScroll" class="flex-1 overflow-y-auto …">…</div>`. The hook attaches to the scrollable container, NOT the stream wrapper.
- [ ] [W10D3-T8] Tests: (a) submitting form with empty body is a no-op; (b) submitting fires `start_async` (mock LLM client to return a 3-chunk stream + persist); (c) `{:chat_chunk, …}` accumulates into the assign and renders into the streaming bubble; (d) `{:turn_complete, …}` lands in the stream and clears the streaming bubble; (e) `{:turn_error, …}` flashes and clears.

### Day 4 — Charts + Tool Call Rendering

- [ ] [W10D4-T1] `AdButlerWeb.Charts` — pure-function module wrapping Contex. Public: `line_plot(points, opts)` accepting `[%{date: Date.t(), value: number()}]` + opts (title, units), returning `{:safe, iolist}`. Disable Contex default styles via `default_style: false`; rely on `app.css` for `.exc-*` overrides if needed (likely not for v1). Includes `@moduledoc` per CLAUDE.md. [lib/ad_butler_web/charts.ex](../../../lib/ad_butler_web/charts.ex) (new)
- [ ] [W10D4-T2] Unit test `AdButlerWeb.Charts.line_plot/2` — given a 7-point series, returned iolist contains `<svg`, `<polyline` (or Contex equivalent), and the date range as text. Pure function, no LV needed. [test/ad_butler_web/charts_test.exs](../../../test/ad_butler_web/charts_test.exs) (new)
- [ ] [W10D4-T3][liveview] `ChatLive.Components.chart_block/1` — receives `series` (the rendered SVG iolist) and `title` (e.g. "spend — last 7d"); wraps in `<div class="bg-white border border-gray-200 rounded-lg p-4 my-2">` with title + svg. No DaisyUI.
- [ ] [W10D4-T4][liveview] `maybe_render_charts/1` private fn in `ChatLive.Show` — given a `Message`, walks `tool_results`, finds entries where `name == "get_insights_series"` and `ok == true`, renders `AdButlerWeb.Charts.line_plot/2` from `result.points`, replaces the result map with the same map plus `:rendered_svg` (iolist serialised to string via `IO.iodata_to_binary/1`). Returns `{message, changed?}`. Idempotent — skips entries that already have `:rendered_svg`.
- [ ] [W10D4-T5][liveview] `handle_info({:turn_complete, _, msg_id}, …)` upgrade — after `Chat.get_message!/1`, run `maybe_render_charts/1`; if `changed?`, call `Chat.update_message_tool_results(msg.id, msg.tool_results)` (errors logged + ignored — UI still shows the chart from in-memory msg). Then `stream_insert`. Per D-W10-03.
- [ ] [W10D4-T6][liveview] `message_bubble/1` upgrade — when assistant message has `tool_results` with `:rendered_svg` entries, render `<.chart_block />` inline below the text content within the same bubble.
- [ ] [W10D4-T7][liveview] `ChatLive.Components.tool_call/1` — collapsible block showing `<details><summary>{tool_name}</summary>{args + truncated result}</details>` (native HTML `<details>` — no JS needed, no DaisyUI `collapse` class). Default closed. Truncate result JSON to 500 chars with `…` suffix. Used for any `tool_results` entry where `:rendered_svg` is absent (i.e. non-chart tools).
- [ ] [W10D4-T8][liveview] Transient tool indicator — on `{:tool_result, _, name, _status}`, set `assign(:current_tool, name)` with a 2-second timer (`Process.send_after(self(), {:clear_tool_indicator, name}, 2000)`). Render as a small grey label `Calling get_findings…` next to the streaming bubble. Clear assign on `clear_tool_indicator` if name still matches.
- [ ] [W10D4-T9] Tests: (a) `maybe_render_charts/1` populates `:rendered_svg` only for `get_insights_series` results; (b) idempotent on re-run; (c) e2e (mocked LLM): user message → chunks → `:turn_complete` with a chart-shaped tool_result → DOM contains an `<svg>` inside the message bubble; (d) tool_call collapsible renders `<details>` block with truncated args.

### Day 5 — Pagination Scroll-Preservation, Polish, E2E Demo, Verify

- [ ] [W10D5-T1] `ChatScroll` hook upgrade — add `beforeUpdate` capturing `this._prevScrollHeight = this.el.scrollHeight; this._prevScrollTop = this.el.scrollTop` when `!this.atBottom`. In `updated`, if `_prevScrollHeight` set, restore via `this.el.scrollTop = this._prevScrollTop + (this.el.scrollHeight - this._prevScrollHeight)` then clear. This preserves viewport when older messages are prepended at `at: 0`. [assets/js/hooks/chat_scroll.js](../../../assets/js/hooks/chat_scroll.js)
- [ ] [W10D5-T2][liveview] "Load older" affordance — instead of (or in addition to) `<.pagination>`, render a `Load older messages` button at the top of the message stream when `@page < @total_pages`, `phx-click="load_older"`, which `push_patch`es to `?page=@page+1`. Clearer UX for chat than numbered pages. Keep `<.pagination>` as fallback for keyboard nav.
- [ ] [W10D5-T3][liveview] `agent_status` indicator — derive from existing assigns: `idle` (no streaming, no sending), `thinking` (sending, no chunks yet), `streaming` (sending + streaming_chunk non-empty). Render as a small status pill in the page header. No new assigns.
- [ ] [W10D5-T4][liveview] Empty session state — when `@session` is loaded but `@streams.messages` is empty (no rows ever), render a centered placeholder: "Start the conversation. Try asking 'What findings do I have today?'" Helps demo and partner onboarding.
- [ ] [W10D5-T5] Extend `mix check.tools_no_repo` alias (per D-W10-04) — second `cmd ! grep` line covering `lib/ad_butler_web/live/chat_*` with the same shell pattern. Update the error message. [mix.exs:117](../../../mix.exs#L117)
- [ ] [W10D5-T6] Integration test (mocked LLM, full e2e) — log in user, create session via "+ New chat", submit message, simulate stream chunks via direct PubSub broadcasts in test, simulate `:turn_complete` after persisting an assistant message with a `get_insights_series` tool_result, assert: streaming_chunk accumulated then cleared, message landed in stream, SVG rendered in DOM, JSONB updated with `rendered_svg`. [test/ad_butler_web/integration/chat_e2e_test.exs](../../../test/ad_butler_web/integration/chat_e2e_test.exs) (new)
- [ ] [W10D5-T7] Demo run on a real ad account — actually use chat for 10 turns. Try: a question that triggers `GetFindings`, one that triggers `GetInsightsSeries`, one that hits the loop cap, one that errors mid-stream. Capture screenshots into `.claude/plans/week-10-chat-ui/screenshots/` (gitignored). Log papercuts in [scratchpad.md](scratchpad.md).
- [ ] [W10D5-T8] DaisyUI audit (D-W10-06) — `grep -rn 'class="\(btn\|card\|badge\|table\|modal\|alert\|navbar\|menu\|tab\|collapse\|tooltip\|progress\|loading\|drawer\)' lib/ad_butler_web/live/chat_*` returns empty. If `theme_toggle` was touched, also clean. If untouched, add a one-line note to scratchpad to file as separate cleanup.
- [ ] [W10D5-T9] Full verification — `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix check.tools_no_repo`, `mix credo --strict`, `mix test` (full suite green). `mix precommit` will fail on `hex.audit` per pre-existing scratchpad note — run the underlying checks individually.

---

## Verification After Each Day

```bash
mix compile --warnings-as-errors
mix format --check-formatted
mix test --only chat
```

End of W10:

```bash
mix compile --warnings-as-errors
mix format --check-formatted
mix check.tools_no_repo   # extended per W10D5-T5
mix credo --strict
mix test                  # full suite
```

---

## Risks (and mitigations)

1. **Multi-tab same-session — broadcast storms.** Two tabs each `start_async`; both receive every chunk. With 50 chunks/turn × 2 tabs × 5 active partners = 500 broadcast deliveries/turn.
   *Mitigation*: PubSub on a single node is in-process message passing — cheap. Real risk is when we move to a clustered Phoenix.PubSub adapter (Redis/PG2). For now, acceptable. Log the broadcast count via telemetry counter `[:chat, :pubsub, :broadcast]` so we have data when we need to optimise.

2. **`Chat.get_message!/1` race with persistence.** `:turn_complete` fires after `Chat.append_message/1` returns, but between PubSub broadcast and the LV's `handle_info`, in theory a different process could delete the message. Pre-existing design: messages are not deleted; risk is theoretical.
   *Mitigation*: catch the `Ecto.NoResultsError` in `handle_info({:turn_complete, _, msg_id}, …)`, log + flash, swallow. Add a test that a missing message id doesn't crash the LV.

3. **Contex SVG persistence balloons row size.** A 30-day insights series renders ~6–10 KB SVG; 5 charts in one assistant message → ~50 KB JSONB row. `chat_messages` already has `tool_results` JSONB — no schema change, but the table grows faster than expected.
   *Mitigation*: per CLAUDE.md, JSONB is fine for this; postgres TOASTs >2KB rows automatically. Track row size via `pg_column_size(tool_results)` aggregate query in W11 if it becomes a concern. Alternative reversal path documented in D-W10-03.

4. **Auto-scroll fights user.** If `updated` fires while user is mid-scroll-up, brief jump.
   *Mitigation*: `atBottom` check uses 50px threshold; actively-scrolling user is far from bottom. Tested manually in W10D5-T7 demo run. If it bites, increase threshold to 100px (one-line change).

5. **Chart pre-render on `:turn_complete` adds latency to bubble appearance.** Contex line plot for 30 points takes ~5–10ms in dev. With 3 charts + JSONB write, ~50ms before bubble shows.
   *Mitigation*: acceptable — the streaming chunks have already painted the content. The bubble swap from `streaming_chunk` to stream item happens on `:turn_complete`. If user notices, move chart render to a Task and `stream_insert` the un-charted message first, then re-insert when chart is ready. Defer until W10D5-T7 reveals an actual problem.

6. **`start_async` task crashes with no useful error in logs.** `handle_async/3 {:exit, reason}` gets the bare reason — chains of supervisor crashes lose the original.
   *Mitigation*: wrap the `start_async` body in a try/rescue and return `{:error, exception}` — the rescued exception lands in `handle_async {:ok, {:error, _}}` cleanly with full info. Add to W10D3-T2.

---

## Self-Check

- **Have you been here before?** `FindingsLive` is the closest sibling — paginated stream, `:active_nav`, scope-bound list, disconnected-render Plug.Conn test. Borrow the pagination + tenant-isolation test patterns wholesale. The streaming + JS-hook side is novel; risk concentrated in W10D3 and W10D5-T1.
- **What's the failure mode you're not pricing in?** PubSub message ordering across pids. The agent broadcasts `chat_chunk` then `turn_complete` synchronously — but `Chat.get_message!/1` on the LV side races against `Chat.append_message/1` on the Server side because the broadcast happens AFTER append returns. So ordering is fine. The actual risk: if the LV re-mounts mid-turn (websocket flap), it re-subscribes and may miss the chunks already broadcast — `streaming_chunk` will be empty and the bubble will pop in fully formed at `:turn_complete`. Acceptable — call it out in the demo W10D5-T7.
- **Where's the Iron Law violation risk?** ChatLive calling `Repo` directly. Mitigated by D-W10-04 (extended `mix check.tools_no_repo`). Second risk: the chart pre-render in `maybe_render_charts/1` mutating the message struct without going through a changeset. Mitigated because the persistence path (`Chat.update_message_tool_results/2`) does the validated changeset; the in-memory mutation is just a render-cache.

---

## Acceptance Criteria

- [ ] User can navigate from any sidebar page → Chat → New chat → start typing.
- [ ] First chunk visible in browser within 1.5s of submit on a typical question.
- [ ] Streaming bubble visibly accumulates text; cursor blinks.
- [ ] On `:turn_complete`, bubble becomes a stable message with chart inline (when applicable).
- [ ] Reload-during-streaming shows the partial assistant message marked `error` (per `terminate/2` behavior) — no half-written content rendered as if complete.
- [ ] Reload-after-completion shows the full conversation including charts (loaded from JSONB, no Contex re-render).
- [ ] Two browser tabs on the same session both stream in real-time.
- [ ] Loop-cap exceeded turn shows a `system_error` row "loop_cap_exceeded" without leaving the LV in a stuck state.
- [ ] Tenant isolation: user B navigating to user A's session URL is redirected with a flash.
- [ ] No DaisyUI component classes anywhere in `lib/ad_butler_web/live/chat_*`.
- [ ] Disconnected-render `Plug.Conn` test green for both Index and Show.

---

## Out of Scope (Week 11+)

- `PauseAd` / `UnpauseAd` write tools and confirmation UI (Week 11 day 1–2).
- `pending_confirmations` schema and consumer flow.
- Per-conversation token cost footer + admin LLM usage page.
- Quota enforcement at `Chat.send_message/3` (Week 11 day 3).
- Eval harness (`mix chat.eval`, 20 questions) — Week 11 day 4.
- Chart types beyond line plots (bar, comparison matrix) — driven by tool additions.
- File/image upload to chat.
- Conversation rename, delete, archive, share.
- Search across conversations.
