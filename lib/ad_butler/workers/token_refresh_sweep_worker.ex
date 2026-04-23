defmodule AdButler.Workers.TokenRefreshSweepWorker do
  @moduledoc """
  Oban worker that periodically sweeps for connections with tokens expiring soon
  and enqueues a `TokenRefreshWorker` job for each.

  Acts as a catch-up mechanism for connections whose normal per-refresh scheduling
  was missed (e.g. after a deploy with no running workers). The sweep window is
  intentionally narrower than the per-refresh buffer to avoid re-scheduling every
  active token on every run.
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: {6, :hours}, fields: [:worker]]

  require Logger

  alias AdButler.Accounts
  alias AdButler.Workers.TokenRefreshWorker

  @default_limit 500

  # 14 days is intentionally larger than TokenRefreshWorker's @refresh_buffer_days (10).
  # The normal path schedules a refresh at (expiry - 10 days); the sweep's job is to
  # catch connections where that scheduling was missed (e.g. after a deploy with no
  # running workers). A 70-day window matches every active 60-day Meta token on every
  # run, turning the catch-up sweep into a continuous hammer — 14 days keeps it narrow.
  @sweep_days_ahead 14

  @impl Oban.Worker
  def perform(_job) do
    connections = Accounts.list_expiring_meta_connections(@sweep_days_ahead, @default_limit)

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
