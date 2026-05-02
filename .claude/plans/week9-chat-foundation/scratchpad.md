# Scratchpad: week9-chat-foundation

## Dead Ends (DO NOT RETRY)

(none yet — populate as the spike + implementation surface surprises)

## Local Setup Steps

- pgvector + extensions wired in W8 — no additional setup expected for W9.
  Verify `mix run` boots clean before W9D0.
- `OPENAI_API_KEY` and `ANTHROPIC_API_KEY` must be in `.env.local` for the
  W9D0 spike. `.env.example` already has both keys (W7 P0-T2).
- `CLOAK_KEY_DEV` is required even for non-encryption work because
  `config/runtime.exs` hard-fails the dev boot without it. Generate with
  `openssl rand -base64 32`.
- **Dev boot hard-requires RabbitMQ** (`AdButler.Application` calls
  `setup_rabbitmq_topology/0` and `System.stop(1)`s if it can't connect after
  3 retries). Spikes that don't need RabbitMQ should run with
  `mix run --no-start`. Long-term: Week 9 itself doesn't need RabbitMQ; the
  agent context only needs Repo + PubSub. We're not changing this — Week 8's
  metadata pipeline lives there — but the spike runner deliberately avoids
  the full app boot.

## Decisions (Week 9)

Confirmed during W9D0 spike (`priv/spike/run.exs`, output in
`priv/spike/findings.md`).

### D-W9-01 — Jido instance must be supervised by AdButler

`Jido.AgentServer.start_link/1` requires a Jido **instance** to exist (the
instance owns `Jido.Registry`, the agent supervisor, telemetry). Without one
the start raises `ArgumentError: unknown registry: Jido.Registry` from
`Registry.info!/1`.

