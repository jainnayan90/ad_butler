defmodule AdButler.NotificationsTest do
  use AdButler.DataCase, async: true

  import AdButler.NotificationsFixtures
  import Swoosh.TestAssertions

  alias AdButler.Notifications

  describe "deliver_digest/2" do
    test "returns :ok and sends email when user has high findings" do
      user = user_with_finding("high")

      assert :ok = Notifications.deliver_digest(user, "daily")

      assert_email_sent(fn email ->
        {_name, addr} = email.from
        assert addr == "noreply@adbutler.app"
        [{_display, to_addr}] = email.to
        assert to_addr == user.email
      end)
    end

    test "returns :ok and sends email when user has medium findings" do
      user = user_with_finding("medium")

      assert :ok = Notifications.deliver_digest(user, "weekly")

      assert_email_sent(fn email ->
        assert email.subject =~ "weekly"
      end)
    end

    test "returns {:skip, :no_findings} when user has no findings" do
      user = user_without_findings()

      assert {:skip, :no_findings} = Notifications.deliver_digest(user, "daily")

      assert_no_email_sent()
    end

    test "returns {:skip, :no_findings} when user has only low-severity findings" do
      user = user_with_finding("low")

      assert {:skip, :no_findings} = Notifications.deliver_digest(user, "daily")

      assert_no_email_sent()
    end

    test "does not deliver another user's findings" do
      user_a = user_with_finding("high")
      user_b = user_without_findings()

      # Verify user A's findings are reachable (validates test setup)
      assert :ok = Notifications.deliver_digest(user_a, "daily")

      assert_email_sent(fn email ->
        [{_display, to_addr}] = email.to
        assert to_addr == user_a.email
      end)

      # User B cannot see user A's findings — scoping enforced by analytics query
      assert {:skip, :no_findings} = Notifications.deliver_digest(user_b, "daily")
    end
  end
end
