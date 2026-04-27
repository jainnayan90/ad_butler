defmodule Mix.Tasks.AdButler.ReplayDlqUnitTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.AdButler.ReplayDlq

  # Publish always fails — used to test the nack-and-stop path.
  defmodule AMQPBasicStub do
    @behaviour AdButler.AMQPBasicBehaviour

    def get(_ch, _queue, _opts),
      do:
        {:ok, Jason.encode!(%{"ad_account_id" => "550e8400-e29b-41d4-a716-446655440000"}),
         %{delivery_tag: :tag1}}

    def publish(_ch, _exchange, _routing_key, _payload, _opts),
      do: {:error, :channel_closed}

    def nack(_ch, tag, _opts) do
      send(:drain_dlq_test, {:nacked, tag})
      :ok
    end

    def ack(_ch, _tag), do: :ok
  end

  # Returns a sequence of responses from the registered `:finite_stub_agent`.
  # Responses: `:bad_json` | `:bad_uuid` | `:empty` | `{:ok, payload}`.
  defmodule AMQPBasicFiniteStub do
    @behaviour AdButler.AMQPBasicBehaviour

    def get(_ch, _queue, _opts) do
      case Agent.get_and_update(:finite_stub_agent, fn [h | t] -> {h, t} end) do
        :bad_json ->
          {:ok, "not json", %{delivery_tag: :bad_tag}}

        :bad_uuid ->
          {:ok, Jason.encode!(%{"ad_account_id" => "not-a-uuid"}), %{delivery_tag: :uuid_tag}}

        :empty ->
          {:empty, %{}}

        {:ok, payload} ->
          {:ok, payload, %{delivery_tag: :ok_tag}}
      end
    end

    def publish(_ch, _exchange, _routing_key, _payload, _opts), do: :ok

    def ack(_ch, tag) do
      send(:drain_dlq_test, {:acked, tag})
      :ok
    end

    def nack(_ch, _tag, _opts), do: :ok
  end

  setup do
    Process.register(self(), :drain_dlq_test)

    on_exit(fn ->
      Application.delete_env(:ad_butler, :amqp_basic)
      # Guard against a mid-test crash leaving :finite_stub_agent registered to a dead PID,
      # which would cause the next test's Process.register/2 to raise :already_registered.
      try do
        Process.unregister(:finite_stub_agent)
      catch
        _, _ -> :ok
      end
    end)

    :ok
  end

  test "nacks message and stops draining when publish fails" do
    Application.put_env(:ad_butler, :amqp_basic, AMQPBasicStub)
    result = ReplayDlq.drain_dlq(:fake_channel, 10, 0)

    assert_received {:nacked, :tag1}
    assert result == 0
  end

  test "acks and discards message with invalid JSON payload, then stops when queue empty" do
    agent = start_supervised!({Agent, fn -> [:bad_json, :empty] end})
    Process.register(agent, :finite_stub_agent)
    Application.put_env(:ad_butler, :amqp_basic, AMQPBasicFiniteStub)

    result = ReplayDlq.drain_dlq(:fake_channel, 10, 0)

    assert_received {:acked, :bad_tag}
    assert result == 0
  end

  test "acks and discards message with invalid UUID, then stops when queue empty" do
    agent = start_supervised!({Agent, fn -> [:bad_uuid, :empty] end})
    Process.register(agent, :finite_stub_agent)
    Application.put_env(:ad_butler, :amqp_basic, AMQPBasicFiniteStub)

    result = ReplayDlq.drain_dlq(:fake_channel, 10, 0)

    assert_received {:acked, :uuid_tag}
    assert result == 0
  end

  test "stops at limit without consuming more messages" do
    assert ReplayDlq.drain_dlq(:fake_channel, 0, 0) == 0
  end
end

defmodule Mix.Tasks.AdButler.ReplayDlqTest do
  use ExUnit.Case, async: false

  alias AdButler.Messaging.RabbitMQTopology
  alias Mix.Tasks.AdButler.ReplayDlq

  @moduletag :integration

  # Requires a running RabbitMQ broker:
  #   docker run -d -p 5672:5672 rabbitmq:3.13-alpine

  @dlq "ad_butler.sync.metadata.dlq"
  @main_queue "ad_butler.sync.metadata"
  @dlq_exchange "ad_butler.sync.dlq.fanout"

  setup do
    :ok = RabbitMQTopology.setup()
    url = Application.fetch_env!(:ad_butler, :rabbitmq)[:url]
    {:ok, conn} = AMQP.Connection.open(url)
    {:ok, channel} = AMQP.Channel.open(conn)

    # Purge both queues for a clean test
    AMQP.Queue.purge(channel, @dlq)
    AMQP.Queue.purge(channel, @main_queue)

    on_exit(fn -> AMQP.Connection.close(conn) end)
    {:ok, channel: channel}
  end

  test "moves messages from DLQ to main queue", %{channel: channel} do
    valid_payload = Jason.encode!(%{ad_account_id: Ecto.UUID.generate()})

    Enum.each(1..3, fn _ ->
      AMQP.Basic.publish(channel, @dlq_exchange, "", valid_payload, persistent: true)
    end)

    # Poll until all 3 messages are visible in the DLQ (avoids flaky timing in CI)
    wait_for_queue_depth(channel, @dlq, 3)

    ReplayDlq.run(["--limit", "10"])

    {:ok, %{message_count: dlq_count}} = AMQP.Queue.declare(channel, @dlq, passive: true)
    {:ok, %{message_count: main_count}} = AMQP.Queue.declare(channel, @main_queue, passive: true)

    assert dlq_count == 0
    assert main_count == 3
  end

  test "handles empty DLQ gracefully", %{channel: _channel} do
    assert :ok = ReplayDlq.run(["--limit", "10"])
  end

  test "discards messages with invalid ad_account_id UUID", %{channel: channel} do
    bad_payload = Jason.encode!(%{ad_account_id: "not-a-uuid"})
    AMQP.Basic.publish(channel, @dlq_exchange, "", bad_payload, persistent: true)

    wait_for_queue_depth(channel, @dlq, 1)

    ReplayDlq.run(["--limit", "10"])

    {:ok, %{message_count: dlq_count}} = AMQP.Queue.declare(channel, @dlq, passive: true)
    {:ok, %{message_count: main_count}} = AMQP.Queue.declare(channel, @main_queue, passive: true)

    assert dlq_count == 0
    assert main_count == 0
  end

  # Polls until the queue reaches the expected depth or deadline passes (500ms).
  # Uses receive/after rather than Process.sleep so the calling process remains
  # schedulable and honours any pending messages during the poll interval.
  defp wait_for_queue_depth(channel, queue, expected, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 500

    {:ok, %{message_count: count}} = AMQP.Queue.declare(channel, queue, passive: true)

    if count >= expected or System.monotonic_time(:millisecond) >= deadline do
      :ok
    else
      receive do
      after
        20 -> wait_for_queue_depth(channel, queue, expected, deadline)
      end
    end
  end
end
