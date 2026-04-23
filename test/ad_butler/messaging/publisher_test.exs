defmodule AdButler.Messaging.PublisherTest do
  use ExUnit.Case, async: false

  alias AdButler.Messaging.Publisher
  alias AdButler.Messaging.RabbitMQTopology

  @moduletag :integration

  # Requires a running RabbitMQ broker:
  #   docker run -d -p 5672:5672 rabbitmq:3.13-alpine

  @queue "ad_butler.sync.metadata"

  setup do
    :ok = RabbitMQTopology.setup()
    {:ok, pid} = start_supervised(Publisher)
    :ok = Publisher.await_connected()

    url = Application.fetch_env!(:ad_butler, :rabbitmq)[:url]
    {:ok, conn} = AMQP.Connection.open(url)
    {:ok, channel} = AMQP.Channel.open(conn)
    AMQP.Queue.purge(channel, @queue)

    on_exit(fn -> AMQP.Connection.close(conn) end)

    {:ok, publisher: pid, channel: channel}
  end

  test "publish/1 delivers message to queue", %{channel: channel} do
    payload = Jason.encode!(%{ad_account_id: "act_123", sync_type: "full"})
    assert :ok = Publisher.publish(payload)

    {:ok, message, _meta} = AMQP.Basic.get(channel, @queue, no_ack: true)
    assert message == payload
  end
end
