defmodule AdButler.Workers.SyncAllConnectionsWorkerTest do
  # async: false — Oban.Testing uses global job queue state
  use AdButler.DataCase, async: false
  use Oban.Testing, repo: AdButler.Repo

  import AdButler.Factory

  alias AdButler.Workers.{FetchAdAccountsWorker, SyncAllConnectionsWorker}

  describe "perform/1" do
    test "returns :ok with no active connections" do
      assert :ok = perform_job(SyncAllConnectionsWorker, %{})
      refute_enqueued(worker: FetchAdAccountsWorker)
    end

    test "enqueues a FetchAdAccountsWorker job for each active connection" do
      conn_a = insert(:meta_connection, status: "active")
      conn_b = insert(:meta_connection, status: "active")

      assert :ok = perform_job(SyncAllConnectionsWorker, %{})

      assert_enqueued(
        worker: FetchAdAccountsWorker,
        args: %{"meta_connection_id" => conn_a.id}
      )

      assert_enqueued(
        worker: FetchAdAccountsWorker,
        args: %{"meta_connection_id" => conn_b.id}
      )
    end

    test "does not enqueue jobs for non-active connections" do
      insert(:meta_connection, status: "revoked")
      insert(:meta_connection, status: "pending")

      assert :ok = perform_job(SyncAllConnectionsWorker, %{})
      refute_enqueued(worker: FetchAdAccountsWorker)
    end

    test "enqueues exactly one job per active connection" do
      insert_list(3, :meta_connection, status: "active")

      assert :ok = perform_job(SyncAllConnectionsWorker, %{})

      enqueued = all_enqueued(worker: FetchAdAccountsWorker)
      assert length(enqueued) == 3
    end
  end
end
