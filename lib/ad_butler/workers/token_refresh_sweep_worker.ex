defmodule AdButler.Workers.TokenRefreshSweepWorker do
  @moduledoc false
  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: {6, :hours}, fields: [:worker]]

  require Logger

  alias AdButler.Accounts
  alias AdButler.Workers.TokenRefreshWorker

  @default_limit 500

  # Enqueue a refresh job for active connections expiring within 70 days.
  # Catches connections that slipped through normal scheduling (e.g. after a
  # deploy with no running workers). TokenRefreshWorker is unique-keyed by
  # meta_connection_id over 23h, so Oban handles deduplication at insert time.
  @impl Oban.Worker
  def perform(_job) do
    connections = Accounts.list_expiring_meta_connections(70, @default_limit)

    if length(connections) == @default_limit do
      Logger.warning(
        "Sweep hit connection limit #{@default_limit}; some connections deferred to next run"
      )
    end

    {succeeded, failed} =
      Enum.reduce(connections, {0, 0}, fn conn, {ok_count, err_count} ->
        case schedule_with_jitter(conn.id) do
          {:ok, _job} ->
            Logger.info("Sweep enqueued refresh", meta_connection_id: conn.id)
            {ok_count + 1, err_count}

          {:error, reason} ->
            Logger.error("Sweep failed to enqueue refresh",
              meta_connection_id: conn.id,
              reason: reason
            )

            {ok_count, err_count + 1}
        end
      end)

    if failed > 0 and succeeded == 0 do
      {:error, :all_enqueues_failed}
    else
      :ok
    end
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(2)

  defp schedule_with_jitter(meta_connection_id) do
    jitter = :rand.uniform(3_600)

    %{"meta_connection_id" => meta_connection_id}
    |> TokenRefreshWorker.new(schedule_in: jitter)
    |> Oban.insert()
  end
end
