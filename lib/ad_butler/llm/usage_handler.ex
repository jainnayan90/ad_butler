defmodule AdButler.LLM.UsageHandler do
  @moduledoc """
  Telemetry handler that persists LLM usage records to `llm_usage`.

  Attach this handler once at application start via `attach/0`. It listens for
  `[:llm, :request, :stop]` and `[:llm, :request, :exception]` events and
  inserts a row via `Repo.insert/2` with `on_conflict: :nothing` keyed on
  `[:request_id]` for idempotency — retried events produce no duplicate rows.

  The `[:llm, :request, :stop]` event is not yet emitted (no LLM client is
  integrated), so no rows will be written until an LLM client calls
  `:telemetry.execute([:llm, :request, :stop], ...)`. Tests emit the event
  manually using `:telemetry.execute/3`.
  """

  require Logger

  alias AdButler.LLM.Usage
  alias AdButler.Repo

  @handler_id "llm-usage-logger"
  @events [[:llm, :request, :stop], [:llm, :request, :exception]]

  @doc """
  Detaches any existing handler and attaches a fresh one.

  Safe to call multiple times — the detach prevents duplicate subscriptions on
  hot-code reloads.
  """
  def attach do
    :telemetry.detach(@handler_id)

    :telemetry.attach_many(
      @handler_id,
      @events,
      &__MODULE__.handle_event/4,
      nil
    )
  end

  @doc false
  def handle_event([:llm, :request, :stop], measurements, metadata, _config) do
    attrs = build_attrs(measurements, metadata, "success")
    insert_usage(attrs)
  end

  def handle_event([:llm, :request, :exception], measurements, metadata, _config) do
    attrs = build_attrs(measurements, metadata, "error")
    insert_usage(attrs)
  end

  defp build_attrs(measurements, metadata, status) do
    token_counts = extract_token_counts(measurements)
    costs = extract_costs(measurements)

    Map.merge(token_counts, costs)
    |> Map.merge(%{
      user_id: metadata[:user_id],
      conversation_id: metadata[:conversation_id],
      turn_id: metadata[:turn_id],
      purpose: metadata[:purpose] || "chat_response",
      provider: metadata[:provider] || "anthropic",
      model: metadata[:model] || "unknown",
      latency_ms: to_milliseconds(measurements[:duration]),
      status: status,
      request_id: nilify_blank(metadata[:request_id]),
      metadata: encode_metadata(metadata[:extra_metadata])
    })
  end

  defp extract_token_counts(m) do
    %{
      input_tokens: m[:input_tokens] || 0,
      output_tokens: m[:output_tokens] || 0,
      cached_tokens: m[:cached_tokens] || 0
    }
  end

  defp extract_costs(m) do
    %{
      cost_cents_input: m[:cost_cents_input] || 0,
      cost_cents_output: m[:cost_cents_output] || 0,
      cost_cents_total: m[:cost_cents_total] || 0
    }
  end

  defp to_milliseconds(nil), do: nil
  defp to_milliseconds(native), do: System.convert_time_unit(native, :native, :millisecond)

  defp nilify_blank(nil), do: nil
  defp nilify_blank(""), do: nil
  defp nilify_blank(value), do: value

  defp encode_metadata(nil), do: nil

  defp encode_metadata(map) when is_map(map) do
    case Jason.encode(map) do
      {:ok, json} -> json
      {:error, _} -> nil
    end
  end

  defp insert_usage(attrs) do
    changeset = Usage.changeset(%Usage{}, attrs)

    case Repo.insert(changeset, on_conflict: :nothing, conflict_target: [:request_id]) do
      {:ok, _} ->
        :ok

      {:error, changeset} ->
        Logger.warning("LLM usage insert failed", errors: inspect(changeset.errors))
    end
  end
end
