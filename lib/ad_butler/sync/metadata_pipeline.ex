defmodule AdButler.Sync.MetadataPipeline do
  @moduledoc false
  use Broadway

  require Logger

  alias AdButler.{Accounts, Ads, ErrorHelpers}
  alias AdButler.Ads.AdAccount
  alias Broadway.Message

  @queue "ad_butler.sync.metadata"

  def start_link(_opts \\ []) do
    producer = producer_config()

    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: [module: producer],
      processors: [
        default: [concurrency: 5, partition_by: &partition_by_ad_account/1]
      ],
      batchers: [
        default: [concurrency: 2, batch_size: 10, batch_timeout: 2_000]
      ]
    )
  end

  @impl Broadway
  def handle_message(_processor, %Message{data: data} = message, _context) do
    with {:ok, %{"ad_account_id" => raw_id}} <- Jason.decode(data),
         {:ok, ad_account_id} <- Ecto.UUID.cast(raw_id),
         %AdAccount{} = ad_account <- Ads.unsafe_get_ad_account_for_sync(ad_account_id) do
      message
      |> Message.put_data(ad_account)
      |> Message.put_batcher(:default)
    else
      # JSON decoded but missing "ad_account_id" key
      {:ok, _} -> Message.failed(message, :invalid_payload)
      {:error, _} -> Message.failed(message, :invalid_payload)
      :error -> Message.failed(message, :invalid_payload)
      nil -> Message.failed(message, :not_found)
    end
  end

  @impl Broadway
  def handle_batch(_batcher, messages, _batch_info, _context) do
    messages
    |> Enum.group_by(fn %Message{data: ad_account} -> ad_account.meta_connection_id end)
    |> Enum.flat_map(fn {_conn_id, msgs} -> process_batch_group(msgs) end)
  end

  defp process_batch_group([%Message{data: first_account} | _] = msgs) do
    connection = Accounts.get_meta_connection!(first_account.meta_connection_id)

    Enum.map(msgs, fn %Message{data: ad_account} = msg ->
      case sync_ad_account(ad_account, connection) do
        :ok -> msg
        {:error, reason} -> Message.failed(msg, reason)
      end
    end)
  end

  defp sync_ad_account(ad_account, connection) do
    client = meta_client()

    with {:ok, campaigns} <-
           client.list_campaigns(ad_account.meta_id, connection.access_token,
             fields: "id,name,status,objective,daily_budget,lifetime_budget"
           ),
         {:ok, ad_sets} <-
           client.list_ad_sets(ad_account.meta_id, connection.access_token,
             fields:
               "id,name,status,campaign_id,daily_budget,lifetime_budget,bid_amount,targeting"
           ),
         {:ok, ads} <-
           client.list_ads(ad_account.meta_id, connection.access_token,
             fields: "id,name,status,adset_id"
           ) do
      campaign_id_map = upsert_campaigns(ad_account, campaigns)
      ad_set_id_map = upsert_ad_sets(ad_account, ad_sets, campaign_id_map)
      attrs_list = Enum.map(ads, &build_ad_attrs(&1, ad_set_id_map))

      {valid_ads, orphaned_ads} = Enum.split_with(attrs_list, &(not is_nil(&1.ad_set_id)))

      if orphaned_ads != [] do
        Logger.warning("Orphaned ads dropped during sync",
          count: length(orphaned_ads),
          ad_account_id: ad_account.id
        )
      end

      {upserted_count, _} = Ads.bulk_upsert_ads(ad_account, valid_ads)

      Logger.info("Metadata sync complete",
        ad_account_id: ad_account.id,
        campaigns: length(campaigns),
        ad_sets: length(ad_sets),
        ads: upserted_count
      )

      :ok
    else
      {:error, :rate_limit_exceeded} ->
        Logger.warning("Rate limit hit during metadata sync", ad_account_id: ad_account.id)
        {:error, :rate_limit_exceeded}

      {:error, reason} ->
        Logger.error("Metadata sync failed",
          ad_account_id: ad_account.id,
          reason: ErrorHelpers.safe_reason(reason)
        )

        {:error, reason}
    end
  end

  defp upsert_campaigns(ad_account, campaigns) do
    attrs_list = Enum.map(campaigns, &build_campaign_attrs/1)
    {_count, rows} = Ads.bulk_upsert_campaigns(ad_account, attrs_list)
    Map.new(rows, fn row -> {row.meta_id, row.id} end)
  end

  defp upsert_ad_sets(ad_account, ad_sets, campaign_id_map) do
    attrs_list = Enum.map(ad_sets, &build_ad_set_attrs(&1, campaign_id_map))

    {valid, orphaned} = Enum.split_with(attrs_list, &(&1.campaign_id != nil))

    if orphaned != [] do
      meta_ids = Enum.map(orphaned, & &1.meta_id)

      Logger.warning("Dropping ad sets with no matching campaign",
        ad_account_id: ad_account.id,
        meta_ids: meta_ids
      )
    end

    {_count, rows} = Ads.bulk_upsert_ad_sets(ad_account, valid)
    Map.new(rows, fn row -> {row.meta_id, row.id} end)
  end

  defp build_campaign_attrs(c) do
    %{
      meta_id: c["id"],
      name: c["name"],
      status: c["status"],
      objective: c["objective"],
      daily_budget_cents: parse_budget(c["daily_budget"]),
      lifetime_budget_cents: parse_budget(c["lifetime_budget"]),
      raw_jsonb: c
    }
  end

  defp build_ad_set_attrs(s, campaign_id_map) do
    %{
      meta_id: s["id"],
      name: s["name"],
      status: s["status"],
      campaign_id: Map.get(campaign_id_map, s["campaign_id"]),
      daily_budget_cents: parse_budget(s["daily_budget"]),
      lifetime_budget_cents: parse_budget(s["lifetime_budget"]),
      bid_amount_cents: parse_budget(s["bid_amount"]),
      targeting_jsonb: s["targeting"] || %{},
      raw_jsonb: s
    }
  end

  defp build_ad_attrs(a, ad_set_id_map) do
    %{
      meta_id: a["id"],
      name: a["name"],
      status: a["status"],
      ad_set_id: Map.get(ad_set_id_map, a["adset_id"]),
      raw_jsonb: a
    }
  end

  defp parse_budget(nil), do: nil
  defp parse_budget(v) when is_integer(v), do: v

  defp parse_budget(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp partition_by_ad_account(%Message{data: data}) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{"ad_account_id" => id}} -> :erlang.phash2(id)
      _ -> 0
    end
  end

  defp partition_by_ad_account(%Message{data: %AdAccount{id: id}}), do: :erlang.phash2(id)

  defp meta_client do
    Application.get_env(:ad_butler, :meta_client, AdButler.Meta.Client)
  end

  defp producer_config do
    case Application.get_env(:ad_butler, :broadway_producer) do
      :test ->
        {Broadway.DummyProducer, []}

      _ ->
        {BroadwayRabbitMQ.Producer,
         queue: @queue,
         qos: [prefetch_count: 10],
         connection: Application.fetch_env!(:ad_butler, :rabbitmq)[:url]}
    end
  end
end
