# W9D0 spike findings

Generated: 2026-05-01 11:34:44.401743Z

---

## T1 — Jido.Agent shape

**Module:** `AdButler.Chat.SpikeAgent`
Defined with `use Jido.Agent, name: "spike_agent", schema: [session_id, counter]`.

`SpikeAgent.new/0` returns: ```
%Jido.Agent{
  id: "019de351-d5b8-7dda-bbff-47f8c5f14e65",
  name: "spike_agent",
  description: "W9D0-T1 throwaway agent — confirms Jido 2.2 shape.",
  vsn: nil,
  category: nil,
  agent_module: AdButler.Chat.SpikeAgent,
  state: %{counter: 0, session_id: ""},
  schema: #Zoi.map<
    coerce: false,
    unrecognized_keys: :strip,
    fields: {:doc_cons, "%{", "}"}
  >,
  tags: []
}
```
**Agent struct keys:** [:id, :name, :state, :description, :vsn, :category, :__struct__, :tags, :agent_module, :schema]

`Jido.AgentServer.start_link(agent: SpikeAgent)` → `{:ok, #PID<0.366.0>}`.
`:sys.get_state/1` keys: [:agent_module, :cron_jobs, :partition, :deferred_async_signals, :cron_specs, :debug, :queue, :debug_events, :completion_waiters, :default_dispatch, :cron_restart_timer_refs, :spawn_fun, :cron_restart_attempts, :cron_restart_timers, :lifecycle, :signal_router, :status, :error_count, :processing, :restored_from_storage, :debug_max_events, :registry, :signal_call_inflight, :cron_monitors, :max_queue_size, :signal_call_queue, :agent, :error_policy, :cron_monitor_refs, :id, :__struct__, :orphaned_from, :cron_runtime_specs, :skip_schedules, :jido, :parent, :on_parent_death, :children, :metrics]
State.agent keys: [:id, :name, :state, :description, :vsn, :category, :__struct__, :tags, :agent_module, :schema]

With `initial_state:` map → `agent.state.session_id == "abc-123"`, `counter == 7`.

## T2 — [:req_llm, :token_usage] event shape

Calling `ReqLLM.embed("openai:text-embedding-3-small", ["hello world"])` with attached telemetry…
`embed/2` returned `{:ok, [1 vector(s)]}`.

Captured 3 telemetry event(s):

#### `[:req_llm, :request, :start]`
- **measurements keys:** [:system_time]
- **measurements:** ```
%{system_time: 1777635284456623209}
```
- **metadata keys:** [:mode, :usage, :request_id, :provider, :model, :operation, :http_status, :reasoning, :transport, :finish_reason, :response_summary, :request_summary]
- **metadata summary:** `%{usage: nil, request_id: "2", provider: :openai, model: %LLMDB.Model{extra: %{type: "embedding", family: "text-embedding", reasoning: false, attachment: false, open_weights: false, temperature: false, created: 1705948997, owned_by: "system", tool_call: false}, id: "text-embedding-3-small", name: "Text Embedding 3 Small", family: "text-embedding-3", provider: :openai, cost: %{input: 2.0e-5, output: 0}, tags: nil, model: "text-embedding-3-small", capabilities: %{json: %{native: false, strict: false, schema: false}, tools: %{enabled: false, strict: false, parallel: false, streaming: false}, embeddings: %{min_dimensions: 1, max_dimensions: 1536, default_dimensions: 1536}, chat: true, reasoning: %{enabled: false}, rerank: false, streaming: %{text: true, tool_calls: false}}, release_date: "2024-01-25", limits: %{output: 1536, context: 8191}, base_url: nil, provider_model_id: "text-embedding-3-small", modalities: %{input: [:text], output: [:text, :embedding]}, execution: %{embed: %{path: "/embeddings", family: "openai_embeddings", wire_protocol: "openai_embeddings", transport: "nil", supported: true}}, last_updated: "2024-01-25", knowledge: "2024-01", lifecycle: nil, doc_url: nil, pricing: %{merge: "merge_by_id", currency: "USD", components: [%{id: "tool.web_search", unit: "call", ...}, %{id: "tool.web_search_preview", ...}, %{...}, ...]}, deprecated: false, aliases: [], retired: false, catalog_only: false}, operation: :embedding, http_status: nil}`

