defmodule AdButler.Sync.Scheduler do
  @moduledoc false

  alias AdButler.Accounts.MetaConnection
  alias AdButler.Workers.FetchAdAccountsWorker

  @spec schedule_sync_for_connection(MetaConnection.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def schedule_sync_for_connection(connection) do
    %{"meta_connection_id" => connection.id}
    |> FetchAdAccountsWorker.new()
    |> Oban.insert()
  end
end
