# Triage: Week 10 Review-Fixes Review

**Source review**: [.claude/plans/week-10-review-fixes/reviews/week-10-review-fixes-review.md](week-10-review-fixes-review.md)
**Date**: 2026-05-02

## Outcome

- **Fix queue**: 8 items (3 MEDIUM + 5 LOW)
- **Deferred**: 0
- **Skipped**: 2 (S1, S2 — not opted in by user; suggestions only)

---

## Fix Queue

### MEDIUM

- [x] **M1 — W1 test race: gate `Repo.delete!` on `:load` completion**
  - File: [test/ad_butler_web/live/chat_live/show_test.exs:235-244](../../../test/ad_butler_web/live/chat_live/show_test.exs#L235)
  - Approach: insert `assert render(view) =~ "All chats"` (or another marker proving the connected mount populated `:session`) BEFORE `Repo.delete!(session)`. Eliminates the chance that `handle_info({:load, id}, ...)` runs after the delete, redirects the LV away, and breaks the subsequent `form |> render_submit`.

- [x] **M2 — Misleading `stub(:stop)` in W2 crash test**
  - File: [test/ad_butler_web/live/chat_live/show_async_error_test.exs:25](../../../test/ad_butler_web/live/chat_live/show_async_error_test.exs#L25)
  - Approach: when `stream/2` raises, the GenServer crashes before `cancel_handle/1` reaches `llm_client().stop(handle)`. The stub never fires. Remove the line, or replace with a one-line `# crash path may not call :stop; stub guards the cap-hit branch in case the test is later extended` comment.

- [x] **M3 — `Message.tool_results_changeset/2` error-clause `@doc` should warn against `Repo.update/1`**
  - File: [lib/ad_butler/chat/message.ex:81-85](../../../lib/ad_butler/chat/message.ex#L81)
  - Approach: extend the `@doc` with one sentence: "The error-clause changeset is for inspection via `errors_on/1` only; never pass it to `Repo.update/1` — it has no dirty fields and would emit an empty `SET` clause."

### LOW

- [x] **L1 — `Chat.get_message!/2` parity: rescue `Ecto.Query.CastError`**
  - File: [lib/ad_butler/chat.ex:216-222](../../../lib/ad_butler/chat.ex#L216)
  - Approach: mirror the `get_message/2` rescue. Add `rescue Ecto.Query.CastError -> raise Ecto.NoResultsError, queryable: Message`. With `binary_id` columns, Ecto raises `CastError` on non-UUID-shaped input — without the rescue, callers get a 500 instead of the documented `Ecto.NoResultsError`. Also add a test case mirroring the malformed-UUID test on the non-bang.

- [x] **L2 — Bump W1 `render_async` timeout 500ms → 1000ms**
  - File: [test/ad_butler_web/live/chat_live/show_test.exs:247](../../../test/ad_butler_web/live/chat_live/show_test.exs#L247)
  - Approach: match W2's 1_000 ms. The W1 path runs a sandbox DB call inside `ensure_server/2 → get_session/2`; on slow CI 500ms can be tight.

- [x] **L3 — Stale section banner above `describe "get_message/2"`**
  - File: [test/ad_butler/chat_test.exs:511](../../../test/ad_butler/chat_test.exs#L511)
  - Approach: rename the comment `# update_message_tool_results/2` to `# get_message/2`. One-line edit.

- [x] **L4 — `:any_messages?` comment imprecise**
  - File: [lib/ad_butler_web/live/chat_live/show.ex:38-42](../../../lib/ad_butler_web/live/chat_live/show.ex#L38)
  - Approach: replace the "no race in practice" wording with the load-bearing invariant: "`Chat.subscribe/1` is called inside the `{:load,_}` handler; PubSub `:turn_complete` cannot arrive before subscribe completes, so `:any_messages? = true` from `:load` always precedes any `:turn_complete` flip."

- [x] **L5 — `LogRedactor.redact/1` `@doc` should list `nil` as an atom example**
  - File: [lib/ad_butler/chat/log_redactor.ex:20-26](../../../lib/ad_butler/chat/log_redactor.ex#L20)
  - Approach: add `nil` to the parenthetical examples ("Atoms pass through unchanged (`:timeout`, `:rate_limited`, `nil`, …)"). The test already covers it; this just documents the contract.

---

## Skipped

- **S1 — Tighten W4 negative assertion to refute on `id="streaming-bubble"`**
  - Reason: not opted in by user. The current `refute html =~ "partial reply"` already catches the regression; tightening to a regex match would be marginal.

- **S2 — Empty-session placeholder test could verify hide-on-first-chunk**
  - Reason: not opted in by user. The placeholder hide is already exercised indirectly by the connected-mount-with-existing-rows test (which doesn't see the placeholder).

---

## Notes from triage

- All items are well-localized and mechanical. Combined diff is expected to be <60 lines.
- L1 is the only one that touches a documented contract — adding the `CastError` rescue makes `get_message!/2` truly equivalent in shape to `get_session!/2`.
- M1 is a real flake risk; without the `:load` gate, this test would intermittently fail on a slow runner.
