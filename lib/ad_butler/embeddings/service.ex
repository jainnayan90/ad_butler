defmodule AdButler.Embeddings.Service do
  @moduledoc """
  Real `Embeddings.ServiceBehaviour` implementation that delegates to ReqLLM.

  Model spec is read from `Application.get_env(:ad_butler, :embeddings_model)`,
  defaulting to `"openai:text-embedding-3-small"` (1536-dim) — matching the
  `embeddings.embedding` column dimension.

  ReqLLM emits telemetry under `[:req_llm, :token_usage]` which the existing
  `LLM.UsageHandler` bridges into the unified usage ledger (D0009 — to be
  wired in W9). For now, calls to this module are observed by the same handler
  via standard ReqLLM telemetry events.
  """
  @behaviour AdButler.Embeddings.ServiceBehaviour

  @default_model "openai:text-embedding-3-small"

  @doc """
  Generates embeddings for the given list of texts. Returns `{:ok, vectors}`
  with vectors in the same order as the inputs, or `{:error, reason}` on a
  ReqLLM failure (transient — caller should retry on subsequent runs).
  """
  @impl AdButler.Embeddings.ServiceBehaviour
  @spec embed([String.t()]) :: {:ok, [[float()]]} | {:error, term()}
  def embed([]), do: {:ok, []}

  def embed(texts) when is_list(texts) do
    model = Application.get_env(:ad_butler, :embeddings_model, @default_model)
    ReqLLM.embed(model, texts)
  end
end
