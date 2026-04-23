defmodule Mix.Tasks.AdButler.ReplayDlq do
  @moduledoc """
  Mix task that replays messages from the dead-letter queue back to the main
  sync fanout exchange.

  Usage:

      mix ad_butler.replay_dlq [--limit N] [--confirm] [--dry-run]

  Options:
  - `--limit N` — replay at most N messages (default: 100)
  - `--confirm` — prompt for confirmation before connecting (recommended in production)
  - `--dry-run` — print how many messages would be replayed without moving any

  Each message payload is validated for a well-formed `ad_account_id` UUID before
  republishing. Invalid messages are ACKed and discarded with a warning.

  On publish failure the message is NACKed (requeued) and draining stops.
  """
  use Mix.Task

  require Logger

  @shortdoc "Replay messages from DLQ back to main queue"

  @dlq "ad_butler.sync.metadata.dlq"
  @exchange "ad_butler.sync.fanout"
  @default_limit 100

  @doc """
  Entry point for `mix ad_butler.replay_dlq`.

  Parses `--limit`, `--confirm`, and `--dry-run` flags, then connects to RabbitMQ
  and either reports the DLQ depth (dry-run) or drains up to `limit` messages back
  to the main exchange.
  """
  @spec run(list()) :: :ok | {:error, term()}
  def run(args) do
    Mix.Task.run("app.start")
    {limit, dry_run?, confirm?} = parse_args(args)

    if confirm? and
         not Mix.shell().yes?("About to replay up to #{limit} message(s) from DLQ. Proceed?") do
      Mix.shell().info("Aborted.")
      :ok
    else
      connect_and_run(limit, dry_run?)
    end
  end

  @doc """
  Drains up to `limit` messages from the DLQ, republishing each to the main exchange.

  Returns the count of messages successfully replayed. Stops early on publish failure
  (NACKing the current message) or when the queue is empty. Payloads with an invalid
  `ad_account_id` UUID are ACKed and discarded rather than republished.
  """
  @spec drain_dlq(term(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def drain_dlq(_channel, limit, count) when count >= limit, do: count

  def drain_dlq(channel, limit, count) do
    case amqp_basic().get(channel, @dlq, no_ack: false) do
      {:ok, payload, %{delivery_tag: tag}} -> handle_message(channel, limit, count, payload, tag)
      {:empty, _} -> count
    end
  end

  defp handle_message(channel, limit, count, payload, tag) do
    if valid_payload?(payload) do
      publish_message(channel, limit, count, payload, tag)
    else
      Logger.warning("DLQ replay: invalid payload discarded (tag=#{inspect(tag)})")
      amqp_basic().ack(channel, tag)
      drain_dlq(channel, limit, count)
    end
  end

  defp publish_message(channel, limit, count, payload, tag) do
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
  end

  defp connect_and_run(limit, dry_run?) do
    case AMQP.Connection.open(rabbitmq_url()) do
      {:ok, conn} ->
        result =
          case AMQP.Channel.open(conn) do
            {:ok, channel} ->
              run_on_channel(channel, limit, dry_run?)

            {:error, reason} ->
              Mix.shell().error("Failed to open AMQP channel: #{inspect(reason)}")
              {:error, reason}
          end

        AMQP.Connection.close(conn)
        result

      {:error, reason} ->
        Mix.shell().error("Failed to connect to RabbitMQ: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp run_on_channel(channel, limit, dry_run?) do
    result =
      if dry_run? do
        run_dry_run(channel, limit)
      else
        replayed = drain_dlq(channel, limit, 0)
        Logger.info("DLQ replay complete", replayed: replayed)
        Mix.shell().info("Replayed #{replayed} message(s) from DLQ to main queue.")
        :ok
      end

    AMQP.Channel.close(channel)
    result
  end

  defp run_dry_run(channel, limit) do
    case AMQP.Queue.declare(channel, @dlq, passive: true) do
      {:ok, %{message_count: count}} ->
        would_replay = min(count, limit)

        Mix.shell().info(
          "Dry run: #{would_replay} of #{count} message(s) in DLQ would be replayed (limit: #{limit})."
        )

        :ok

      {:error, reason} ->
        Mix.shell().error("Failed to inspect DLQ: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp valid_payload?(payload) do
    case Jason.decode(payload) do
      {:ok, %{"ad_account_id" => id}} -> match?({:ok, _}, Ecto.UUID.cast(id))
      _ -> false
    end
  end

  defp amqp_basic, do: Application.get_env(:ad_butler, :amqp_basic, AMQP.Basic)

  defp parse_args(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [limit: :integer, dry_run: :boolean, confirm: :boolean]
      )

    limit = Keyword.get(opts, :limit, @default_limit)
    dry_run? = Keyword.get(opts, :dry_run, false)
    confirm? = Keyword.get(opts, :confirm, false)
    {limit, dry_run?, confirm?}
  end

  defp rabbitmq_url do
    Application.fetch_env!(:ad_butler, :rabbitmq)[:url]
  end
end
