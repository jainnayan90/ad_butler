defmodule AdButler.Workers.FetchAdAccountsWorker do
  @moduledoc """
  Oban worker that fetches all Meta ad accounts for a single `MetaConnection` and
  publishes a sync message to RabbitMQ for each account.

  On success each account is upserted and a `{"ad_account_id": ..., "sync_type":
  "full"}` message is published to the fanout exchange so `MetadataPipeline` can
  pick it up. On rate-limit the job snoozes 15 minutes; on auth failure the
  connection is revoked and the job cancelled.
  """
  use Oban.Worker,
    queue: :sync,
    max_attempts: 5,
    unique: [
      period: 300,
      keys: [:meta_connection_id],
      states: [:scheduled, :available, :executing, :retryable]
    ]

  require Logger

  alias AdButler.{Accounts, Ads, ErrorHelpers}
  alias AdButler.Accounts.MetaConnection
  alias AdButler.Meta.Client, as: MetaClient

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) ::
          :ok | {:snooze, Oban.Period.t()} | {:cancel, binary()} | {:error, term()}
  def perform(%Oban.Job{args: %{"meta_connection_id" => id}}) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %MetaConnection{} = conn <- Accounts.get_meta_connection(uuid) do
      run_sync(conn)
    else
      :error -> {:cancel, "invalid_meta_connection_id"}
      nil -> {:cancel, "meta_connection_not_found"}
    end
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  defp run_sync(connection) do
    case meta_client().list_ad_accounts(connection.access_token) do
      {:ok, accounts} ->
        results = Enum.map(accounts, &sync_account(connection, &1))

        Logger.info("Ad accounts fetched and synced",
          meta_connection_id: connection.id,
          count: length(accounts)
        )

        # At-least-once delivery: RabbitMQ may redeliver on restart; MetadataPipeline
        # handles duplicates via idempotent upserts (conflict target: ad_account_id + meta_id).
        case Enum.find(results, &match?({:error, _}, &1)) do
          nil -> :ok
          # Snooze rather than retry — retrying would re-call Meta's API and burn
          # rate-limit quota just because AMQP is temporarily disconnected.
          {:error, :not_connected} -> {:snooze, 60}
          error -> error
        end

      {:error, :rate_limit_exceeded} ->
        {:snooze, {15, :minutes}}

      {:error, :unauthorized} ->
        revoke_connection(connection)
        {:cancel, "unauthorized"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revoke_connection(connection) do
    case Accounts.update_meta_connection(connection, %{status: "revoked"}) do
      {:ok, _} ->
        :ok

      {:error, %Ecto.Changeset{} = cs} ->
        Logger.warning("Failed to revoke meta connection",
          meta_connection_id: connection.id,
          errors: inspect(cs.errors)
        )

      {:error, reason} ->
        Logger.warning("Failed to revoke meta connection",
          meta_connection_id: connection.id,
          reason: ErrorHelpers.safe_reason(reason)
        )
    end
  end

  defp sync_account(connection, account) do
    with {:ok, ad_account} <- Ads.upsert_ad_account(connection, build_ad_account_attrs(account)),
         {:ok, payload} <- Jason.encode(%{ad_account_id: ad_account.id, sync_type: "full"}),
         :ok <- publisher().publish(payload) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("Failed to sync ad account reason=#{inspect(reason)}",
          meta_connection_id: connection.id,
          meta_id: account["id"]
        )

        {:error, reason}
    end
  end

  # Meta account_status values: 1=ACTIVE, 2=DISABLED, 3=UNSETTLED, 101=CLOSED
  @account_status_map %{1 => "ACTIVE", 2 => "DISABLED", 3 => "UNSETTLED", 101 => "CLOSED"}

  defp build_ad_account_attrs(account) do
    raw_status = account["account_status"] || account["status"]

    status =
      cond do
        is_integer(raw_status) -> Map.get(@account_status_map, raw_status, "UNKNOWN")
        is_binary(raw_status) -> raw_status
        true -> "UNKNOWN"
      end

    bm = account["business"]

    %{
      meta_id: account["id"],
      name: account["name"],
      currency: account["currency"],
      timezone_name: account["timezone_name"],
      status: status,
      bm_id: bm && bm["id"],
      bm_name: bm && bm["name"],
      last_synced_at: DateTime.utc_now(),
      raw_jsonb: account
    }
  end

  defp meta_client, do: MetaClient.client()

  defp publisher do
    Application.get_env(:ad_butler, :messaging_publisher, AdButler.Messaging.PublisherPool)
  end
end
