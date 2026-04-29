defmodule AdButler.Workers.DigestSchedulerWorkerTest do
  use AdButler.DataCase, async: true
  use Oban.Testing, repo: AdButler.Repo

  import AdButler.Factory

  alias AdButler.Workers.{DigestSchedulerWorker, DigestWorker}

  describe "perform/1" do
    test "fans out one DigestWorker job per user with active connections" do
      user_a = insert(:user)
      user_b = insert(:user)
      insert(:meta_connection, user: user_a, status: "active")
      insert(:meta_connection, user: user_b, status: "active")

      assert :ok = perform_job(DigestSchedulerWorker, %{"period" => "daily"})

      assert_enqueued(worker: DigestWorker, args: %{"user_id" => user_a.id, "period" => "daily"})
      assert_enqueued(worker: DigestWorker, args: %{"user_id" => user_b.id, "period" => "daily"})
      assert length(all_enqueued(worker: DigestWorker)) == 2
    end

    test "skips users with no active connections" do
      active_user = insert(:user)
      inactive_user = insert(:user)
      insert(:meta_connection, user: active_user, status: "active")
      insert(:meta_connection, user: inactive_user, status: "expired")

      assert :ok = perform_job(DigestSchedulerWorker, %{"period" => "daily"})

      assert_enqueued(
        worker: DigestWorker,
        args: %{"user_id" => active_user.id, "period" => "daily"}
      )

      refute_enqueued(worker: DigestWorker, args: %{"user_id" => inactive_user.id})
      assert length(all_enqueued(worker: DigestWorker)) == 1
    end

    test "returns :ok with no jobs when no active connections exist" do
      assert :ok = perform_job(DigestSchedulerWorker, %{"period" => "weekly"})
      assert all_enqueued(worker: DigestWorker) == []
    end

    test "passes period through to DigestWorker jobs" do
      user = insert(:user)
      insert(:meta_connection, user: user, status: "active")

      assert :ok = perform_job(DigestSchedulerWorker, %{"period" => "weekly"})

      assert_enqueued(worker: DigestWorker, args: %{"user_id" => user.id, "period" => "weekly"})
    end
  end
end
