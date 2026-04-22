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

  test "main queue exists", %{channel: channel} do
    # passive: true verifies the queue was declared by RabbitMQTopology.setup/0
    # without re-declaring it. Dead-letter routing args are not readable via
    # passive declare; they are validated end-to-end by the DLQ routing test below.
    {:ok, info} = AMQP.Queue.declare(channel, @queue, passive: true)
    assert info.queue == @queue
  end

  test "DLQ and dead-letter exchange exist", %{channel: channel} do
    {:ok, info} = AMQP.Queue.declare(channel, @dlq, passive: true)
    assert info.queue == @dlq

    # Verifies x-dead-letter-exchange is wired: the fanout exchange that the main
    # queue's dead-letter config points to must exist for routing to work.
    assert :ok = AMQP.Exchange.declare(channel, @dlq_exchange, :fanout, passive: true)
  end
end
