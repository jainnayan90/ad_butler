# Jido + jido_ai + ReqLLM patterns — Week 9 confirmed

> **Status: CONFIRMED via W9D0 spike (priv/spike/run.exs).** Pinned versions:
> `jido 2.2.0`, `jido_ai 2.1.0`, `req_llm 1.10.0`. Findings in
> `priv/spike/findings.md` and `.claude/plans/week9-chat-foundation/scratchpad.md`
> under "Decisions (Week 9)".

## 1. Jido instance is required at boot

The host application MUST start a Jido instance before any
`Jido.AgentServer.start_link/1` call. Without it,
`ArgumentError: unknown registry: Jido.Registry` is raised from
`Registry.info!/1`.

```elixir
# lib/ad_butler/application.ex children list, before SessionRegistry/SessionSupervisor:
{Jido, name: Jido}
```

The Jido instance owns: `Task.Supervisor`, `Jido.Registry`,
`Jido.RuntimeStore`, and a `DynamicSupervisor` for agents.

## 2. Agent struct shape

`use Jido.Agent, schema: [...]` defines the agent's state schema (compiled to
a Zoi validator). `MyAgent.new/0` returns:

```elixir
%Jido.Agent{
  id: "uuidv7-string",
  name: "spike_agent",
  description: "...",
  agent_module: AdButler.Chat.SpikeAgent,
  state: %{counter: 0, session_id: ""},
  schema: #Zoi.map<...>,
  tags: [],
  vsn: nil,
  category: nil
}
```

Domain state lives at `agent.state`. From a running AgentServer:

```elixir
server_state = :sys.get_state(pid)         # %Jido.AgentServer.State{}
agent = server_state.agent                  # %Jido.Agent{}
domain_state = agent.state                  # %{counter: 0, session_id: ""}
```

`initial_state:` keyword passed to `start_link/1` populates `agent.state`
with whatever the schema accepts (extras are stripped).

## 3. ReqLLM telemetry events

Three events fire per LLM/embedding call. Bridge to our `llm_usage`
ledger via `[:req_llm, :token_usage]` (see §4).

### `[:req_llm, :request, :start]`
- `measurements`: `%{system_time}`
- `metadata`: `[:mode, :usage, :request_id, :provider, :model, :operation,
  :http_status, :reasoning, :transport, :finish_reason, :response_summary,
  :request_summary]`
- `usage` is `nil` here.

### `[:req_llm, :token_usage]`  ← **persist from this**
- `measurements`:
  ```elixir
  %{
    tokens: %{
      input_tokens: 2,
      output_tokens: 0,
      cached_tokens: 0,
      cache_creation_tokens: 0,
      total_tokens: 2,
      reasoning_tokens: 0,
      tool_usage: %{},
      image_usage: %{},
      # plus duplicated keys: :input, :output, :reasoning, :cached_input, etc.
    },
    cost: 0.0,
    total_cost: 0.0,
    input_cost: 0.0,
    output_cost: 0.0,
    reasoning_cost: 0.0
  }
  ```
- `metadata`: `[:mode, :request_id, :provider, :model, :operation, :transport]`
- `provider` is an atom (`:openai`, `:anthropic`). `model` is a `%LLMDB.Model{}`
  struct — use `model.id` for the string slug.

### `[:req_llm, :request, :stop]`
- `measurements`: `%{system_time, duration}` (duration in nanoseconds)
- `metadata.usage` is populated post-call with the same shape as
  `[:req_llm, :token_usage]` measurements.

### Foot-gun: `request_id` in metadata is generic

The `:request_id` field in metadata is a per-process counter (e.g. `"2"`),
not something we minted. **Do NOT use it for chat-message correlation.**
Mint our own UUID, set it on the `chat_messages.request_id` column AND pass
it through the ReqLLM call via opts so it's reflected somewhere we control.

The recommended correlation pattern remains
[token-monitoring §4](docs/plan/decisions/03-token-monitoring.md): mint a
UUID, write `(uuid → context_map)` into `:llm_request_context` ETS BEFORE
the call, and `:ets.take/2` it inside the telemetry handler.

