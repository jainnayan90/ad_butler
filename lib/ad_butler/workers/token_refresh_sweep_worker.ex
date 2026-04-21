defmodule AdButler.Workers.TokenRefreshSweepWorker do
  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: {6, :hours}, fields: [:worker]]

  import Ecto.Query

  require Logger

  alias AdButler.Accounts.MetaConnection
  alias AdButler.Repo
  alias AdButler.Workers.TokenRefreshWorker

  # Enqueue a refresh job for active connections expiring within 70 days.
  # Catches connections that slipped through normal scheduling (e.g. after a
  # deploy with no running workers). TokenRefreshWorker is unique-keyed by
  # meta_connection_id over 23h, so Oban handles deduplication at insert time.
  @impl Oban.Worker
  def perform(_job) do
    threshold = DateTime.add(DateTime.utc_now(), 70 * 86_400, :second)

    connections =
      from(mc in MetaConnection,
        where: mc.status == "active" and mc.token_expires_at < ^threshold
      )
      |> Repo.all()

    Enum.each(connections, fn conn ->
      case schedule_with_jitter(conn.id) do
        {:ok, _job} ->
          Logger.info("Sweep enqueued refresh", meta_connection_id: conn.id)

        {:error, reason} ->
          Logger.error("Sweep failed to enqueue refresh",
            meta_connection_id: conn.id,
            reason: reason
          )
      end
    end)

    :ok
  end

  defp schedule_with_jitter(meta_connection_id) do
    jitter = :rand.uniform(3_600)

    %{"meta_connection_id" => meta_connection_id}
    |> TokenRefreshWorker.new(schedule_in: jitter)
    |> Oban.insert()
  end
end
