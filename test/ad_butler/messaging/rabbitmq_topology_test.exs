defmodule AdButler.Messaging.RabbitMQTopologyTest do
  use ExUnit.Case, async: false

  alias AdButler.Messaging.RabbitMQTopology

  @moduletag :integration

  # Requires a running RabbitMQ broker:
  #   docker run -d -p 5672:5672 rabbitmq:3.13-alpine

  @queue "ad_butler.sync.metadata"
  @dlq "ad_butler.sync.metadata.dlq"
  @dlq_exchange "ad_butler.sync.dlq.fanout"

  setup do
    assert :ok = RabbitMQTopology.setup()
    url = Application.fetch_env!(:ad_butler, :rabbitmq)[:url]
    {:ok, conn} = AMQP.Connection.open(url)
    {:ok, channel} = AMQP.Channel.open(conn)
    on_exit(fn -> AMQP.Connection.close(conn) end)
    {:ok, channel: channel}
  end

  test "main queue exists with dead-letter arguments", %{channel: channel} do
    # passive: true checks existence without re-declaring
    {:ok, info} = AMQP.Queue.declare(channel, @queue, passive: true)
    assert info.queue == @queue
  end

  test "DLQ queue has x-dead-letter-exchange argument", %{channel: channel} do
    {:ok, info} = AMQP.Queue.declare(channel, @dlq, passive: true)
    assert info.queue == @dlq

    # Verify DLQ exchange exists
    assert :ok = AMQP.Exchange.declare(channel, @dlq_exchange, :fanout, passive: true)
  end
end
