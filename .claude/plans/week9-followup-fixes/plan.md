# Plan: Week 9 Follow-up Fixes

**Source**: [week9-review-fixes-triage.md](.claude/plans/week9-review-fixes/reviews/week9-review-fixes-triage.md)
**Window**: ~45-60 min
**Scope**: 9 review findings (2 Iron-Law auto-approves + 2 HIGH + 5 WARN). All
SUGGESTIONs deferred. Two pre-existing items (worker `inspect/1` cleanup,
CompareCreatives N+1) are out of scope.

Decisions: [scratchpad.md](scratchpad.md).

---

## Goal

Close the security defense-in-depth gaps surfaced in the Week 9 review:

1. The new `Chat.unsafe_*` prefix becomes enforced by `mix check.unsafe_callers`
   instead of just documented.
2. `Chat.Server.start_link/1` is no longer a public-facing entry that bypasses
   `ensure_server/2`.
3. `request_id` is hardened against accidental log/param exposure with `redact:
   true` and a partial unique index, before W10 LiveView surfaces messages.
4. The remaining `inspect/1`-into-jsonb fallback and the missing `Jason.encode!`
   guard rail are removed from the chat hot path.
5. The Logger metadata allowlist gains the `:turn_id` and `:conversation_id`
   keys before any future `Logger.*` call references them.

Out of scope: 5 SUGGESTIONs (comment-only additions, deferred); IL-W2 worker
`inspect/1` cleanup (separate task); CompareCreatives N+1 (W11 TODO).

---

## Verification After Each Phase

```
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix check.tools_no_repo
mix check.unsafe_callers
mix test test/ad_butler/chat/   # fast feedback
```

End-of-plan additionally:
```
mix test                          # full suite (target ≥ 524 green)
mix test --include integration    # 7 RabbitMQ pre-existing fails ok
```

---

## Phase 1 — Logger metadata + filter_parameters (W1 + Sec W-1 partial)

Goal: Logger config + Phoenix param filter ready before any redaction code references them.

