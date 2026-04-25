defmodule AdButler.Workers.TokenRefreshSweepWorkerTest do
  # async: false — Application.put_env(:oban_mod) is process-global state
  use AdButler.DataCase, async: false
  use Oban.Testing, repo: AdButler.Repo

  import AdButler.Factory
  import Mox

  alias AdButler.Workers.{ObanMock, TokenRefreshSweepWorker}

  setup :verify_on_exit!

  describe "perform/1" do
    test "returns :ok with no qualifying connections" do
      assert :ok = perform_job(TokenRefreshSweepWorker, %{})
    end

    test "enqueues refresh job for active connection expiring within 14 days" do
      conn =
        insert(:meta_connection,
          status: "active",
          token_expires_at: DateTime.add(DateTime.utc_now(), 10 * 86_400, :second)
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

    test "does not enqueue for connections expiring beyond 14 days" do
      insert(:meta_connection,
        status: "active",
        token_expires_at: DateTime.add(DateTime.utc_now(), 20 * 86_400, :second)
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

  describe "perform/1 — when all inserts are conflict-skipped" do
    setup do
      Application.put_env(:ad_butler, :oban_mod, ObanMock)
      on_exit(fn -> Application.delete_env(:ad_butler, :oban_mod) end)
      :ok
    end

    test "returns :ok (on_conflict: :nothing skips are not failures)" do
      insert(:meta_connection,
        status: "active",
        token_expires_at: DateTime.add(DateTime.utc_now(), 5 * 86_400, :second)
      )

      expect(ObanMock, :insert_all, fn _changesets -> [] end)

      assert :ok = perform_job(TokenRefreshSweepWorker, %{})
    end
  end
end
