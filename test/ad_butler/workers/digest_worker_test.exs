defmodule AdButler.Workers.DigestWorkerTest do
  use AdButler.DataCase, async: true
  use Oban.Testing, repo: AdButler.Repo

  import AdButler.NotificationsFixtures
  import Swoosh.TestAssertions

  alias AdButler.Workers.DigestWorker

  describe "perform/1" do
    test "returns :ok and delivers no email when no high/medium findings exist" do
      user = user_without_findings()

      assert :ok = perform_job(DigestWorker, %{"user_id" => user.id, "period" => "daily"})

      assert_no_email_sent()
    end

    test "returns :ok and delivers one email when findings exist" do
      user = user_with_finding("high")

      assert :ok = perform_job(DigestWorker, %{"user_id" => user.id, "period" => "daily"})

      assert_email_sent(fn email ->
        [{_display, to_addr}] = email.to
        assert to_addr == user.email
      end)
    end

    test "returns :ok and delivers email for weekly period" do
      user = user_with_finding("medium")

      assert :ok = perform_job(DigestWorker, %{"user_id" => user.id, "period" => "weekly"})

      assert_email_sent(fn email ->
        assert email.subject =~ "weekly"
      end)
    end

    test "cancels job for unknown user_id instead of raising" do
      assert {:cancel, "user not found"} =
               perform_job(DigestWorker, %{"user_id" => Ecto.UUID.generate(), "period" => "daily"})
    end

    test "does not deliver user A findings to user B" do
      _user_a = user_with_finding("high")
      user_b = user_without_findings()

      assert :ok = perform_job(DigestWorker, %{"user_id" => user_b.id, "period" => "daily"})

      assert_no_email_sent()
    end
  end
end
