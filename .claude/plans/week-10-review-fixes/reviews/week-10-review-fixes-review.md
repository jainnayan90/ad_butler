# Review: week-10-review-fixes

**Date**: 2026-05-02
**Branch**: `week-10-chat-ui` (uncommitted working-tree)
**Plan**: [.claude/plans/week-10-review-fixes/plan.md](../plan.md)
**Reviewers**: elixir-reviewer, security-analyzer, testing-reviewer, iron-law-judge

## Verdict

**PASS WITH WARNINGS** — Three findings worth addressing before commit; one already verified non-issue.

Prior findings (HIGH `unsafe_update_message_tool_results/2` inversion, MEDIUM Chat.Server log-leak at server.ex:153/407, MEDIUM `send_turn_safely/3` rescue) all confirmed RESOLVED by both elixir-reviewer and security-analyzer.

## Findings

### HIGH

**(none)**

`render_async/2` version-gate flagged by elixir-reviewer is verified non-issue:
mix.lock pins `phoenix_live_view 1.1.28`, well past 0.20.17 introduction.
Full test suite already passing confirms.

### MEDIUM

**M1 — Race: `Repo.delete!` may run before `:load` handler completes**
- *testing-reviewer*: `test/ad_butler_web/live/chat_live/show_test.exs:235-244`
- The new W1 test deletes the session row immediately after `live/2`, but
  the `{:load, id}` `handle_info` runs asynchronously. If `:load` fires
  AFTER the delete, `get_session/2` returns `:not_found` and the LV
  redirects to `/chat`, making the subsequent `form(...) |> render_submit()`
  fail with a stale-view error.
- Fix: gate the delete on `assert render(view) =~ "All chats"` (or any
  marker that proves the connected mount populated the session assign)
  before deleting.

**M2 — Misleading `stub(:stop)` in W2 test**
- *elixir-reviewer + testing-reviewer (S-4)*: `test/ad_butler_web/live/chat_live/show_async_error_test.exs:25`
- When `stream/2` raises, `Chat.Server` crashes before `cancel_handle/1`
  reaches `llm_client().stop(handle)` — the stub is dead code. Either
  remove or add a one-line comment explaining it guards a different path
  (cap-hit cancel) that does not apply here.

**M3 — `tool_results_changeset/2` error-clause `@doc` is silent on caller contract**
- *elixir-reviewer*: `lib/ad_butler/chat/message.ex:81-85`
- The error clause returns a `valid?: false` changeset with no dirty
  fields. Passing it to `Repo.update/1` would emit an empty `SET` clause.
  Current callers are safe; future callers may not be.
- Fix: one-line `@doc` addition: "The error-clause changeset is for
  inspection via `errors_on/1` only; never pass it to `Repo.update/1`."

### LOW

**L1 — `Chat.get_message!/2` does not rescue `Ecto.Query.CastError`**
- *security-analyzer*: `lib/ad_butler/chat.ex:216-222`
- The non-bang sibling rescues `CastError` so a malformed UUID returns
  `:not_found`. The bang variant has no rescue, so a malformed UUID
  surfaces as a 500 (`CastError`) rather than the documented
  `Ecto.NoResultsError`. With `binary_id` columns, Ecto raises `CastError`
  on non-UUID-shaped input.
- Why only LOW: no current callers pass untrusted ids to `get_message!/2`
  — only tests. Latent rather than exploitable.
- Fix: rescue `Ecto.Query.CastError -> raise Ecto.NoResultsError, queryable: Message`
  for parity with `get_session!/2`.

**L2 — `render_async(view, 500)` in W1 may be tight on CI**
- *testing-reviewer*: `test/ad_butler_web/live/chat_live/show_test.exs:247`
- W1 involves a sandbox DB call inside `ensure_server/2` (`get_session/2`).
  W2 uses 1_000 ms; W1 should match for consistency on slow CI.

**L3 — Stale section-banner comment**
- *testing-reviewer*: `test/ad_butler/chat_test.exs:511`
- `# update_message_tool_results/2` banner above `describe "get_message/2"`.
  One-line edit.

**L4 — `:any_messages?` comment imprecise**
- *elixir-reviewer*: `lib/ad_butler_web/live/chat_live/show.ex:38-42`
- "No race in practice" is correct but doesn't state the load-bearing
  invariant: `Chat.subscribe/1` is called inside `{:load,_}`, so
  `:turn_complete` can't arrive before subscribe completes.

**L5 — `LogRedactor.redact/1` `@doc` omits `nil`**
- *elixir-reviewer*: `lib/ad_butler/chat/log_redactor.ex:20-26`
- `nil` is an atom and passes through; test covers it but @doc examples
  list only `:timeout` / `:rate_limited`.

### Suggestions (non-blocking polish)

- **S1** — Tighten W4 cap-hit negative assertion to refute on
  `id="streaming-bubble"` rather than the chunk text.
- **S2** — Empty-session placeholder test could add a follow-up
  assertion verifying the placeholder hides on first chunk.

## Iron Laws

PASS — no violations. `LogRedactor` has `@moduledoc` + `@doc` + `@spec`.
No `inspect/1` in Logger metadata fields. No `String.to_atom/1` on user
input. `Repo` only called from contexts. No `rescue` of own code.
DaisyUI bans respected. Streams not bypassed.

## Security

PASS — tenant isolation on `get_message/2` JOIN verified correct
(both `^id` and `^user_id` pinned, cross-tenant test exercises boundary).
`Chat.subscribe/1` auth-naive but caller (LV `:load`) authorizes via
`get_session/2` first. `current_user.id` set by `:require_authenticated`
on_mount, not client-settable. No new logging of secrets, tokens, or
content. Prior log-leak findings closed.

## Tests

PASS WITH WARNINGS — race condition (M1) and stub clarity (M2) are real.
Mox patterns correct (`expect`/`stub` distinguished, `set_mox_global`
justified, `verify_on_exit!` present). `Process.sleep` not used.
Cross-tenant isolation tests exercise the boundary.

## Next Step

Recommend `/phx:triage` to walk through M1/M2/M3 + L1 (the four
material items). Or fix directly — all are small, well-localized.
