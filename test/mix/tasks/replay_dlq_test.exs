defmodule Mix.Tasks.AdButler.ReplayDlqUnitTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.AdButler.ReplayDlq

  defmodule AMQPBasicStub do
    @behaviour AdButler.AMQPBasicBehaviour

    def get(_ch, _queue, _opts), do: {:ok, "payload", %{delivery_tag: :tag1}}

    def publish(_ch, _exchange, _routing_key, _payload, _opts),
      do: {:error, :channel_closed}

    def nack(_ch, tag, _opts) do
      send(:drain_dlq_test, {:nacked, tag})
      :ok
    end

    def ack(_ch, _tag), do: :ok
  end

  setup do
    Process.register(self(), :drain_dlq_test)
    Application.put_env(:ad_butler, :amqp_basic, AMQPBasicStub)
    on_exit(fn -> Application.delete_env(:ad_butler, :amqp_basic) end)
    :ok
  end

  test "nacks message and stops draining when publish fails" do
    result = ReplayDlq.drain_dlq(:fake_channel, 10, 0)

    assert_received {:nacked, :tag1}
    assert result == 0
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
    Enum.each(1..3, fn i ->
      AMQP.Basic.publish(channel, @dlq_exchange, "", Jason.encode!(%{test: i}), persistent: true)
    end)

    ReplayDlq.run(["--limit", "10"])

    {:ok, %{message_count: dlq_count}} = AMQP.Queue.declare(channel, @dlq, passive: true)
    {:ok, %{message_count: main_count}} = AMQP.Queue.declare(channel, @main_queue, passive: true)

    assert dlq_count == 0
    assert main_count == 3
  end

  test "handles empty DLQ gracefully", %{channel: _channel} do
    assert :ok = ReplayDlq.run(["--limit", "10"])
  end
end
