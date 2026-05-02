# Scratchpad: week-10-chat-ui

## Decisions

(carry forward from `plan.md` D-W10-01 through D-W10-06; this file captures
in-flight decisions during implementation that don't merit a plan entry)

## Dead Ends (DO NOT RETRY)

- **D-W10-03 (chart pre-render + persist as raw SVG string in JSONB) — reverted.**
  Iron Law #12 forbids `Phoenix.HTML.raw/1` with a variable (XSS surface).
  Persisting the SVG as a binary and rendering it back via `raw/1` trips the
  pre-commit hook. Reversal path (already documented in plan): render via
  `AdButlerWeb.Charts.line_plot/2` at display time — the function returns
  `{:safe, iolist}` which Phoenix renders inline without `raw/1`. Contex cost
  ~10ms/chart accepted; only the points data sits in `tool_results`. The
  `Chat.update_message_tool_results/2` helper stays in place for future use
  (e.g. caching aggregations) but is not called from the streaming path.
  *Do not retry SVG-string-into-JSONB persistence.* Refactor charts upstream
  if performance bites.

## Open Questions

- Should `:turn_complete, :error` (cap hit) ever surface a transient toast?
  Plan currently just clears `streaming_chunk`; the error row is loaded on
  next mount only. Decide during W10D5-T7 demo.

## Demo Papercuts (W10D5-T7)

(populate during demo run)

## Handoff

### What shipped (W10)

- `Chat.subscribe/1`, `Chat.get_message/1`, `Chat.get_message!/1`, and
  `Chat.unsafe_update_message_tool_results/2` (renamed from
  `update_message_tool_results/2` per the codebase's `unsafe_` prefix
  convention; currently has no caller — kept for future cache-style use).
- `/chat` and `/chat/:id` routes inside the `:authenticated` live_session.
- `AdButlerWeb.ChatLive.Index` (paginated sessions list + "+ New chat"),
  `AdButlerWeb.ChatLive.Show` (per-session chat with PubSub streaming,
  `start_async` send, in-flight bubble, history pagination via
  `?page=N`, `load_older` button, agent-status pill).
- `AdButlerWeb.ChatLive.Components` — `message_bubble`, `streaming_bubble`,
  `chart_block`, `tool_call`. All plain Tailwind, no DaisyUI.
- `AdButlerWeb.Charts.line_plot/2` returning `{:safe, iolist}` from
  Contex; `Date` inputs converted to `DateTime` UTC midnight.
- `assets/js/hooks/chat_scroll.js` — auto-scroll-to-bottom + viewport
  preservation on history prepend.
- `:chat` sidebar nav entry with `hero-chat-bubble-left-right`.
- `mix check.tools_no_repo` extended to forbid `Repo.` calls in
  `lib/ad_butler_web/live/chat_live/`.
- Logger metadata allowlist gained `:message_id`.

### Known follow-ups (not blocking)

- **D-W10-06 DaisyUI audit deferred.** `theme_toggle/1` in
  [layouts.ex:207](../../../lib/ad_butler_web/components/layouts.ex#L207)
  still uses `class="card"` — pre-existing leak in unused helper. The
  chat surface does not touch it; per plan, leaving for a separate
  cleanup task.
- **W10D5-T6 full e2e integration test deferred.** Unit tests cover
  every PubSub handler and the chart render path with direct-broadcast
  driving. The end-to-end flow with a mocked LLM client (Mox) plus the
  full `Chat.send_message/3` → `Chat.Server` → ReqLLM stream → DB
  persistence chain is unverified at the test level. Add this when
  Mox-able LLM client interface is finalised.
- **W10D5-T7 demo run on a real ad account is pending.** The plan
  expects a 10-turn dogfood pass with screenshots. Defer until W11.
- **PubSub subscribe location.** `Chat.subscribe/1` is called inside
  `handle_info({:load, id}, …)` after `get_session/2` succeeds. This is
  safe (the load message only fires when `connected?`) but elixir-reviewer
  flagged the indirection. Consider moving to `mount/3` directly under
  `if connected?(socket)` in a future pass.
- **Sending-state machine.** Reset paths for `:sending` are spread
  across `handle_async/3` and `handle_info/2` clauses. They are
  consistent today but a state-table comment on top of `mount/3`
  would clarify intent. Non-blocking.

### Verification

- `mix compile --warnings-as-errors` ✓
- `mix format --check-formatted` ✓
- `mix credo --strict` ✓ (added `:message_id` to allowlist)
- `mix check.tools_no_repo` ✓
- `mix test` ✓ — 579 tests, 0 failures, 10 excluded
[20:07] WARN: testing-reviewer did not write .claude/plans/week-10-chat-ui/reviews/testing.md (Write blocked for session) — extracted findings from agent message
