defmodule AdButler.Sync.SchedulerTest do
  use AdButler.DataCase, async: false

  import AdButler.Factory

  use Oban.Testing, repo: AdButler.Repo

  alias AdButler.Sync.Scheduler
  alias AdButler.Workers.FetchAdAccountsWorker
  alias AdButler.Workers.SyncAllConnectionsWorker

  describe "schedule_sync_for_connection/1" do
    test "enqueues a FetchAdAccountsWorker job with string key" do
      conn = insert(:meta_connection)

      assert {:ok, _job} = Scheduler.schedule_sync_for_connection(conn)

      assert_enqueued(
        worker: FetchAdAccountsWorker,
        args: %{"meta_connection_id" => conn.id}
      )
    end
  end

  describe "SyncAllConnectionsWorker.perform/1" do
    test "enqueues jobs for active connections only" do
      user = insert(:user)
      _active1 = insert(:meta_connection, user: user, status: "active")
      _active2 = insert(:meta_connection, user: user, status: "active")
      _revoked = insert(:meta_connection, user: user, status: "revoked")

      assert :ok = perform_job(SyncAllConnectionsWorker, %{})

      assert length(all_enqueued(worker: FetchAdAccountsWorker)) == 2
      [job1, job2] = all_enqueued(worker: FetchAdAccountsWorker)
      assert Map.has_key?(job1.args, "meta_connection_id")
      assert Map.has_key?(job2.args, "meta_connection_id")
    end

    test "returns :ok with no connections" do
      assert :ok = perform_job(SyncAllConnectionsWorker, %{})
      assert all_enqueued(worker: FetchAdAccountsWorker) == []
    end
  end
end
