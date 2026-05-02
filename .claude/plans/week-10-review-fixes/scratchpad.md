# Scratchpad: week-10-review-fixes

## Decisions

- **W1 trigger via session-deletion, not LLM mock.** `Chat.Server`'s `:reply, :ok`
  pattern means the GenServer always replies `:ok` even when the LLM stream returns
  `{:error, _}` — error is signalled via PubSub `{:turn_error, ...}` instead. So the
  LiveView's `handle_async {:ok, {:error, _}}` branch can't be triggered by mocking
  the LLM client. Trigger it upstream by deleting the session row between mount and
  submit so `Chat.ensure_server/2` returns `{:error, :not_found}`. No Mox needed,
  keeps the test in `async: true`. Captured in
  `.claude/solutions/testing-issues/liveview-handle-async-error-branch-needs-render-async-20260502.md`.

- **W2 in a separate `async: false` file.** `set_mox_global` is required because
  `Chat.Server` runs under DynamicSupervisor, not linked to the test pid. Mixing
  it into an `async: true` file would be unsound — created
  `test/ad_butler_web/live/chat_live/show_async_error_test.exs`.

- **`Message.tool_results_changeset/2` keeps the original two-clause guard form.**
  First refactor inverted the precedence (Repo.get before list-validation), causing
  an extra DB query for invalid input AND inverted the priority of `:not_found`
  vs changeset error. Reverted to two function clauses with `is_list` guards —
  matches the original semantics with the new shared changeset.

- **Removed `send_turn_safely/3` rescue.** CLAUDE.md prohibits rescuing internal code.
  The `handle_async {:exit, _}` clause already covers `GenServer.call` exits, so the
  rescue was duplicative and masked unexpected bugs as user-facing flashes.

- **`LogRedactor` lives in `AdButler.Chat`.** Reviewer flagged that it's generic
  enough to live in `AdButler.Log`, but it's currently only used in the chat path
  and the move would expand its public API surface across contexts. Leaving in
  `Chat.LogRedactor`; revisit if a non-chat caller appears.

- **Extended redaction to `persist_user_message` and `persist_assistant`.**
  Security review flagged that `Chat.append_message`'s changeset error carries
  `changes: %{content: <user body>}` (or LLM output), so those Logger sites also
  need redaction. Extended PE1 fix beyond just the LLM-stream-error path.

## Dead Ends (DO NOT RETRY)

- **Mocking `LLMClientMock.stream/2` to return `{:error, :rate_limited}` does NOT
  trigger `handle_async {:ok, {:error, _}}`.** `Chat.Server` handles the error
  internally (broadcasts `{:turn_error, ...}` and replies `:ok`), so the LiveView's
  Task gets `:ok`, not `{:error, ...}`. The plan's W1 description suggested this
  approach — it doesn't work. Use the session-deletion trick instead.

- **Don't use `inspect/1` on Logger metadata for the redacted reason.** Pattern is
  `reason: LogRedactor.redact(reason)` — the redactor returns an atom, which the
  Logger formatter serializes as a structured field. Wrapping in `inspect/1` would
  defeat aggregation per
  `.claude/solutions/logging/structured-logger-inspect-defeats-aggregation-20260430.md`.

## Open Questions

- (resolved) `Chat.get_message!/1` referenced outside tests? Only AGENTS.md doc
  example referenced it (illustrative, not real code). Retro-scoped both bang and
  non-bang to `(user_id, id)`.

## Handoff

- W10 review fix queue **closed**. All 10 items addressed. S7 (JS test framework)
  remains deferred.
- 2 new solution docs captured under `.claude/solutions/`:
  - `logging/llm-error-reason-leaks-user-content-into-logs-20260502.md`
  - `testing-issues/liveview-handle-async-error-branch-needs-render-async-20260502.md`
- Test count: 594 (was 579 + 6 new + 9 from existing `async: true` show_test.exs
  additions and chat_test.exs cross-tenant cases). 0 failures.
- Branch `week-10-chat-ui` continues to hold the changes; ready for commit and PR.
