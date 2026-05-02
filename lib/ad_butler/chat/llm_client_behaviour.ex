defmodule AdButler.Chat.LLMClientBehaviour do
  @moduledoc """
  Behaviour for the chat LLM client. The real implementation
  (`AdButler.Chat.LLMClient`) wraps `Jido.AI.stream_text/2`; tests bind a
  Mox mock via `Application.get_env(:ad_butler, :chat_llm_client)` so the
  agent can be exercised without live API calls.

  ## Stream protocol

  `stream/2` returns `{:ok, stream}` where `stream` is an enumerable of
  `%ReqLLM.StreamChunk{}` (or anything matching that shape — `:type` plus
  `:content` text and `:meta` metadata). The caller is expected to consume
  it exactly once and forward content deltas to PubSub. See
  `.claude/plans/week9-chat-foundation/scratchpad.md` D-W9-04 — the stream
  is single-pass and re-iterating crashes the lazy GenServer backing it.
  """

  @typedoc "A list of OpenAI-flavored message maps: %{role, content, ...}."
  @type messages :: [map()]

  @typedoc "Opaque handle returned by `stream/2`; pass to `stop/1` to cancel."
  @type stream_handle :: term()

  @callback stream(messages :: messages(), opts :: keyword()) ::
              {:ok, stream_handle()} | {:error, term()}

  @callback stop(stream_handle :: stream_handle()) :: :ok
end
