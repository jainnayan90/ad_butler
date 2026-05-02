---
title: "Set telemetry context per LLM call (not per turn) and clear with try/after"
module: "AdButler.Chat.Server"
date: "2026-05-01"
problem_type: telemetry_correlation
component: chat_runtime
symptoms:
  - "ReqLLM `[:req_llm, :token_usage]` events fire but `llm_usage` rows are written under the wrong request_id (or none at all)"
  - "A tool crash inside react_loop leaves a stale context map in the GenServer's process dictionary; the next turn's first usage row inherits the previous turn's request_id"
  - "Tests pass when one LLM call/turn but mis-attribute when the agent recurses through tool calls"
---

## Root cause

`Chat.Telemetry.set_context/1` writes to the *calling process's* dictionary, and ReqLLM emits `[:req_llm, :token_usage]` synchronously in that same process. If you set the context once at the top of `run_turn/2` and recurse through `react_loop/3` for tool-using turns, every recursion shares the same `request_id` — so the bridge writes multiple rows under one ID, and `chat_messages.request_id` (the assistant turn) only matches the last call.

If a tool raises and the recursion unwinds without `clear_context`, the next turn starts with the previous turn's context still in `Process.get(@context_key)`. The first `:token_usage` of the new turn lands under the *old* request_id.

## Fix

Mint `request_id` *per `llm_client().stream/2` call* (not per turn) and wrap the call in `try/after`:

```elixir
defp react_loop(state, messages, ctx) do
  request_id = Ecto.UUID.generate()

  Telemetry.set_context(%{
    user_id: state.user_id,
    conversation_id: state.session_id,
    turn_id: ctx.turn_id,        # one per turn — minted in run_turn
    purpose: "chat_response",
    request_id: request_id       # one per LLM call — minted here
  })

  try do
    handle_stream_result(
      llm_client().stream(messages, tools: Tools.read_tools()),
      state, messages, ctx, request_id
    )
  after
    Telemetry.clear_context()
  end
end
```

Persist the same `request_id` on the assistant `chat_messages` row so the message and the `llm_usage` row correlate end-to-end.

## Test the wiring directly

A unit test that asserts `Telemetry.get_context/0` returns the expected map *during* a stream catches future regressions of the set_context wiring without depending on real telemetry firing:

```elixir
expect(LLMClientMock, :stream, fn _msgs, _opts ->
  send(parent, {:context_during_call, Telemetry.get_context()})
  {:ok, stub_response([content_chunk("ok"), meta_terminal()])}
end)

# ...
assert_receive {:context_during_call, ctx}, 500
assert ctx.request_id  # is_binary
assert ctx.turn_id     # is_binary
assert ctx.user_id == user.id
```

The integration test should also drop any synthetic `:telemetry.execute` call and instead have the LLM stub itself emit `[:req_llm, :token_usage]` — that proves the bridge writes one `llm_usage` row per LLM call and that the final row's `request_id` matches `chat_messages.request_id` for the assistant turn.

## Why turn_id and request_id are both needed

- `turn_id`: one user message → one assistant turn → one ID for grouping all the LLM calls and tool invocations the agent fired.
- `request_id`: one LLM call. Tool-using turns produce N llm_usage rows, one per request_id, all sharing the same turn_id.