## 4. Telemetry handler placement

We collapse `LLM.UsageHandler` into `Chat.Telemetry` (W9D2-T8). The shape
of the existing `llm_usage` schema lines up with the
`[:req_llm, :token_usage]` measurements 1:1, so we just rewrite the
attachment target.

```elixir
# lib/ad_butler/chat/telemetry.ex (W9D2-T8 sketch)
def attach do
  :telemetry.attach_many(
    "chat-llm-usage",
    [
      [:req_llm, :token_usage],
      [:req_llm, :request, :exception]
    ],
    &__MODULE__.handle/4,
    nil
  )
end

def handle([:req_llm, :token_usage], measurements, metadata, _) do
  # ETS lookup for our context (user_id, session_id, request_id) keyed on
  # the UUID we set as the ReqLLM request_id (NOT metadata[:request_id]).
  context = :ets.take(:llm_request_context, our_uuid_from_metadata(metadata))
  ...
  Repo.insert!(%LlmUsage{
    user_id: context.user_id,
    conversation_id: context.session_id,
    purpose: context.purpose,
    provider: to_string(metadata.provider),
    model: metadata.model.id,
    input_tokens: measurements.tokens.input_tokens,
    output_tokens: measurements.tokens.output_tokens,
    cached_tokens: measurements.tokens.cached_tokens,
    cost_cents_input: trunc(measurements.input_cost * 10_000),
    cost_cents_output: trunc(measurements.output_cost * 10_000),
    cost_cents_total: trunc(measurements.total_cost * 10_000),
    status: "success",
    request_id: context.request_id
  })
end
```

## 5. Streaming chunks

`Jido.AI.stream_text(input, opts)` returns
`{:ok, %ReqLLM.StreamResponse{stream, cancel, context, model, metadata_handle}}`.

`stream_response.stream` is a lazy `Stream` of `%ReqLLM.StreamChunk{}`
structs. Two types observed:

- `:content` — `chunk.text` is a binary delta. May be `""`.
- `:meta` — `chunk.metadata` is a map. Subkeys observed:
  - `:usage` — running token tally
  - `:keepalive?` / `:provider_event` — transport heartbeats; ignore
  - `:finish_reason` — terminal marker
  - `:terminal?` — true on the last meta chunk

### The stream is single-pass

`Enum.take(stream, 5)` consumes the underlying lazy GenServer. Calling
`Enum.map(stream, ...)` after it crashes with `(EXIT) no process`.

**Pattern for `Chat.Server`** — fold once:

```elixir
chunks = Enum.to_list(stream_response.stream)

text =
  chunks
  |> Enum.filter(&(&1.type == :content))
  |> Enum.map(& &1.text)
  |> Enum.join()
```

…or stream-and-broadcast in one pass:

```elixir
stream_response.stream
|> Enum.reduce("", fn
  %ReqLLM.StreamChunk{type: :content, text: t}, acc ->
    Phoenix.PubSub.broadcast(AdButler.PubSub, "chat:#{session_id}",
      {:chat_chunk, t})
    acc <> t

  %ReqLLM.StreamChunk{type: :meta, metadata: %{terminal?: true}}, acc ->
    acc

  _, acc -> acc
end)
```

The final `[:req_llm, :token_usage]` event fires after the stream exhausts —
that's our cue to persist the `llm_usage` row, separately from the
streaming-content path.

## 6. What we still don't know

- **Anthropic `cache_control` breakpoint placement** in v1.10 — not
  exercised in W9D0 (no system prompt yet). Validated inline in W9D5-T3
  when `SystemPrompt.build/1` lands.
- **`Jido.AI` tool binding signature** — we'll write `Jido.Action`-shaped
  modules in W9D3 and confirm whether `tools:` is per-call or per-agent at
  registration time.
- **Loop / max_steps config** — jido_ai may or may not expose one. We
  enforce the 6-tool-call cap in `Chat.Server` regardless (D0010 +
  W9D5-T2), so this is not a blocker.
