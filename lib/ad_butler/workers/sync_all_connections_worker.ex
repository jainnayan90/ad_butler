defmodule AdButler.Workers.SyncAllConnectionsWorker do
  @moduledoc """
  Oban worker that fans out a `FetchAdAccountsWorker` job for every active
  `MetaConnection`.

  Runs on a cron schedule to trigger a full sync sweep across all users. Deduplication
  is handled by `FetchAdAccountsWorker`'s own unique constraint so this worker can
  safely insert duplicates without causing double-syncs.
  """
  use Oban.Worker,
    queue: :sync,
    max_attempts: 3,
    unique: [period: 21_600, states: [:available, :executing, :scheduled, :retryable]]

  alias AdButler.Accounts
  alias AdButler.Workers.FetchAdAccountsWorker

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(2)

  @impl Oban.Worker
  def perform(_job) do
    case AdButler.Repo.transaction(&insert_jobs/0, timeout: :timer.minutes(2)) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_jobs do
    Accounts.stream_active_meta_connections()
    |> Stream.map(&FetchAdAccountsWorker.new(%{"meta_connection_id" => &1.id}))
    |> Stream.chunk_every(200)
    |> Enum.each(&Oban.insert_all/1)
  end
end
