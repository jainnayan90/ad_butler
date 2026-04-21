defmodule AdButler.Workers.TokenRefreshWorkerTest do
  use AdButler.DataCase, async: true
  use Oban.Testing, repo: AdButler.Repo

  import AdButler.Factory
  import Mox

  alias AdButler.Accounts
  alias AdButler.Workers.TokenRefreshWorker

  setup :set_mox_from_context
  setup :verify_on_exit!

  describe "perform/1 success" do
    test "updates token in DB and enqueues next refresh job" do
      conn = insert(:meta_connection)
      new_expiry = DateTime.add(DateTime.utc_now(), 30 * 86_400, :second)

      expect(AdButler.Meta.ClientMock, :refresh_token, fn _token ->
        {:ok, %{"access_token" => "refreshed_token", "expires_in" => 30 * 86_400}}
      end)

      assert :ok =
               perform_job(TokenRefreshWorker, %{
                 "meta_connection_id" => conn.id
               })

      updated = Accounts.get_meta_connection!(conn.id)
      assert updated.access_token == "refreshed_token"
      assert DateTime.diff(updated.token_expires_at, new_expiry, :second) |> abs() < 5

      assert_enqueued(
        worker: TokenRefreshWorker,
        queue: :default,
        args: %{"meta_connection_id" => conn.id}
      )
    end
  end

  describe "perform/1 failure" do
    test "snoozes on rate limit exceeded and leaves connection unchanged" do
      conn = insert(:meta_connection)

      expect(AdButler.Meta.ClientMock, :refresh_token, fn _token ->
        {:error, :rate_limit_exceeded}
      end)

      assert {:snooze, 3600} =
               perform_job(TokenRefreshWorker, %{"meta_connection_id" => conn.id})

      unchanged = Accounts.get_meta_connection!(conn.id)
      assert unchanged.access_token == conn.access_token
    end

    test "cancels and marks revoked on unauthorized" do
      conn = insert(:meta_connection)

      expect(AdButler.Meta.ClientMock, :refresh_token, fn _token ->
        {:error, :unauthorized}
      end)

      assert {:cancel, "unauthorized"} =
               perform_job(TokenRefreshWorker, %{"meta_connection_id" => conn.id})

      revoked = Accounts.get_meta_connection!(conn.id)
      assert revoked.status == "revoked"
    end
  end

  describe "perform/1 with non-existent connection" do
    test "returns cancel tuple" do
      assert {:cancel, _reason} =
               perform_job(TokenRefreshWorker, %{
                 "meta_connection_id" => "00000000-0000-0000-0000-000000000000"
               })
    end
  end

  describe "timeout/1" do
    test "returns 60 seconds" do
      assert TokenRefreshWorker.timeout(%Oban.Job{}) == :timer.seconds(60)
    end
  end

  describe "schedule_refresh/2" do
    test "enqueues job in default queue with correct scheduled_at" do
      conn = insert(:meta_connection)
      ref_time = DateTime.utc_now()

      assert {:ok, job} = TokenRefreshWorker.schedule_refresh(conn, 3)
      assert job.queue == "default"
      assert_in_delta DateTime.diff(job.scheduled_at, ref_time, :second), 3 * 86_400, 5
    end
  end

  describe "perform/1 edge cases" do
    test "60-day clamp: expires_in > 60 days schedules at most 60 days out", %{} do
      conn = insert(:meta_connection)

      expect(AdButler.Meta.ClientMock, :refresh_token, fn _token ->
        {:ok, %{"access_token" => "refreshed_token", "expires_in" => 71 * 86_400}}
      end)

      assert :ok = perform_job(TokenRefreshWorker, %{"meta_connection_id" => conn.id})

      [job] = all_enqueued(worker: TokenRefreshWorker)
      max_scheduled = DateTime.add(DateTime.utc_now(), 60 * 86_400, :second)
      assert DateTime.compare(job.scheduled_at, max_scheduled) != :gt
    end

    test "token_revoked: returns cancel and marks connection revoked", %{} do
      conn = insert(:meta_connection)

      expect(AdButler.Meta.ClientMock, :refresh_token, fn _token ->
        {:error, :token_revoked}
      end)

      assert {:cancel, "token_revoked"} =
               perform_job(TokenRefreshWorker, %{"meta_connection_id" => conn.id})

      revoked = Accounts.get_meta_connection!(conn.id)
      assert revoked.status == "revoked"
    end

    test "generic {:error, reason}: returns error for Oban retry", %{} do
      conn = insert(:meta_connection)

      expect(AdButler.Meta.ClientMock, :refresh_token, fn _token ->
        {:error, :meta_server_error}
      end)

      assert {:error, :meta_server_error} =
               perform_job(TokenRefreshWorker, %{"meta_connection_id" => conn.id})
    end

    test "schedule_refresh/2 returns {:ok, job} on success and schedules correctly", %{} do
      conn = insert(:meta_connection)
      ref_time = DateTime.utc_now()

      assert {:ok, job} = TokenRefreshWorker.schedule_refresh(conn, 5)
      assert job.queue == "default"

      expected_delay = 5 * 86_400
      assert_in_delta DateTime.diff(job.scheduled_at, ref_time, :second), expected_delay, 5
    end
  end

  describe "idempotency" do
    test "perform/1 twice does not crash on second call" do
      conn = insert(:meta_connection)

      expect(AdButler.Meta.ClientMock, :refresh_token, 2, fn _token ->
        {:ok, %{"access_token" => "refreshed_token", "expires_in" => 30 * 86_400}}
      end)

      assert :ok = perform_job(TokenRefreshWorker, %{"meta_connection_id" => conn.id})

      updated = Accounts.get_meta_connection!(conn.id)
      assert :ok = perform_job(TokenRefreshWorker, %{"meta_connection_id" => updated.id})
    end
  end
end
