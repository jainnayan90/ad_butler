defmodule AdButler.Chat.Telemetry do
  @moduledoc """
  Telemetry handler that bridges ReqLLM events to the `llm_usage` ledger.

  Replaces the prior `AdButler.LLM.UsageHandler` (which listened to
  `[:llm, :request, :stop]` — an event nothing actually emits). ReqLLM
  emits `[:req_llm, :token_usage]` at the end of every chat / embedding
  request; that's the canonical signal we persist.

  See [scratchpad D-W9-03b](.claude/plans/week9-chat-foundation/scratchpad.md)
  for why we collapsed both handlers into one — single source of truth
  avoids double-counting when two handlers wrote the same row.

  ## Correlation

  ReqLLM's `metadata[:request_id]` is a per-process counter ("2") — not
  usable for chat correlation. Each caller stashes a context map in the
  process dictionary BEFORE issuing the request:

      Chat.Telemetry.set_context(%{
        user_id: user.id,
        conversation_id: session.id,
        turn_id: turn_uuid,
        purpose: "chat_response",
        request_id: turn_uuid
      })

  ReqLLM telemetry handlers fire synchronously in the calling process for
  non-streaming calls and (per W9D0 spike) also for streaming when the
  stream is consumed via `Enum.to_list`/`Enum.reduce_while` in the same
  process. The handler reads the context via `Process.get/1`.

  Embedding calls from background workers (no user context) intentionally
  do not write `llm_usage` rows — those are system-level and not
  user-billable. Workers SHOULD NOT call `set_context/1`.
  """

  require Logger

  alias AdButler.LLM

  @handler_id "chat-llm-usage"
  @context_key :chat_llm_context

  @events [
    [:req_llm, :token_usage],
    [:req_llm, :request, :exception]
  ]

  @doc """
  Detaches the legacy `LLM.UsageHandler` (if present) and attaches this
  handler to ReqLLM events. Idempotent — safe to call repeatedly.
  """
  @spec attach() :: :ok | {:error, term()}
  def attach do
    # Detach the legacy event-stream attachment so we don't double-write.
    :telemetry.detach("llm-usage-logger")
    :telemetry.detach(@handler_id)

    :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil)
  end

  @doc """
  Detaches the handler installed by `attach/0`. Idempotent — returns
  `:ok` whether or not the handler was attached. Tests use this in
  `on_exit` to keep handlers from leaking between cases.
  """
  @spec detach() :: :ok
  def detach do
    _ = :telemetry.detach(@handler_id)
    :ok
  end

  @doc """
  Stashes a correlation context for the current process. Call this
  immediately before invoking `Jido.AI.stream_text/2` or `ReqLLM.embed/2`
  if the call is on behalf of a specific user/session and should be
  recorded to `llm_usage`.

  Required keys: `:user_id`. Other recognised keys: `:conversation_id`,
  `:turn_id`, `:purpose`, `:request_id`. Anything else is ignored.
  """
  @spec set_context(map()) :: :ok
  def set_context(%{user_id: _} = context) when is_map(context) do
    Process.put(@context_key, context)
    :ok
  end

  @doc "Clears the correlation context from the current process."
  @spec clear_context() :: :ok
  def clear_context do
    Process.delete(@context_key)
    :ok
  end

  @doc """
  Returns the current correlation context, or `nil` if none is set.
  """
  @spec get_context() :: map() | nil
  def get_context, do: Process.get(@context_key)

  @doc false
  def handle_event([:req_llm, :token_usage], measurements, metadata, _config) do
    case Process.get(@context_key) do
      nil ->
        :ok

      %{} = context ->
        attrs = build_attrs(measurements, metadata, context, "success")
        insert_usage(attrs)
    end
  end

  def handle_event([:req_llm, :request, :exception], _measurements, metadata, _config) do
    case Process.get(@context_key) do
      nil ->
        :ok

      %{} = context ->
        attrs =
          %{}
          |> put_token_counts(%{})
          |> put_costs(%{})
          |> Map.merge(provider_model_attrs(metadata))
          |> Map.merge(context_attrs(context))
          |> Map.put(:status, "error")

        insert_usage(attrs)
    end
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp build_attrs(measurements, metadata, context, status) do
    tokens = measurements[:tokens] || %{}

    %{}
    |> put_token_counts(tokens)
    |> put_costs(measurements)
    |> Map.merge(provider_model_attrs(metadata))
    |> Map.merge(context_attrs(context))
    |> Map.put(:status, status)
  end

  defp put_token_counts(attrs, tokens) do
    attrs
    |> Map.put(:input_tokens, tokens[:input_tokens] || 0)
    |> Map.put(:output_tokens, tokens[:output_tokens] || 0)
    |> Map.put(:cached_tokens, tokens[:cached_tokens] || tokens[:cache_creation_tokens] || 0)
  end

  defp put_costs(attrs, measurements) do
    attrs
    |> Map.put(:cost_cents_input, dollars_to_cents(measurements[:input_cost]))
    |> Map.put(:cost_cents_output, dollars_to_cents(measurements[:output_cost]))
    |> Map.put(:cost_cents_total, dollars_to_cents(measurements[:total_cost]))
  end

  defp provider_model_attrs(metadata) do
    %{
      provider: provider_string(metadata[:provider]),
      model: model_string(metadata[:model])
    }
  end

  defp context_attrs(context) do
    %{
      user_id: context[:user_id],
      conversation_id: context[:conversation_id],
      turn_id: context[:turn_id],
      purpose: context[:purpose] || "chat_response",
      request_id: context[:request_id]
    }
  end

  defp provider_string(nil), do: "anthropic"
  defp provider_string(provider) when is_atom(provider), do: Atom.to_string(provider)
  defp provider_string(provider) when is_binary(provider), do: provider

  defp model_string(nil), do: "unknown"
  defp model_string(%{id: id}) when is_binary(id), do: id
  defp model_string(model) when is_binary(model), do: model
  defp model_string(_), do: "unknown"

  defp dollars_to_cents(nil), do: 0
  defp dollars_to_cents(usd) when is_number(usd), do: trunc(Float.round(usd * 100, 0))

  defp insert_usage(attrs) do
    case LLM.insert_usage(attrs) do
      :ok ->
        :ok

      {:error, changeset} ->
        Logger.warning("chat: llm_usage insert failed",
          errors: changeset.errors
        )
    end
  end
end
