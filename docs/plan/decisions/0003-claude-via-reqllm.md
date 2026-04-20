# D0003: Use Claude (via jido_ai / ReqLLM) as the chat LLM for MVP

Date: 2026-04-20
Status: accepted

## Context

The chatbot relies on multi-tool reasoning (ReAct-style) over the user's ad data: identify entities in the question, call read tools, compose results, occasionally propose write tools. Quality of tool-call reasoning, cost per turn, and latency are the three axes that matter.

jido_ai wraps ReqLLM, which supports Anthropic, OpenAI, Google, and several others through a single API. Model choice is a config flag, not a code change.

## Decision

Default chat model: **Claude** (Sonnet class for quality, Haiku class for cheap paths).

- Chat responses and multi-tool reasoning: Claude Sonnet (latest available via ReqLLM at the time of the call).
- Cheap paths — classification, entity extraction before retrieval, finding summarization — Claude Haiku.
- Embeddings: stay on OpenAI's embedding models for now (competitive, well-understood, and decoupled from the chat model choice).
- Configuration via a single `config :adflux, :llm_models` keyword list so swapping is a deploy, not a code change.

## Consequences

- **Strong tool-call reasoning.** Claude models have historically performed well on structured tool use, which is the bulk of chat workload here.
- **Prompt caching available.** Anthropic's prompt caching reduces cost of long-lived system prompts — relevant because the agent's system prompt will include tool definitions and a fixed "you are a media buyer's copilot" preamble. Worth enabling in v0.3.
- **Cost profile is predictable.** Sonnet pricing is higher per token than Haiku/mini-class models but lower average *per turn* when tool calls reduce retries and hallucinations.
- **Token accounting still works.** ReqLLM surfaces Anthropic's token counts (including cached-input tokens) via telemetry, which is already the pattern in `03-token-monitoring.md`.

## When to revisit

- If average cost per chat turn at 100+ users is outside the budget envelope — drop Sonnet → Haiku for more paths, or introduce a cheaper mixed-provider strategy.
- If Anthropic reliability (rate limits, outages) causes user-visible issues — ReqLLM makes failover to OpenAI trivial; keep that as the contingency.
- If a newer model from any provider clearly dominates on multi-tool reasoning evals — re-run eval suite, swap the config flag.

## Alternatives considered

- **GPT-4o / GPT-4o-mini** — cheaper baseline, wider ecosystem, but historically less reliable on multi-step tool chains for this kind of structured domain. Hold as fallback.
- **Gemini 2.x / other** — underweighted for now; re-evaluate when evals say so.
- **Local / open-weight models** — not viable for MVP on a VPS; tool-call quality gap is still large.

## Implementation notes

- Build a small eval harness in v0.3 — 20 representative questions about a real ad account, expected tool sequences, expected numeric citations. Run it whenever the model config changes. This is how we avoid accidentally shipping a model regression.
- Structured output (via `Jido.AI.Actions.Instructor`) is the right pattern for any response that includes numbers the UI renders — forces the LLM to quote them from tool outputs rather than freestyle.