**Action for W9D2-T1**: in `AdButler.Application` children, add
`{Jido, name: Jido}` (default instance name) before `SessionRegistry` /
`SessionSupervisor`. We can keep our own per-session `SessionRegistry`
(it's a Registry not the Jido one) but the Jido instance is the parent of
every `Jido.AgentServer`.

### D-W9-02 — Jido.Agent struct shape (v2.2)

`SpikeAgent.new/0` returns a `%Jido.Agent{}` struct with these top-level
keys: `:id`, `:name`, `:state`, `:description`, `:vsn`, `:category`,
`:tags`, `:agent_module`, `:schema`. **Our domain state lives in
`agent.state`** (an Elixir map of the keys defined in the `schema:` opt to
`use Jido.Agent`). `:sys.get_state(server_pid)` returns the AgentServer
struct, not the Agent struct directly — read `state.agent.state` to get the
domain map.

**`schema:` is converted to a Zoi schema** at compile time (Zoi is a Zod-style
validator pulled in by jido_ai). Validation happens via `Jido.Agent.validate/2`.

**`initial_state:` works as expected**: passing `initial_state: %{counter:
7, session_id: "abc"}` to `Jido.AgentServer.start_link/1` populates
`agent.state` with those keys (anything outside the schema is stripped per
`unrecognized_keys: :strip`).

### D-W9-03 — ReqLLM telemetry event schema (v1.10)

`[:req_llm, :request, :start]`:
- measurements: `%{system_time: int}`
- metadata keys: `[:mode, :usage, :request_id, :provider, :model,
  :operation, :http_status, :reasoning, :transport, :finish_reason,
  :response_summary, :request_summary]`
- `:usage` is `nil` at start.

`[:req_llm, :token_usage]`:
- **measurements** carry the structured tally (this is what we record):
  - `:tokens` map → `%{input_tokens, output_tokens, cached_tokens,
    cache_creation_tokens, total_tokens, cached_input, cache_creation,
    reasoning_tokens, output_tokens, input_tokens, tool_usage, image_usage,
    add_reasoning_to_cost, input_includes_cached, total_tokens, ...}`.
    The "real" keys we'll persist: `:input_tokens`, `:output_tokens`,
    `:cached_tokens`, `:total_tokens`, `:cache_creation_tokens`.
  - `:cost`, `:total_cost`, `:input_cost`, `:output_cost`, `:reasoning_cost`
    (USD floats).
- metadata keys: `[:mode, :request_id, :provider, :model, :operation,
  :transport]`. Provider is `:openai` / `:anthropic` (atom). Model is
  `%LLMDB.Model{}` struct (we'll `model.id` to store the slug).

`[:req_llm, :request, :stop]`:
- measurements: `%{system_time: int, duration: nanoseconds}`
- metadata.usage is now populated with the same shape as `:token_usage`'s
  measurements.

**`:request_id`** in metadata is generic ("2") — looks like a per-request
counter from ReqLLM internals, **not** something we can use to correlate
back to our chat session. We must still set our own `request_id` on the
chat message and pass it via the ETS context table (`:llm_request_context`
pattern from token-monitoring §4) keyed on the UUID we mint.

**Decision**: `Chat.Telemetry` attaches directly to
`[:req_llm, :token_usage]` and writes an `llm_usage` row from there. We
do NOT re-emit on `[:llm, :request, :stop]` — the existing
`LLM.UsageHandler` was designed for the same set of fields, but having two
emitters writing the same row is a foot-gun. Instead, in W9D2-T8 we
**move** `LLM.UsageHandler` (or its core insertion logic) under
`Chat.Telemetry`, attach to `[:req_llm, :token_usage]` once, and delete the
existing `[:llm, :request, :stop]` attach. This is option (a) in the plan
but inverted (handler lives under Chat, not LLM). Touch `llm_usage` schema
zero, since the columns line up.

### D-W9-04 — Streaming chunk delivery shape

`Jido.AI.stream_text(input, opts)` is a thin facade over
`ReqLLM.stream_text/3`. Returns `{:ok, %ReqLLM.StreamResponse{}}` with
keys `:stream`, `:cancel`, `:context`, `:model`, `:metadata_handle`.

`stream_response.stream` is a **lazy `Stream`** of `%ReqLLM.StreamChunk{}`
structs. Chunk types observed:

- `:content` — has `:text` field, the assistant's actual output
- `:meta` — has `:metadata` map with various fields:
  - `usage` (the running token tally — same shape as the
    `[:req_llm, :token_usage]` event measurements)
  - `keepalive?`, `provider_event` (transport heartbeats — ignore)
  - `finish_reason`, `terminal?` (end-of-turn markers)

Total chunks for a 30-token response: 8 chunks (5 meta, 3 content).
Each `:meta usage` chunk reflects the running tally; the FINAL
`[:req_llm, :token_usage]` telemetry event is what we persist (same data,
emitted once at the end via the request span).

**The stream is single-pass.** Iterating it twice (`Enum.take` then
`Enum.map`) crashes with `(EXIT) no process` because the lazy GenServer
backing it has terminated. Caller must `Enum.to_list/1` once and work off
the list, or fold-as-it-goes.

**Action for W9D2-T4 (`Chat.Server`)**: own the stream consumption inside
the server — for each chunk, broadcast `{:chat_chunk, session_id, text}`
via PubSub to LiveView, and accumulate the assistant-content text into a
local accumulator. On terminal `:meta` chunk, persist the final assistant
message (`status: "complete"`) and let `Chat.Telemetry` write the
`llm_usage` row.

**Action for W10**: LiveView subscribes to `chat:#{session_id}` topic and
appends each `:chat_chunk` payload's text to the rendered assistant
message via `stream_insert/3` or an assign update.

### D-W9-05 — Anthropic prompt caching breakpoint

Not directly probed in W9D0 (no Anthropic streaming call yet uses
`cache_control:`). Carrying the v0.3 plan assumption forward: the
**system prompt** sits as the LAST item in the request with the
`cache_control` breakpoint, per ReqLLM 1.7+. Will validate inline in
W9D5-T3 when `Chat.SystemPrompt.build/1` is exercised against a real call.

## Open Questions

- Whether jido_ai exposes a `max_steps` config or we must enforce the
  6-tool-call cap manually in `Chat.Server`. **Tentatively**: not
  needed — we count in `Chat.Server` per W9D5-T2. If jido_ai adds one
  later, we keep ours as a backstop.
- Whether to use `Jido.AI.stream_text/2` directly from `Chat.Server` or
  go through `ReqLLM.stream_text/3` (skip jido_ai). jido_ai adds
  prompt-builder + tool-binding niceties that we'll likely want in W9D5;
  staying on the `Jido.AI` facade is the working assumption.

## Handoff

(populate at end of week)


### [19:29] WARN: otp-advisor did not write otp-review.md — will re-spawn or extract from message after other agents finish

## API Failure — 2026-05-01 19:34

Turn ended due to API error. Check progress.md for last completed task.
Resume with: /phx:work --continue
