defmodule AdButler.Messaging.RabbitMQTopology do
  @moduledoc """
  Declares the RabbitMQ exchange and queue topology required by the sync and insights pipelines.

  Sets up:
  - Sync fanout exchange (`ad_butler.sync.fanout`) with the metadata queue and its DLQ.
  - Insights fanout exchange (`ad_butler.insights.fanout`) with delivery and conversions queues,
    each with its own DLQ bound to `ad_butler.insights.dlq.fanout`.

  Called once at application startup via `AdButler.Application` with automatic retry on
  transient connection failures.
  """
  require Logger

  @exchange "ad_butler.sync.fanout"
  @dlq_exchange "ad_butler.sync.dlq.fanout"
  @queue "ad_butler.sync.metadata"
  @dlq "ad_butler.sync.metadata.dlq"
  @dlq_ttl_ms 300_000

  @insights_exchange "ad_butler.insights.fanout"
  @insights_dlq_exchange "ad_butler.insights.dlq.fanout"
  @insights_delivery_queue "ad_butler.insights.delivery"
  @insights_delivery_dlq "ad_butler.insights.delivery.dlq"
  @insights_conversions_queue "ad_butler.insights.conversions"
  @insights_conversions_dlq "ad_butler.insights.conversions.dlq"

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
         :ok <- AMQP.Queue.bind(channel, @queue, @exchange),
         :ok <- declare_insights_topology(channel) do
      Logger.info("RabbitMQ topology ready",
        exchange: @exchange,
        queue: @queue,
        dlq: @dlq
      )

      :ok
    end
  end

  defp declare_insights_topology(channel) do
    with :ok <- AMQP.Exchange.declare(channel, @insights_dlq_exchange, :fanout, durable: true),
         {:ok, _} <-
           AMQP.Queue.declare(channel, @insights_delivery_dlq,
             durable: true,
             arguments: [{"x-message-ttl", :long, @dlq_ttl_ms}]
           ),
         {:ok, _} <-
           AMQP.Queue.declare(channel, @insights_conversions_dlq,
             durable: true,
             arguments: [{"x-message-ttl", :long, @dlq_ttl_ms}]
           ),
         :ok <- AMQP.Queue.bind(channel, @insights_delivery_dlq, @insights_dlq_exchange),
         :ok <- AMQP.Queue.bind(channel, @insights_conversions_dlq, @insights_dlq_exchange),
         :ok <- AMQP.Exchange.declare(channel, @insights_exchange, :fanout, durable: true),
         {:ok, _} <-
           AMQP.Queue.declare(channel, @insights_delivery_queue,
             durable: true,
             arguments: [{"x-dead-letter-exchange", :longstr, @insights_dlq_exchange}]
           ),
         {:ok, _} <-
           AMQP.Queue.declare(channel, @insights_conversions_queue,
             durable: true,
             arguments: [{"x-dead-letter-exchange", :longstr, @insights_dlq_exchange}]
           ),
         :ok <- AMQP.Queue.bind(channel, @insights_delivery_queue, @insights_exchange),
         :ok <- AMQP.Queue.bind(channel, @insights_conversions_queue, @insights_exchange) do
      Logger.info("RabbitMQ insights topology ready",
        exchange: @insights_exchange,
        delivery_queue: @insights_delivery_queue,
        conversions_queue: @insights_conversions_queue
      )

      :ok
    end
  end

  defp rabbitmq_url do
    Application.fetch_env!(:ad_butler, :rabbitmq)[:url]
  end
end
