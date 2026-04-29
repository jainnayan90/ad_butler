defmodule AdButler.Workers.InsightsSchedulerWorker do
  @moduledoc """
  Oban worker that fans out one insights-delivery message per active `AdAccount`
  to the `ad_butler.insights.delivery` RabbitMQ queue.

  Runs every 30 minutes. Jitter (`rem(:erlang.phash2(meta_id), 1800)` seconds) is
  included in each message so downstream consumers can spread their API calls rather
  than hammering Meta simultaneously.

  **Retry behaviour:** This worker is not fully idempotent — a retry after partial
  failure republishes messages to accounts that already received one. Downstream
  consumers of `ad_butler.insights.*` queues must be idempotent (safe to process
  duplicate messages).
  """
  use Oban.Worker, queue: :default, max_attempts: 3, unique: [period: 1800]

  require Logger

  alias AdButler.Ads

  @insights_exchange "ad_butler.insights.fanout"

  @doc "Publishes one delivery sync message per active ad account."
  @impl Oban.Worker
  def perform(_job) do
    case Ads.stream_ad_accounts_and_run(&collect_payloads/1) do
      {:ok, payloads} ->
        {count, errors} = Enum.reduce(payloads, {0, []}, &publish_and_accumulate/2)
        Logger.info("insights delivery scheduler complete", count: count)

        case errors do
          [] -> :ok
          [{:error, reason} | _] -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # 1 minute above the 5-minute DB transaction timeout in stream_ad_accounts_and_run/2,
  # so the DB call fails cleanly before Oban kills the job.
  # Requires Postgres idle_in_transaction_session_timeout to exceed 5 minutes on the host.
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(6)

  defp publish_and_accumulate(payload, {n, errs}) do
    case publish_payload(payload) do
      :ok -> {n + 1, errs}
      {:error, r} -> {n, [{:error, r} | errs]}
    end
  end

  defp collect_payloads(stream) do
    results = Enum.map(stream, &build_payload/1)
    {ok, errors} = Enum.split_with(results, &match?({:ok, _}, &1))

    if errors != [] do
      Logger.warning("insights scheduler: encode failed for some accounts",
        dropped: length(errors)
      )
    end

    Enum.map(ok, fn {:ok, payload} -> payload end)
  end

  defp build_payload(account) do
    jitter = rem(:erlang.phash2(account.meta_id), 1800)

    case Jason.encode(%{ad_account_id: account.id, sync_type: "delivery", jitter_secs: jitter}) do
      {:ok, payload} ->
        {:ok, payload}

      {:error, reason} ->
        Logger.error("insights scheduler encode failed",
          ad_account_id: account.id,
          reason: reason
        )

        {:error, reason}
    end
  end

  defp publish_payload(payload) do
    case publisher().publish(payload, @insights_exchange) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("insights scheduler publish failed", reason: reason)
        {:error, reason}
    end
  end

  defp publisher do
    Application.get_env(:ad_butler, :insights_publisher, AdButler.Messaging.PublisherPool)
  end
end