#### `[:req_llm, :token_usage]`
- **measurements keys:** [:tokens, :cost, :total_cost, :input_cost, :output_cost, :reasoning_cost]
- **measurements:** ```
%{
  tokens: %{
    input: 2,
    output: 0,
    reasoning: 0,
    cached_input: 0,
    output_tokens: 0,
    input_tokens: 2,
    reasoning_tokens: 0,
    add_reasoning_to_cost: false,
    input_includes_cached: true,
    cache_creation: 0,
    cached_tokens: 0,
    total_tokens: 2,
    tool_usage: %{},
    image_usage: %{},
    cache_creation_tokens: 0
  },
  cost: 0.0,
  total_cost: 0.0,
  input_cost: 0.0,
  output_cost: 0.0,
  reasoning_cost: 0.0
}
```
- **metadata keys:** [:mode, :request_id, :provider, :model, :operation, :transport]
- **metadata summary:** `%{usage: nil, request_id: "2", provider: :openai, model: %LLMDB.Model{extra: %{type: "embedding", family: "text-embedding", reasoning: false, attachment: false, open_weights: false, temperature: false, created: 1705948997, owned_by: "system", tool_call: false}, id: "text-embedding-3-small", name: "Text Embedding 3 Small", family: "text-embedding-3", provider: :openai, cost: %{input: 2.0e-5, output: 0}, tags: nil, model: "text-embedding-3-small", capabilities: %{json: %{native: false, strict: false, schema: false}, tools: %{enabled: false, strict: false, parallel: false, streaming: false}, embeddings: %{min_dimensions: 1, max_dimensions: 1536, default_dimensions: 1536}, chat: true, reasoning: %{enabled: false}, rerank: false, streaming: %{text: true, tool_calls: false}}, release_date: "2024-01-25", limits: %{output: 1536, context: 8191}, base_url: nil, provider_model_id: "text-embedding-3-small", modalities: %{input: [:text], output: [:text, :embedding]}, execution: %{embed: %{path: "/embeddings", family: "openai_embeddings", wire_protocol: "openai_embeddings", transport: "nil", supported: true}}, last_updated: "2024-01-25", knowledge: "2024-01", lifecycle: nil, doc_url: nil, pricing: %{merge: "merge_by_id", currency: "USD", components: [%{id: "tool.web_search", unit: "call", ...}, %{id: "tool.web_search_preview", ...}, %{...}, ...]}, deprecated: false, aliases: [], retired: false, catalog_only: false}, operation: :embedding}`

#### `[:req_llm, :request, :stop]`
- **measurements keys:** [:system_time, :duration]
- **measurements:** ```
%{system_time: 1777635285555412167, duration: 1098788875}
```
- **metadata keys:** [:mode, :usage, :request_id, :provider, :model, :operation, :http_status, :reasoning, :transport, :finish_reason, :response_summary, :request_summary]
- **metadata summary:** `%{usage: [:tokens, :cost, :total_cost, :input_cost, :output_cost, :reasoning_cost], request_id: "2", provider: :openai, model: %LLMDB.Model{extra: %{type: "embedding", family: "text-embedding", reasoning: false, attachment: false, open_weights: false, temperature: false, created: 1705948997, owned_by: "system", tool_call: false}, id: "text-embedding-3-small", name: "Text Embedding 3 Small", family: "text-embedding-3", provider: :openai, cost: %{input: 2.0e-5, output: 0}, tags: nil, model: "text-embedding-3-small", capabilities: %{json: %{native: false, strict: false, schema: false}, tools: %{enabled: false, strict: false, parallel: false, streaming: false}, embeddings: %{min_dimensions: 1, max_dimensions: 1536, default_dimensions: 1536}, chat: true, reasoning: %{enabled: false}, rerank: false, streaming: %{text: true, tool_calls: false}}, release_date: "2024-01-25", limits: %{output: 1536, context: 8191}, base_url: nil, provider_model_id: "text-embedding-3-small", modalities: %{input: [:text], output: [:text, :embedding]}, execution: %{embed: %{path: "/embeddings", family: "openai_embeddings", wire_protocol: "openai_embeddings", transport: "nil", supported: true}}, last_updated: "2024-01-25", knowledge: "2024-01", lifecycle: nil, doc_url: nil, pricing: %{merge: "merge_by_id", currency: "USD", components: [%{id: "tool.web_search", unit: "call", ...}, %{id: "tool.web_search_preview", ...}, %{...}, ...]}, deprecated: false, aliases: [], retired: false, catalog_only: false}, operation: :embedding, http_status: 200}`

## T3 — Streaming chunk delivery

Calling `Jido.AI.stream_text("count to 3", model: "anthropic:claude-haiku-4-5")`…
Returns `%ReqLLM.StreamResponse{}`. Keys: [:stream, :cancel, :context, :__struct__, :model, :metadata_handle]

Total chunks: 8. **The stream is consumed once** — re-iterating crashes the lazy GenServer (recorded as a footgun).

First 20 chunks:
- `[1]` `#StreamChunk<:meta meta: usage>`
- `[2]` `#StreamChunk<:content "">`
- `[3]` `#StreamChunk<:meta meta: keepalive?,provider_event>`
- `[4]` `#StreamChunk<:content "1">`
- `[5]` `#StreamChunk<:content "
2
3">`
- `[6]` `#StreamChunk<:meta meta: usage>`
- `[7]` `#StreamChunk<:meta meta: finish_reason,terminal?>`
- `[8]` `#StreamChunk<:meta meta: terminal?>`

**Chunk type frequencies:** `%{meta: 5, content: 3}`

**Concatenated content text:** ```
1
2
3
```

**Sample :meta usage chunk metadata keys:** `[:usage]`
**Sample :meta usage chunk metadata.usage:** `%{output_tokens: 3, input_tokens: 16, reasoning_tokens: 0, cached_tokens: 0, total_tokens: 19, cache_creation_input_tokens: 0, cache_read_input_tokens: 0}`

---
Spike complete. See priv/spike/findings.md.
