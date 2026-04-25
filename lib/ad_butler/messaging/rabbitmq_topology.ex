defmodule AdButler.Messaging.RabbitMQTopology do
  @moduledoc """
  Declares the RabbitMQ exchange and queue topology required by the sync pipeline.

  Sets up a fanout exchange (`ad_butler.sync.fanout`) with a durable main queue
  and a dead-letter queue (`ad_butler.sync.metadata.dlq`) bound to its own fanout
  exchange. Called once at application startup via `AdButler.Application` with
  automatic retry on transient connection failures.
  """
  require Logger

  @exchange "ad_butler.sync.fanout"
  @dlq_exchange "ad_butler.sync.dlq.fanout"
  @queue "ad_butler.sync.metadata"
  @dlq "ad_butler.sync.metadata.dlq"
  @dlq_ttl_ms 300_000

  @doc "Declares the full exchange and queue topology. Opens and closes its own connection; safe to call multiple times."
  @spec setup() :: :ok | {:error, term()}
  def setup do
    case AMQP.Connection.open(rabbitmq_url()) do
      {:ok, conn} ->
        case AMQP.Channel.open(conn) do
          {:ok, channel} ->
            result = declare_topology(channel)
            AMQP.Channel.close(channel)
            AMQP.Connection.close(conn)
            result

          {:error, _} = err ->
            AMQP.Connection.close(conn)
            err
        end

      {:error, _} = err ->
        err
    end
  end

  defp declare_topology(channel) do
    with :ok <- AMQP.Exchange.declare(channel, @dlq_exchange, :fanout, durable: true),
         {:ok, _} <-
           AMQP.Queue.declare(channel, @dlq,
             durable: true,
             arguments: [{"x-message-ttl", :long, @dlq_ttl_ms}]
           ),
         :ok <- AMQP.Queue.bind(channel, @dlq, @dlq_exchange),
         :ok <- AMQP.Exchange.declare(channel, @exchange, :fanout, durable: true),
         {:ok, _} <-
           AMQP.Queue.declare(channel, @queue,
             durable: true,
             arguments: [{"x-dead-letter-exchange", :longstr, @dlq_exchange}]
           ),
         :ok <- AMQP.Queue.bind(channel, @queue, @exchange) do
      Logger.info("RabbitMQ topology ready",
        exchange: @exchange,
        queue: @queue,
        dlq: @dlq
      )

      :ok
    end
  end

  defp rabbitmq_url do
    Application.fetch_env!(:ad_butler, :rabbitmq)[:url]
  end
end
