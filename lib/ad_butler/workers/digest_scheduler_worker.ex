defmodule AdButler.Workers.DigestSchedulerWorker do
  @moduledoc "Fans out DigestWorker jobs for all users with active connections."

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: {23, :hours}, fields: [:args, :queue, :worker]]

  require Logger

  alias AdButler.{Accounts, Workers.DigestWorker}

  @chunk_size 500

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"period" => period}}) do
    users = Accounts.list_users_with_active_connections()

    users
    |> Enum.chunk_every(@chunk_size)
    |> Enum.each(fn chunk ->
      jobs = Enum.map(chunk, &DigestWorker.new(%{"user_id" => &1.id, "period" => period}))
      results = Oban.insert_all(jobs)

      # Oban.insert_all/1 returns [Job.t()] only — uniqueness conflicts produce
      # fewer results, not Changeset errors. Warn only when nothing inserted at all,
      # which indicates a genuine DB failure rather than expected dedup suppression.
      if results == [] and chunk != [] do
        Logger.warning("DigestSchedulerWorker: no digest jobs inserted for chunk",
          chunk_size: length(chunk),
          period: period
        )
      end
    end)

    :ok
  end
end
