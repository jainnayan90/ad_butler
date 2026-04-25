defmodule AdButler.LLM.UsageHandlerTest do
  use AdButler.DataCase, async: false

  import AdButler.Factory

  alias AdButler.LLM.{Usage, UsageHandler}
  alias AdButler.Repo

  setup do
    UsageHandler.attach()
    on_exit(fn -> :telemetry.detach("llm-usage-logger") end)
    user = insert(:user)
    %{user: user}
  end

  defp emit_stop(user_id, request_id, extra \\ %{}) do
    measurements =
      Map.merge(
        %{
          input_tokens: 100,
          output_tokens: 50,
          cached_tokens: 10,
          cost_cents_input: 1,
          cost_cents_output: 2,
          cost_cents_total: 3,
          duration: System.convert_time_unit(250, :millisecond, :native)
        },
        extra[:measurements] || %{}
      )

    metadata =
      Map.merge(
        %{
          user_id: user_id,
          request_id: request_id,
          purpose: "chat_response",
          provider: "anthropic",
          model: "claude-sonnet-4-6"
        },
        extra[:metadata] || %{}
      )

    :telemetry.execute([:llm, :request, :stop], measurements, metadata)
  end

  test "stop event writes a llm_usage row with correct token counts", %{user: user} do
    emit_stop(user.id, "req-001")

    row = Repo.get_by!(Usage, request_id: "req-001")
    assert row.user_id == user.id
    assert row.input_tokens == 100
    assert row.output_tokens == 50
    assert row.cached_tokens == 10
    assert row.cost_cents_total == 3
    assert row.status == "success"
    assert row.model == "claude-sonnet-4-6"
    assert row.latency_ms == 250
  end

  test "duplicate event with same request_id does not write a second row", %{user: user} do
    import Ecto.Query

    emit_stop(user.id, "req-dup")
    emit_stop(user.id, "req-dup")

    count = Repo.aggregate(from(u in Usage, where: u.request_id == "req-dup"), :count, :id)
    assert count == 1
  end

  test "exception event writes a row with status error", %{user: user} do
    :telemetry.execute([:llm, :request, :exception], %{duration: nil}, %{
      user_id: user.id,
      request_id: "req-exception",
      purpose: "chat_response",
      provider: "anthropic",
      model: "claude-sonnet-4-6"
    })

    row = Repo.get_by!(Usage, request_id: "req-exception")
    assert row.status == "error"
    assert row.user_id == user.id
  end

  test "metadata field is stored encrypted (raw bytes, not plaintext JSON)", %{user: user} do
    emit_stop(user.id, "req-enc", metadata: %{extra_metadata: %{"key" => "secret_value"}})

    row = Repo.get_by!(Usage, request_id: "req-enc")

    raw =
      Repo.query!("SELECT metadata FROM llm_usage WHERE request_id = $1", ["req-enc"])
      |> Map.fetch!(:rows)
      |> List.first()
      |> List.first()

    refute is_nil(raw), "expected metadata to be stored"

    refute raw == Jason.encode!(%{"key" => "secret_value"}),
           "metadata should not be plaintext JSON"

    assert Jason.decode!(row.metadata) == %{"key" => "secret_value"},
           "decrypted value should round-trip back to original map"
  end
end
