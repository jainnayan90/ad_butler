# Prior findings — from /phx:full review pass (same session)

These were raised by `elixir-reviewer` and `security-analyzer` during the
`/phx:full` cycle and have been **addressed in the current diff**:

1. **HIGH (elixir-reviewer)** — `unsafe_update_message_tool_results/2`
   inverted validation priority (Repo.get before is_list check).
   ✅ Fixed: restored guard-clause two-arity form, no DB query for
   non-list input, `:not_found` always wins over changeset-error
   when the row is missing.

2. **MEDIUM (security-analyzer)** — `Chat.Server` `persist_user_message`
   error path (server.ex:153) and `persist_assistant` error path
   (server.ex:407) still logged raw `reason` (changeset with user
   content / model output in `.changes`).
   ✅ Fixed: both sites now use `LogRedactor.redact(reason)`.

3. **MEDIUM (elixir-reviewer)** — `send_turn_safely/3` rescued
   `Exception` broadly, violating CLAUDE.md "never rescue your own
   code." `handle_async {:exit, _}` already covers GenServer.call
   exits, so the rescue was duplicative.
   ✅ Fixed: helper deleted; `start_async/3` now invokes
   `Chat.send_message/3` directly.

Items NOT addressed (deliberate):

- **MEDIUM (elixir-reviewer)** — `LogRedactor` placement in
  `AdButler.Chat` rather than `AdButler.Log`. Decision: only chat
  callers today; revisit if a non-chat caller appears. No public-
  surface expansion warranted.

- **MEDIUM (elixir-reviewer)** — `chart_points/1` called twice per
  iteration in `tool_results_block/1` (`:if` guard + `points` attr).
  Decision: pure function over a small list, harmless overhead.

- **LOW (security-analyzer)** — `LogRedactor` collapses
  `{%struct{}, _}` shapes (Req/ReqLLM error structs) to `:unknown`,
  losing triage signal. Decision: conservative behaviour acceptable;
  test at `log_redactor_test.exs:43` documents this as the intended
  outcome.

Reviewers: focus on NEW issues. Mark anything still surfacing here
as PERSISTENT so we know our fix was incomplete.
