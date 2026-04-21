defmodule AdButler.Workers.TokenRefreshSweepWorkerTest do
  use AdButler.DataCase, async: true
  use Oban.Testing, repo: AdButler.Repo

  import AdButler.Factory

  alias AdButler.Workers.TokenRefreshSweepWorker

  describe "perform/1" do
    test "returns :ok with no qualifying connections" do
      assert :ok = perform_job(TokenRefreshSweepWorker, %{})
    end

    test "enqueues refresh job for active connection expiring within 70 days" do
      conn =
        insert(:meta_connection,
          status: "active",
          token_expires_at: DateTime.add(DateTime.utc_now(), 30 * 86_400, :second)
        )

      assert :ok = perform_job(TokenRefreshSweepWorker, %{})

      assert_enqueued(
        worker: AdButler.Workers.TokenRefreshWorker,
        args: %{"meta_connection_id" => conn.id}
      )
    end

    test "enqueues refresh job for already-expired connection" do
      conn =
        insert(:meta_connection,
          status: "active",
          token_expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
        )

      assert :ok = perform_job(TokenRefreshSweepWorker, %{})

      assert_enqueued(
        worker: AdButler.Workers.TokenRefreshWorker,
        args: %{"meta_connection_id" => conn.id}
      )
    end

    test "does not enqueue for connections expiring beyond 70 days" do
      insert(:meta_connection,
        status: "active",
        token_expires_at: DateTime.add(DateTime.utc_now(), 100 * 86_400, :second)
      )

      assert :ok = perform_job(TokenRefreshSweepWorker, %{})
      refute_enqueued(worker: AdButler.Workers.TokenRefreshWorker)
    end

    test "does not enqueue for inactive connections" do
      insert(:meta_connection,
        status: "revoked",
        token_expires_at: DateTime.add(DateTime.utc_now(), 1 * 86_400, :second)
      )

      assert :ok = perform_job(TokenRefreshSweepWorker, %{})
      refute_enqueued(worker: AdButler.Workers.TokenRefreshWorker)
    end
  end
end
