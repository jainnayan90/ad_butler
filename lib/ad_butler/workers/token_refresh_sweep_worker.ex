defmodule AdButler.Workers.TokenRefreshSweepWorker do
  @moduledoc """
  Oban worker that periodically sweeps for connections with tokens expiring soon
  and enqueues a `TokenRefreshWorker` job for each.

  Acts as a catch-up mechanism for connections whose normal per-refresh scheduling
  was missed (e.g. after a deploy with no running workers). The sweep window is
  intentionally narrower than the per-refresh buffer to avoid re-scheduling every
  active token on every run.

  All `TokenRefreshWorker` jobs are enqueued in a single bulk `Oban.insert_all/1`
  call rather than one `Oban.insert/1` per connection (avoids up to 500 DB round-trips).
  `insert_all` uses `on_conflict: :nothing`, so conflict-skipped rows (already-queued
  refreshes) are simply not returned — this is normal in steady state and is not treated
  as a failure.
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
    # Fetch one extra row to detect limit exhaustion without a separate COUNT query.
    # Enum.split returns {first_n, rest} in one pass — avoids length/1 + Enum.take double scan.
    {connections, overflow} =
      Accounts.list_expiring_meta_connections(@sweep_days_ahead, @default_limit + 1)
      |> Enum.split(@default_limit)

    if overflow != [] do
      Logger.warning(
        "Sweep hit connection limit #{@default_limit}; some connections deferred to next run"
      )
    end

    changesets = Enum.map(connections, &schedule_changeset(&1.id))
    total = length(changesets)

    inserted_jobs = oban_mod().insert_all(changesets)
    newly_enqueued = length(inserted_jobs)
    # on_conflict: :nothing conflict-skips are not returned — they are normal, not failures.
    # A real DB error raises before reaching this line and is handled by Oban's retry logic.
    skipped = total - newly_enqueued

    if skipped > 0 do
      inserted_ids = MapSet.new(inserted_jobs, & &1.args["meta_connection_id"])

      skipped_ids =
        connections
        |> Enum.map(& &1.id)
        |> Enum.reject(&MapSet.member?(inserted_ids, &1))

      Logger.warning("Sweep skipped or failed to enqueue some refreshes",
        count: skipped,
        meta_connection_ids: skipped_ids
      )
    end

    if total > 0 do
      Logger.info("Token refresh sweep complete",
        count: total,
        newly_enqueued: newly_enqueued,
        skipped: skipped
      )
    end

    :ok
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(2)

  defp oban_mod, do: Application.get_env(:ad_butler, :oban_mod, Oban)

  defp schedule_changeset(meta_connection_id) do
    jitter = :rand.uniform(3_600)

    TokenRefreshWorker.new(%{"meta_connection_id" => meta_connection_id}, schedule_in: jitter)
  end
end
