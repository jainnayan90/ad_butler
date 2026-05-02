# Scratchpad: week9-review-fixes

## Dead Ends (DO NOT RETRY)

### DE-RF-01 — `stop_supervised!(pid)` is unsupported in this ExUnit
The W5 plan task asked to swap `stop_supervised!(Server)` for
`stop_supervised!(pid)`. ExUnit 1.18.2 still rejects this with
`could not stop child ID #PID<...> because it was not found` — the
function only accepts the child id (atom/module). The original
`stop_supervised!(Server)` is correct because `start_supervised!({Server,
arg})` registers under the module name. Leave it alone.

## Decisions

### D-RF-01 — Telemetry context placement (B2)

`Chat.Telemetry.set_context/1` writes to the **calling process's** dictionary.
`Chat.Server.react_loop/3` calls `llm_client().stream/2` from the GenServer
process, and ReqLLM emits `[:req_llm, :token_usage]` synchronously in the
*emitting* process — for non-streaming requests this is the caller, for
streaming it's whichever process consumes the stream (per W9D0 spike, also
the caller when we do `Enum.to_list/1`). So the Server's pid IS the right
process to set context on.

**Pattern**:
```elixir
request_id = Ecto.UUID.generate()
Telemetry.set_context(%{
  user_id: ctx.user_id,
  conversation_id: state.session_id,
  turn_id: ctx.turn_id,
  purpose: "chat_response",
  request_id: request_id
})

try do
  llm_client().stream(messages, tools: ...)
  # ...
after
  Telemetry.clear_context()
end
```

The `request_id` UUID we mint here gets stored on the `chat_messages.request_id`
column for the assistant turn — same UUID that will key the `llm_usage` row.

### D-RF-02 — Move terminate logic into Chat context (B1)

`Chat.Server.terminate/2` and `Chat.Server.lookup_user_id/1` both call
`Repo` directly. CLAUDE.md violation. Replace with:

- `Chat.flip_streaming_messages_to_error(session_id)` using
  `Repo.update_all` (resolves W2 N+1 too).
- Store `user_id` in Server state at `init/1` (load via `Chat.get_session/2`
  using a ServerSession schema, OR add `Chat.get_session_user_id(session_id)`
  context fn).

### D-RF-03 — `ensure_server!/1` rename + scope (H3)

Rename to `ensure_server/1`. Make signature `(user_id, session_id)` and
re-validate inside via `get_session/2`. Update sole caller
`Chat.send_message/3` accordingly. The Server itself doesn't need
authorization knowledge — the context layer is the gate.

## Open Questions

(none — all spike findings carry forward from week9-chat-foundation)

## Handoff

(populate at end)
