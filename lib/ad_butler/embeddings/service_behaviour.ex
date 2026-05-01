defmodule AdButler.Embeddings.ServiceBehaviour do
  @moduledoc """
  Behaviour wrapping a remote embeddings provider.

  The single batched `embed/1` callback takes a list of texts and returns the
  list of float vectors in the same order. Single-text callers wrap their
  input in a list. Splitting `embed_text/1` and `embed_batch/1` would
  duplicate the provider call, so the behaviour is intentionally batch-only.
  """

  @callback embed([String.t()]) :: {:ok, [[float()]]} | {:error, term()}
end
