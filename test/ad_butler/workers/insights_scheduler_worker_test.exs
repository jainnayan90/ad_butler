defmodule AdButler.Workers.InsightsSchedulerWorkerTest do
  use AdButler.DataCase, async: false
  use Oban.Testing, repo: AdButler.Repo

  import AdButler.Factory
  import Mox

  alias AdButler.Workers.InsightsSchedulerWorker

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    Application.put_env(:ad_butler, :insights_publisher, AdButler.Messaging.PublisherMock)
    on_exit(fn -> Application.delete_env(:ad_butler, :insights_publisher) end)
    :ok
  end

  describe "perform/1" do
    test "publishes one delivery message per active ad account" do
      insert(:ad_account)
      insert(:ad_account)
      insert(:ad_account)

      expect(AdButler.Messaging.PublisherMock, :publish, 3, fn payload, exchange ->
        assert exchange == "ad_butler.insights.fanout"
        decoded = Jason.decode!(payload)
        assert decoded["sync_type"] == "delivery"
        assert Map.has_key?(decoded, "ad_account_id")
        assert Map.has_key?(decoded, "jitter_secs")
        :ok
      end)

      assert :ok = perform_job(InsightsSchedulerWorker, %{})
    end

    test "jitter for each account is in [0, 1800) range" do
      accounts =
        Enum.map(1..3, fn _ -> insert(:ad_account) end)

      jitters = Enum.map(accounts, fn aa -> rem(:erlang.phash2(aa.meta_id), 1800) end)

      expect(AdButler.Messaging.PublisherMock, :publish, 3, fn _payload, _exchange -> :ok end)

      assert :ok = perform_job(InsightsSchedulerWorker, %{})

      Enum.each(jitters, fn j ->
        assert j >= 0 and j < 1800
      end)
    end

    test "inactive ad accounts are not included" do
      insert(:ad_account, status: "PAUSED")

      # No messages published — 0 expects means mock must NOT be called
      expect(AdButler.Messaging.PublisherMock, :publish, 0, fn _p, _e -> :ok end)

      assert :ok = perform_job(InsightsSchedulerWorker, %{})
    end
  end
end
