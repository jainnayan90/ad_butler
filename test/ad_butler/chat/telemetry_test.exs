defmodule AdButler.Chat.TelemetryTest do
  # async: false — named telemetry handler is global; concurrent runs would clash with :already_exists.
  use AdButler.DataCase, async: false

  import AdButler.Factory

  alias AdButler.Chat.Telemetry, as: ChatTelemetry
  alias AdButler.LLM.Usage
  alias AdButler.Repo

  setup do
    ChatTelemetry.attach()

    on_exit(fn ->
      ChatTelemetry.clear_context()
      ChatTelemetry.detach()
    end)

    :ok
  end

  defp emit_token_usage(opts \\ []) do
    measurements = %{
      tokens: %{
        input_tokens: Keyword.get(opts, :input_tokens, 100),
        output_tokens: Keyword.get(opts, :output_tokens, 50),
        cached_tokens: 10,
        cache_creation_tokens: 0,
        total_tokens: 160
      },
      cost: 0.0009,
      total_cost: Keyword.get(opts, :total_cost, 0.0009),
      input_cost: 0.0006,
      output_cost: 0.0003,
      reasoning_cost: 0.0
    }

    metadata = %{
      provider: :anthropic,
      model: %{id: "claude-sonnet-4-6"},
      operation: :chat,
      request_id: Keyword.get(opts, :req_llm_request_id, "1"),
      transport: :http
    }

    :telemetry.execute([:req_llm, :token_usage], measurements, metadata)
  end

  describe "set_context/1 + req_llm token_usage event" do
    test "writes an llm_usage row with the context's user_id and turn_id" do
      user = insert(:user)

      ChatTelemetry.set_context(%{
        user_id: user.id,
        conversation_id: nil,
        turn_id: nil,
        purpose: "chat_response",
        request_id: "turn-001"
      })

      emit_token_usage()

      row = Repo.get_by!(Usage, request_id: "turn-001")
      assert row.user_id == user.id
      assert row.input_tokens == 100
      assert row.output_tokens == 50
      assert row.cached_tokens == 10
      assert row.provider == "anthropic"
      assert row.model == "claude-sonnet-4-6"
      assert row.status == "success"
      assert row.cost_cents_total == 0
    end

    test "without context, no row is written" do
      ChatTelemetry.clear_context()

      emit_token_usage(req_llm_request_id: "no-context")

      assert Repo.get_by(Usage, request_id: "no-context") |> is_nil()
    end

    test "duplicate emissions with the same request_id stay idempotent" do
      import Ecto.Query

      user = insert(:user)

      ChatTelemetry.set_context(%{
        user_id: user.id,
        purpose: "chat_response",
        request_id: "dup-001"
      })

      emit_token_usage()
      emit_token_usage()

      count = Repo.aggregate(from(u in Usage, where: u.request_id == "dup-001"), :count, :id)
      assert count == 1
    end
  end

  describe "req_llm exception event" do
    test "writes a row with status error" do
      user = insert(:user)

      ChatTelemetry.set_context(%{
        user_id: user.id,
        purpose: "chat_response",
        request_id: "err-001"
      })

      :telemetry.execute(
        [:req_llm, :request, :exception],
        %{system_time: System.system_time(), duration: 0},
        %{provider: :anthropic, model: %{id: "claude-sonnet-4-6"}, operation: :chat}
      )

      row = Repo.get_by!(Usage, request_id: "err-001")
      assert row.status == "error"
      assert row.user_id == user.id
    end
  end

  describe "cost conversion" do
    test "converts dollars to cents (rounded)" do
      user = insert(:user)

      ChatTelemetry.set_context(%{
        user_id: user.id,
        purpose: "chat_response",
        request_id: "cost-001"
      })

      :telemetry.execute(
        [:req_llm, :token_usage],
        %{
          tokens: %{input_tokens: 0, output_tokens: 0, cached_tokens: 0},
          cost: 0.234,
          total_cost: 0.234,
          input_cost: 0.123,
          output_cost: 0.111,
          reasoning_cost: 0.0
        },
        %{provider: :openai, model: %{id: "text-embedding-3-small"}}
      )

      row = Repo.get_by!(Usage, request_id: "cost-001")
      assert row.cost_cents_total == 23
      assert row.cost_cents_input == 12
      assert row.cost_cents_output == 11
    end
  end
end
