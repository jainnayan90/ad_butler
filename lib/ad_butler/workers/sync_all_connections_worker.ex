defmodule AdButler.Workers.SyncAllConnectionsWorker do
  @moduledoc false
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
    jobs =
      Accounts.list_all_active_meta_connections()
      |> Enum.map(fn connection ->
        FetchAdAccountsWorker.new(%{"meta_connection_id" => connection.id})
      end)

    Oban.insert_all(jobs)
    :ok
  end
end
