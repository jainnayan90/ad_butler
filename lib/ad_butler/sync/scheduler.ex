defmodule AdButler.Sync.Scheduler do
  @moduledoc """
  Convenience module for scheduling a full ad-account sync for a given connection.

  Wraps `FetchAdAccountsWorker` insertion so callers don't need to know the Oban
  job structure. Use this when triggering a sync from within application code
  (e.g. after OAuth login).
  """

  alias AdButler.Accounts.MetaConnection
  alias AdButler.Workers.FetchAdAccountsWorker

  @doc "Enqueues a `FetchAdAccountsWorker` job for `connection`, triggering a full ad-account sync."
  @spec schedule_sync_for_connection(MetaConnection.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def schedule_sync_for_connection(connection) do
    %{"meta_connection_id" => connection.id}
    |> FetchAdAccountsWorker.new()
    |> Oban.insert()
  end
end
