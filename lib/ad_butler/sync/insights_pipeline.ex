defmodule AdButler.Sync.InsightsPipeline do
  @moduledoc """
  Broadway pipeline that consumes insights-sync messages from RabbitMQ and fetches
  ad-level insights from the Meta API, writing results to `insights_daily`.

  Each message carries `{ad_account_id, sync_type}`. The processor resolves the
  `AdAccount` record; the batcher groups messages by `meta_connection_id` (one Meta
  API call per connection). `sync_type` controls the lookback window: `"delivery"`
  fetches the last 2 days; `"conversions"` fetches the last 7 days.

  Two RabbitMQ queues feed this pipeline (one instance per queue in production):
  - `ad_butler.insights.delivery`   — 30-min scheduler cycle
  - `ad_butler.insights.conversions` — 2-hour scheduler cycle

  In test env a `Broadway.DummyProducer` is used, controlled by the
  `:broadway_producer` application env.
  """
  use Broadway

  require Logger

  alias AdButler.{Accounts, Ads, ErrorHelpers}
  alias AdButler.Ads.AdAccount
  alias Broadway.Message

  @delivery_queue "ad_butler.insights.delivery"

  @doc "Starts the Broadway pipeline. Pass `queue: queue_name` to choose which RabbitMQ queue to consume."
  def start_link(opts \\ []) do
    queue = Keyword.get(opts, :queue, @delivery_queue)
    producer = producer_config(queue)
    name = queue_to_name(queue)

    Broadway.start_link(__MODULE__,
      name: name,
      producer: [module: producer],
      processors: [
        default: [concurrency: 5, partition_by: &partition_by_ad_account/1]
      ],
      batchers: [
        default: [concurrency: 5, batch_size: 25, batch_timeout: 2_000]
      ]
    )
  end

  @impl Broadway
  def handle_message(_processor, %Message{data: data} = message, _context) do
    with {:ok, %{"ad_account_id" => raw_id, "sync_type" => sync_type}} <- Jason.decode(data),
         true <- sync_type in ["delivery", "conversions"],
         {:ok, ad_account_id} <- Ecto.UUID.cast(raw_id),
         %AdAccount{} = ad_account <- Ads.unsafe_get_ad_account_for_sync(ad_account_id) do
      message
      |> Message.put_data({ad_account, sync_type})
      |> Message.put_batcher(:default)
    else
      {:ok, _} -> Message.failed(message, :invalid_payload)
      false -> Message.failed(message, :invalid_sync_type)
      {:error, _} -> Message.failed(message, :invalid_payload)
      :error -> Message.failed(message, :invalid_payload)
      nil -> Message.failed(message, :not_found)
    end
  end

  @impl Broadway
  def handle_failed(messages, _context) do
    Enum.map(messages, &maybe_requeue_once/1)
  end

  @impl Broadway
  def handle_batch(_batcher, messages, _batch_info, _context) do
    client = meta_client()

    connection_ids =
      messages
      |> Enum.map(fn %Message{data: {ad_account, _}} -> ad_account.meta_connection_id end)
      |> Enum.uniq()

    connections = Accounts.get_meta_connections_by_ids(connection_ids)

    messages
    |> Enum.group_by(fn %Message{data: {ad_account, _}} -> ad_account.meta_connection_id end)
    |> Enum.flat_map(fn {conn_id, msgs} ->
      process_batch_group(msgs, connections, conn_id, client)
    end)
  end

  defp process_batch_group(msgs, connections, conn_id, client) do
    case Map.get(connections, conn_id) do
      nil -> Enum.map(msgs, &Message.failed(&1, :connection_not_found))
      connection -> Enum.map(msgs, &sync_insights_message(&1, connection, client))
    end
  end

  defp sync_insights_message(%Message{data: {ad_account, sync_type}} = msg, connection, client) do
    usage = client.get_rate_limit_usage(ad_account.meta_id)

    if usage > 0.85 do
      Logger.warning("insights skipped: rate limit",
        ad_account_id: ad_account.id,
        usage: usage
      )

      msg
    else
      case fetch_and_upsert(ad_account, connection, sync_type, client) do
        :ok -> msg
        {:error, reason} -> Message.failed(msg, reason)
      end
    end
  end

  defp fetch_and_upsert(ad_account, connection, sync_type, client) do
    opts = insights_opts(sync_type)
    meta_id_map = Ads.unsafe_get_ad_meta_id_map(ad_account.id)

    case client.get_insights(ad_account.meta_id, connection.access_token, opts) do
      {:ok, rows} ->
        normalised = filter_valid_rows(rows, meta_id_map)

        case Ads.bulk_upsert_insights(normalised) do
          {:ok, count} ->
            Logger.info("insights upserted",
              ad_account_id: ad_account.id,
              sync_type: sync_type,
              count: count
            )

            :ok

          {:error, reason} ->
            Logger.error("insights upsert failed",
              ad_account_id: ad_account.id,
              sync_type: sync_type,
              reason: reason
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("insights fetch failed",
          ad_account_id: ad_account.id,
          sync_type: sync_type,
          reason: ErrorHelpers.safe_reason(reason)
        )

        {:error, reason}
    end
  end

  defp filter_valid_rows(rows, meta_id_map) do
    Enum.flat_map(rows, fn row ->
      with {:ok, local_id} <- Map.fetch(meta_id_map, row.ad_id),
           normalised when not is_nil(normalised.date_start) <- normalise_row(row, local_id) do
        [normalised]
      else
        _ -> []
      end
    end)
  end

  defp normalise_row(row, local_id) do
    date =
      case row.date_start do
        s when is_binary(s) ->
          case Date.from_iso8601(s) do
            {:ok, d} ->
              d

            {:error, _} ->
              Logger.warning("insights: invalid date_start, skipping", date_start: s)
              nil
          end

        d ->
          d
      end

    row |> Map.put(:ad_id, local_id) |> Map.put(:date_start, date)
  end

  defp insights_opts("delivery") do
    today = Date.utc_today()
    [time_range: %{since: Date.add(today, -2), until: today}]
  end

  defp insights_opts("conversions") do
    today = Date.utc_today()
    [time_range: %{since: Date.add(today, -7), until: today}]
  end

  defp partition_by_ad_account(%Message{data: data}) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{"ad_account_id" => id}} -> :erlang.phash2(id)
      _ -> 0
    end
  end

  defp partition_by_ad_account(%Message{data: {%AdAccount{id: id}, _}}), do: :erlang.phash2(id)

  # Reasons that should get one in-broker retry before being dead-lettered.
  # Anything not matched here falls through to the producer's :reject default → straight to DLQ.
  @doc false
  def retryable?(:rate_limit_exceeded), do: true
  def retryable?(:meta_server_error), do: true
  def retryable?(:timeout), do: true
  def retryable?(_), do: false

  defp maybe_requeue_once(%Message{status: {:failed, reason}} = msg) do
    if retryable?(reason) do
      Message.configure_ack(msg, on_failure: :reject_and_requeue_once)
    else
      msg
    end
  end

  defp maybe_requeue_once(msg), do: msg

  defp meta_client do
    Application.get_env(:ad_butler, :meta_client, AdButler.Meta.Client)
  end

  defp queue_to_name("ad_butler.insights.delivery"), do: __MODULE__.Delivery
  defp queue_to_name("ad_butler.insights.conversions"), do: __MODULE__.Conversions
  defp queue_to_name(_), do: __MODULE__

  defp producer_config(queue) do
    case Application.get_env(:ad_butler, :broadway_producer) do
      :test ->
        {Broadway.DummyProducer, []}

      _ ->
        {BroadwayRabbitMQ.Producer,
         queue: queue,
         qos: [prefetch_count: 150],
         on_failure: :reject,
         connection: Application.fetch_env!(:ad_butler, :rabbitmq)[:url]}
    end
  end
end