- [ ] [P1-T1] Add `:turn_id` and `:conversation_id` to the Logger formatter
  metadata allowlist in [config/config.exs:90-143](config/config.exs#L90).
  Place adjacent to `:session_id` for grep-ability.
- [ ] [P1-T2] Add `"request_id"` to `:filter_parameters` in
  [config/config.exs:148](config/config.exs#L148). Phoenix param logs
  (controller plug) will redact any inbound/outbound param with that key.
- [ ] [P1-T3] **Verify**: phase loop. No tests should break — these are
  pass-through config additions.

---

## Phase 2 — request_id schema hardening (Sec W-1 + Sec W-3 + Test W)

Goal: `request_id` is `redact: true` everywhere and has a partial unique index;
migration column type is documented as verified.

- [ ] [P2-T1] Add `redact: true` to the `:request_id` field in
  [lib/ad_butler/chat/message.ex:32](lib/ad_butler/chat/message.ex#L32).
  Confirm `inspect/1` of a `%Message{}` shows `request_id: ...redacted...`
  via `iex> %AdButler.Chat.Message{request_id: "x"} |> inspect()`.
- [ ] [P2-T2] Add `redact: true` to the `:request_id` field in
  [lib/ad_butler/llm/usage.ex:38](lib/ad_butler/llm/usage.ex#L38).
- [ ] [P2-T3] [ecto] Generate a migration
  `priv/repo/migrations/<TS>_add_request_id_unique_index_to_chat_messages.exs`
  that creates a **partial** unique index:
  ```elixir
  defmodule AdButler.Repo.Migrations.AddRequestIdUniqueIndexToChatMessages do
    use Ecto.Migration

    def change do
      create unique_index(:chat_messages, [:request_id],
        where: "request_id IS NOT NULL",
        name: :chat_messages_request_id_unique_when_present
      )
    end
  end
  ```
  Partial-on-NOT-NULL keeps the user-message rows (no request_id) from
  colliding while still preventing `persist_assistant/3` retries from
  inserting a second row with the same correlation key.
- [ ] [P2-T4] Run `mix ecto.migrate` locally and confirm `\d chat_messages`
  shows the index. Add a one-line test in [chat_test.exs](test/ad_butler/chat_test.exs)
  asserting two assistant messages with the same request_id reject the
  second insert with `Ecto.ConstraintError`.
- [ ] [P2-T5] **Test W resolved by inspection** (not a code change):
  `chat_messages.inserted_at` IS already declared `:utc_datetime_usec`
  in the migration ([priv/repo/migrations/20260501110604_create_chat_messages.exs#L18](priv/repo/migrations/20260501110604_create_chat_messages.exs#L18))
  AND in the schema ([message.ex:34](lib/ad_butler/chat/message.ex#L34)).
  `insert_chat_message_at/4` is therefore safe. Document in scratchpad
  D-FU-01 and check off.
- [ ] [P2-T6] **Verify**: phase loop + the new constraint test.

---

## Phase 3 — Server.ex hardening (IL-W1 + H-2 + Sec W-4)

Goal: `Chat.Server` cannot crash the calling process via `Jason.encode!`,
cannot be lazy-started by an unauthorized caller via direct `start_link`,
and never writes `inspect/1` output into persistent jsonb.

- [ ] [P3-T1] Replace `format_tool_results/1` at
  [server.ex:347-349](lib/ad_butler/chat/server.ex#L347-L349) with a
  non-raising version:
  ```elixir
  defp format_tool_results(results) do
    case Jason.encode(results) do
      {:ok, json} -> String.slice(json, 0, 4_000)
      {:error, reason} ->
        Logger.warning("chat: tool result not encodable",
          session_id: nil, reason: reason
        )
        ~s({"error":"unencodable_tool_result"})
    end
  end
  ```
  Note: the call site in `react_step/7` doesn't carry `session_id` —
  pass it as a second arg instead and log it. (Adjust signature.)
- [ ] [P3-T2] Mark `Chat.Server.start_link/1` `@doc false` at
  [server.ex:55-61](lib/ad_butler/chat/server.ex#L55). Update the
  `@moduledoc` reference at [server.ex:53](lib/ad_butler/chat/server.ex#L53)
  to read "end users go through `Chat.ensure_server/2` — `start_link/1`
  is private to the supervisor".
- [ ] [P3-T3] Replace `serialise_tool_call/1` fallback at
  [server.ex:341-344](lib/ad_butler/chat/server.ex#L341-L344):
  ```elixir
  defp serialise_tool_call(other) do
    Logger.warning("chat: unrecognised tool_call shape",
      session_id: nil, kind: kind_of(other)
    )
    %{"error" => "unrecognised_tool_call_shape"}
  end

  defp kind_of(term) when is_map(term), do: "map"
  defp kind_of(term) when is_struct(term), do: term.__struct__ |> to_string()
  defp kind_of(term) when is_atom(term), do: Atom.to_string(term)
  defp kind_of(_), do: "other"
  ```
  Same `session_id` plumbing note as P3-T1. Decision in scratchpad
  D-FU-02: log without `inspect(other)` to avoid leaking a tool's
  shape into Logger; just classify by kind.
- [ ] [P3-T4] Add a unit test in
  [server_test.exs](test/ad_butler/chat/server_test.exs) for P3-T1:
  pass a tool result containing a value `Jason` cannot encode (e.g.
  `{:ok, %{pid: self()}}`); assert the assistant message is persisted
  with the fallback string instead of crashing the call.
- [ ] [P3-T5] **Verify**: phase loop + new server tests.

---

## Phase 4 — Tooling enforcement (H-1 + W2)

Goal: `mix check.unsafe_callers` enforces the `Chat.unsafe_*` boundary,
and `Helpers.decimal_to_float/1` no longer crashes on unexpected input.

- [ ] [P4-T1] Extend the `check.unsafe_callers` alias in
  [mix.exs](mix.exs) to also forbid `Chat.unsafe_` outside the chat
  Server allowlist:
  ```elixir
  "check.unsafe_callers": [
    "cmd ! grep -rn 'Ads\\.unsafe_' lib/ad_butler_web || (echo 'ERROR: Ads.unsafe_ called from web layer' && exit 1)",
    "cmd ! grep -rn 'Chat\\.unsafe_' lib/ --include='*.ex' --exclude='lib/ad_butler/chat/server.ex' --exclude='lib/ad_butler/chat.ex' || (echo 'ERROR: Chat.unsafe_ called outside Chat.Server' && exit 1)"
  ],
  ```
  The exclude on `lib/ad_butler/chat.ex` is needed because the
  function definitions themselves contain the string. Server is the
  only callsite. Decision in scratchpad D-FU-03 — alternative
  considered (move to `AdButler.Chat.Internal`) and rejected as more
  intrusive than the grep gate.
- [ ] [P4-T2] Run `mix check.unsafe_callers` to confirm it passes
  today, then deliberately add a test call site in
  `lib/ad_butler/embeddings.ex` (touch then revert) to confirm it
  fails when violated.
- [ ] [P4-T3] Add a fall-through clause to
  [lib/ad_butler/chat/tools/helpers.ex:48](lib/ad_butler/chat/tools/helpers.ex#L48):
  ```elixir
  def decimal_to_float(_), do: nil
  ```
  Update the `@spec` to:
  ```elixir
  @spec decimal_to_float(any()) :: nil | float()
  ```
- [ ] [P4-T4] Add a one-line test in
  [test/ad_butler/chat/tools/](test/ad_butler/chat/tools/) (new file
  or existing) asserting `decimal_to_float("not a number") == nil`.
  Pick the existing test file with the most similar surface — likely
  `get_ad_health_test.exs` since it's the heaviest decimal user.
- [ ] [P4-T5] **Verify**: phase loop. `mix precommit` should pass.

---

## Phase 5 — Iron Law auto-approves (W1 + IL-W1)

Goal: handled inline above.

- [x] **W1** — landed in P1-T1.
- [x] **IL-W1** — landed in P3-T1.

(No standalone tasks here — kept the section so the plan's checklist
maps 1:1 with the triage queue.)

---

## Acceptance

- [ ] All 9 triage items either landed (7) or marked
  resolved-by-inspection (1: Test W) or already covered (1: Phase 5 inlined).
- [ ] `mix check.unsafe_callers` rejects a `Chat.unsafe_` call from
  outside the allowlist.
- [ ] `inspect(%AdButler.Chat.Message{request_id: "x"})` shows
  `request_id: ...redacted...`.
- [ ] `inspect(%AdButler.LLM.Usage{request_id: "x"})` shows
  `request_id: ...redacted...`.
- [ ] `chat_messages` has a partial unique index on `request_id WHERE
  request_id IS NOT NULL`; duplicate-insert test passes.
- [ ] `format_tool_results` returns a fallback JSON string when
  `Jason.encode/1` fails — does not raise.
- [ ] `serialise_tool_call/1` fallback writes `{"error" =>
  "unrecognised_tool_call_shape"}` (no `inspect/1`) to jsonb.
- [ ] `Chat.Server.start_link/1` is `@doc false`.
- [ ] Logger formatter allowlist contains `:turn_id` and
  `:conversation_id`.
- [ ] `:filter_parameters` contains `"request_id"`.
- [ ] `Helpers.decimal_to_float(_)` returns `nil` instead of raising.
- [ ] Full test suite green: `mix test` ≥ 524 / 0 / 10 excluded.
- [ ] `mix precommit` clean.

---

## Risks (per Self-Check)

1. **Have you been here before?** Yes — same module surfaces from
   the Week 9 review-fix work. Risk concentrates in P3 because
   `format_tool_results/1` and `serialise_tool_call/1` need an
   added `session_id` parameter and the call sites in `react_step/7`
   need to thread it. The scratchpad change tracks this so the
   diff stays small.

2. **What's the failure mode you're not pricing in?**
   The partial unique index in P2-T3 will reject ANY future code
   path that retries `persist_assistant/3` for the same `request_id`.
   Today no such path exists; if W11 introduces a retry-on-conflict
   pattern (e.g. background re-emission of `:req_llm` token usage),
   we'd need to either reuse the same `request_id` UUID (ok with the
   index) or mint a new one (also ok). The risk is W10 LiveView
   speculatively re-persisting on reconnect — flag in the W10 plan.

3. **Where's the Iron Law violation risk?**
   P3-T1 introduces `Logger.warning(...)` in `format_tool_results/1`.
   Any new metadata key (e.g. `:kind` for the tool-call shape
   classifier in P3-T3) must already be in the allowlist or
   silently drops. Re-check P1-T1 covers everything P3 logs;
   `:kind` is already in the allowlist (line 94 of config.exs).
   Confirmed during planning. No additional allowlist entries needed.
