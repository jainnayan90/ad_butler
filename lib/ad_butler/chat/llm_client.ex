defmodule AdButler.Chat.LLMClient do
  @moduledoc """
  Real `Chat.LLMClientBehaviour` implementation — thin wrapper over
  `Jido.AI.stream_text/2`.

  We do NOT add retry/circuit-breaker logic here; the failure modes
  (rate-limit, transient 5xx) are routed through the existing ReqLLM
  retry config plus the per-turn 6-tool-call cap on `Chat.Server`. Adding
  a second retry layer here would compound latency and confuse log
  aggregation.

  Streaming returns a single-pass `Stream` of `%ReqLLM.StreamChunk{}` —
  see scratchpad D-W9-04. The caller consumes it once.
  """

  @behaviour AdButler.Chat.LLMClientBehaviour

  @default_model "anthropic:claude-sonnet-4-6"

  @doc """
  Issues a streaming request to the configured chat model. `messages` is a
  list of `%{role, content}` maps in OpenAI shape; `opts` is forwarded to
  `Jido.AI.stream_text/2` (e.g. `:tools`, `:max_tokens`, `:cache_control`).

  Returns `{:ok, stream}` on success, `{:error, reason}` on a ReqLLM
  failure (transient — caller should surface to the user, not retry).
  """
  @impl AdButler.Chat.LLMClientBehaviour
  @spec stream([map()], keyword()) :: {:ok, term()} | {:error, term()}
  def stream(messages, opts \\ []) when is_list(messages) and is_list(opts) do
    model =
      Keyword.get(
        opts,
        :model,
        Application.get_env(:ad_butler, :chat_default_model, @default_model)
      )

    forwarded_opts =
      opts
      |> Keyword.delete(:model)
      |> Keyword.put(:model, model)

    case Jido.AI.stream_text(messages, forwarded_opts) do
      {:ok, %ReqLLM.StreamResponse{} = response} -> {:ok, response}
      {:ok, other} -> {:ok, other}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Cancels an in-flight stream. `Jido.AI.stream_text/2` returns a struct
  whose `:cancel` field holds the cancel function; we invoke it if
  present, otherwise no-op.
  """
  @impl AdButler.Chat.LLMClientBehaviour
  @spec stop(term()) :: :ok
  def stop(%ReqLLM.StreamResponse{cancel: cancel}) when is_function(cancel, 0) do
    cancel.()
    :ok
  end

  def stop(_handle), do: :ok
end
