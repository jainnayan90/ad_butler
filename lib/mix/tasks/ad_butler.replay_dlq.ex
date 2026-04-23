defmodule Mix.Tasks.AdButler.ReplayDlq do
  @moduledoc false
  use Mix.Task

  require Logger

  @shortdoc "Replay messages from DLQ back to main queue"

  @dlq "ad_butler.sync.metadata.dlq"
  @exchange "ad_butler.sync.fanout"
  @default_limit 100

  @spec run(list()) :: :ok | {:error, term()}
  def run(args) do
    Mix.Task.run("app.start")
    limit = parse_limit(args)

    with {:ok, conn} <- AMQP.Connection.open(rabbitmq_url()),
         {:ok, channel} <- AMQP.Channel.open(conn) do
      replayed = drain_dlq(channel, limit, 0)

      Logger.info("DLQ replay complete", replayed: replayed)
      Mix.shell().info("Replayed #{replayed} message(s) from DLQ to main queue.")

      AMQP.Channel.close(channel)
      AMQP.Connection.close(conn)
      :ok
    else
      {:error, reason} ->
        Mix.shell().error("Failed to connect to RabbitMQ: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc false
  def drain_dlq(_channel, limit, count) when count >= limit, do: count

  @doc false
  def drain_dlq(channel, limit, count) do
    case amqp_basic().get(channel, @dlq, no_ack: false) do
      {:ok, payload, %{delivery_tag: tag}} ->
        case amqp_basic().publish(channel, @exchange, "", payload, persistent: true) do
          :ok ->
            amqp_basic().ack(channel, tag)
            drain_dlq(channel, limit, count + 1)

          {:error, reason} ->
            Logger.warning("DLQ replay: publish failed, stopping drain",
              reason: inspect(reason),
              replayed_so_far: count
            )

            amqp_basic().nack(channel, tag, requeue: true)
            count
        end

      {:empty, _} ->
        count
    end
  end

  defp amqp_basic, do: Application.get_env(:ad_butler, :amqp_basic, AMQP.Basic)

  defp parse_limit(args) do
    case OptionParser.parse(args, strict: [limit: :integer]) do
      {opts, _, _} -> Keyword.get(opts, :limit, @default_limit)
    end
  end

  defp rabbitmq_url do
    Application.fetch_env!(:ad_butler, :rabbitmq)[:url]
  end
end
