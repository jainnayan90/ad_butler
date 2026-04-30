defmodule AdButler.Sync.MetadataPipelineTest do
  use AdButler.DataCase, async: false

  import AdButler.Factory
  import Mox

  import ExUnit.CaptureLog

  alias AdButler.{Ads, Repo}
  alias AdButler.Sync.MetadataPipeline

  setup :verify_on_exit!
  setup :set_mox_global

  setup do
    {:ok, _pid} = start_supervised(MetadataPipeline)
    :ok
  end

  defp campaign_payload(ad_account_id) do
    [
      %{
        "id" => "campaign_1",
        "name" => "Test Campaign",
        "status" => "ACTIVE",
        "objective" => "OUTCOME_TRAFFIC",
        "daily_budget" => "1000"
      }
    ]
    |> then(fn campaigns -> {ad_account_id, campaigns} end)
  end

  describe "valid message" do
    test "upserts campaigns, ad_sets, and ads in DB" do
      user = insert(:user)
      mc = insert(:meta_connection, user: user)
      ad_account = insert(:ad_account, meta_connection: mc)

      {_aa_id, campaigns} = campaign_payload(ad_account.id)

      ad_sets = [
        %{
          "id" => "adset_1",
          "name" => "Test AdSet",
          "status" => "ACTIVE",
          "campaign_id" => "campaign_1"
        }
      ]

      expect(AdButler.Meta.ClientMock, :list_campaigns, fn _aa_meta_id, _token, _opts ->
        {:ok, campaigns}
      end)

      expect(AdButler.Meta.ClientMock, :list_ad_sets, fn _aa_meta_id, _token, _opts ->
        {:ok, ad_sets}
      end)

      expect(AdButler.Meta.ClientMock, :list_ads, fn _aa_meta_id, _token, _opts ->
        {:ok, []}
      end)

      payload = Jason.encode!(%{ad_account_id: ad_account.id, sync_type: "full"})
      ref = Broadway.test_message(MetadataPipeline, payload)

      assert_receive {:ack, ^ref, [_], []}, 2_000

      assert length(Ads.list_campaigns(user)) == 1
      assert length(Ads.list_ad_sets(user)) == 1
    end
  end

  describe "unknown ad_account_id" do
    test "message fails gracefully without crashing" do
      payload = Jason.encode!(%{ad_account_id: Ecto.UUID.generate(), sync_type: "full"})
      ref = Broadway.test_message(MetadataPipeline, payload)

      assert_receive {:ack, ^ref, [], [_failed]}, 2_000
    end
  end

  describe "rate limit error" do
    test "message fails, no DB writes" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)

      expect(AdButler.Meta.ClientMock, :list_campaigns, fn _aa_meta_id, _token, _opts ->
        {:error, :rate_limit_exceeded}
      end)

      payload = Jason.encode!(%{ad_account_id: ad_account.id, sync_type: "full"})
      ref = Broadway.test_message(MetadataPipeline, payload)

      assert_receive {:ack, ^ref, [], [_failed]}, 2_000

      assert Repo.aggregate(AdButler.Ads.Campaign, :count) == 0
    end
  end

  describe "ads sync" do
    test "upserts ads when API returns non-empty list" do
      user = insert(:user)
      mc = insert(:meta_connection, user: user)
      ad_account = insert(:ad_account, meta_connection: mc)

      campaigns = [
        %{
          "id" => "campaign_1",
          "name" => "C1",
          "status" => "ACTIVE",
          "objective" => "OUTCOME_TRAFFIC"
        }
      ]

      ad_sets = [
        %{"id" => "adset_1", "name" => "AS1", "status" => "ACTIVE", "campaign_id" => "campaign_1"}
      ]

      ads = [
        %{"id" => "ad_1", "name" => "Ad One", "status" => "ACTIVE", "adset_id" => "adset_1"},
        %{"id" => "ad_2", "name" => "Ad Two", "status" => "ACTIVE", "adset_id" => "adset_1"}
      ]

      expect(AdButler.Meta.ClientMock, :list_campaigns, fn _, _, _ -> {:ok, campaigns} end)
      expect(AdButler.Meta.ClientMock, :list_ad_sets, fn _, _, _ -> {:ok, ad_sets} end)
      expect(AdButler.Meta.ClientMock, :list_ads, fn _, _, _ -> {:ok, ads} end)

      payload = Jason.encode!(%{ad_account_id: ad_account.id, sync_type: "full"})
      ref = Broadway.test_message(MetadataPipeline, payload)

      assert_receive {:ack, ^ref, [_], []}, 2_000

      assert Repo.aggregate(AdButler.Ads.Ad, :count) == 2
    end

    test "drops ads with no matching ad set (orphan guard) and sync still returns :ok" do
      user = insert(:user)
      mc = insert(:meta_connection, user: user)
      ad_account = insert(:ad_account, meta_connection: mc)

      campaigns = [
        %{
          "id" => "campaign_1",
          "name" => "C1",
          "status" => "ACTIVE",
          "objective" => "OUTCOME_TRAFFIC"
        }
      ]

      ad_sets = [
        %{"id" => "adset_1", "name" => "AS1", "status" => "ACTIVE", "campaign_id" => "campaign_1"}
      ]

      ads = [
        %{"id" => "ad_good", "name" => "Good Ad", "status" => "ACTIVE", "adset_id" => "adset_1"},
        %{
          "id" => "ad_orphan",
          "name" => "Orphan Ad",
          "status" => "ACTIVE",
          "adset_id" => "adset_nonexistent"
        }
      ]

      expect(AdButler.Meta.ClientMock, :list_campaigns, fn _, _, _ -> {:ok, campaigns} end)
      expect(AdButler.Meta.ClientMock, :list_ad_sets, fn _, _, _ -> {:ok, ad_sets} end)
      expect(AdButler.Meta.ClientMock, :list_ads, fn _, _, _ -> {:ok, ads} end)

      payload = Jason.encode!(%{ad_account_id: ad_account.id, sync_type: "full"})
      ref = Broadway.test_message(MetadataPipeline, payload)

      assert_receive {:ack, ^ref, [_], []}, 2_000

      assert Repo.aggregate(AdButler.Ads.Ad, :count) == 1
      [ad] = Repo.all(AdButler.Ads.Ad)
      assert ad.meta_id == "ad_good"
    end
  end

  describe "unauthorized API responses" do
    test "list_campaigns returns {:error, :unauthorized} → message failed" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)

      expect(AdButler.Meta.ClientMock, :list_campaigns, fn _, _, _ ->
        {:error, :unauthorized}
      end)

      payload = Jason.encode!(%{ad_account_id: ad_account.id, sync_type: "full"})
      ref = Broadway.test_message(MetadataPipeline, payload)

      assert_receive {:ack, ^ref, [], [_failed]}, 2_000
    end

    test "list_ad_sets returns {:error, :unauthorized} → message failed" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)

      expect(AdButler.Meta.ClientMock, :list_campaigns, fn _, _, _ ->
        {:ok,
         [%{"id" => "c1", "name" => "C", "status" => "ACTIVE", "objective" => "OUTCOME_TRAFFIC"}]}
      end)

      expect(AdButler.Meta.ClientMock, :list_ad_sets, fn _, _, _ ->
        {:error, :unauthorized}
      end)

      payload = Jason.encode!(%{ad_account_id: ad_account.id, sync_type: "full"})
      ref = Broadway.test_message(MetadataPipeline, payload)

      assert_receive {:ack, ^ref, [], [_failed]}, 2_000
    end

    test "list_ads returns {:error, :unauthorized} → message failed" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)

      expect(AdButler.Meta.ClientMock, :list_campaigns, fn _, _, _ ->
        {:ok,
         [%{"id" => "c1", "name" => "C", "status" => "ACTIVE", "objective" => "OUTCOME_TRAFFIC"}]}
      end)

      expect(AdButler.Meta.ClientMock, :list_ad_sets, fn _, _, _ -> {:ok, []} end)

      expect(AdButler.Meta.ClientMock, :list_ads, fn _, _, _ ->
        {:error, :unauthorized}
      end)

      payload = Jason.encode!(%{ad_account_id: ad_account.id, sync_type: "full"})
      ref = Broadway.test_message(MetadataPipeline, payload)

      assert_receive {:ack, ^ref, [], [_failed]}, 2_000
    end

    test "list_ads returns {:error, :rate_limit_exceeded} → message failed and warning logged" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)

      expect(AdButler.Meta.ClientMock, :list_campaigns, fn _, _, _ ->
        {:ok,
         [%{"id" => "c1", "name" => "C", "status" => "ACTIVE", "objective" => "OUTCOME_TRAFFIC"}]}
      end)

      expect(AdButler.Meta.ClientMock, :list_ad_sets, fn _, _, _ -> {:ok, []} end)

      expect(AdButler.Meta.ClientMock, :list_ads, fn _, _, _ ->
        {:error, :rate_limit_exceeded}
      end)

      payload = Jason.encode!(%{ad_account_id: ad_account.id, sync_type: "full"})

      log =
        capture_log(fn ->
          ref = Broadway.test_message(MetadataPipeline, payload)
          assert_receive {:ack, ^ref, [], [_failed]}, 2_000
        end)

      assert log =~ "Rate limit hit during metadata sync"
      assert Repo.aggregate(AdButler.Ads.Ad, :count) == 0
    end
  end

  describe "orphan ad set (campaign_id not in campaign_id_map)" do
    test "orphan ad sets dropped, message still succeeds" do
      user = insert(:user)
      mc = insert(:meta_connection, user: user)
      ad_account = insert(:ad_account, meta_connection: mc)

      campaigns = [
        %{"id" => "c1", "name" => "C1", "status" => "ACTIVE", "objective" => "OUTCOME_TRAFFIC"}
      ]

      ad_sets = [
        %{"id" => "as_good", "name" => "Good", "status" => "ACTIVE", "campaign_id" => "c1"},
        %{
          "id" => "as_orphan",
          "name" => "Orphan",
          "status" => "ACTIVE",
          "campaign_id" => "c_gone"
        }
      ]

      expect(AdButler.Meta.ClientMock, :list_campaigns, fn _, _, _ -> {:ok, campaigns} end)
      expect(AdButler.Meta.ClientMock, :list_ad_sets, fn _, _, _ -> {:ok, ad_sets} end)
      expect(AdButler.Meta.ClientMock, :list_ads, fn _, _, _ -> {:ok, []} end)

      payload = Jason.encode!(%{ad_account_id: ad_account.id, sync_type: "full"})
      ref = Broadway.test_message(MetadataPipeline, payload)

      assert_receive {:ack, ^ref, [_], []}, 2_000

      assert Repo.aggregate(AdButler.Ads.AdSet, :count) == 1
      [ad_set] = Repo.all(AdButler.Ads.AdSet)
      assert ad_set.meta_id == "as_good"
    end
  end

  describe "malformed message payloads" do
    test "non-JSON payload → message failed with :invalid_payload" do
      ref = Broadway.test_message(MetadataPipeline, "not-json")
      assert_receive {:ack, ^ref, [], [_failed]}, 2_000
    end

    test "JSON without ad_account_id → message failed with :invalid_payload" do
      ref = Broadway.test_message(MetadataPipeline, ~s({"wrong_key": "abc"}))
      assert_receive {:ack, ^ref, [], [_failed]}, 2_000
    end
  end

  describe "retryable?/1 (DLQ routing)" do
    test "transient Meta failures are retryable" do
      assert MetadataPipeline.retryable?(:rate_limit_exceeded)
      assert MetadataPipeline.retryable?(:meta_server_error)
      assert MetadataPipeline.retryable?(:timeout)
    end

    test "validation and auth failures go straight to DLQ" do
      refute MetadataPipeline.retryable?(:invalid_payload)
      refute MetadataPipeline.retryable?(:not_found)
      refute MetadataPipeline.retryable?(:connection_not_found)
      refute MetadataPipeline.retryable?(:unauthorized)
      refute MetadataPipeline.retryable?(:forbidden)
      refute MetadataPipeline.retryable?({:bad_request, "anything"})
      refute MetadataPipeline.retryable?(:unknown_error)
    end
  end

  describe "parse_budget/1" do
    test "nil returns nil" do
      assert MetadataPipeline.parse_budget(nil) == nil
    end

    test "integer passthrough" do
      assert MetadataPipeline.parse_budget(1000) == 1000
    end

    test "numeric string parsed" do
      assert MetadataPipeline.parse_budget("2500") == 2500
    end

    test "non-numeric string returns nil" do
      assert MetadataPipeline.parse_budget("abc") == nil
    end

    test "partial numeric string returns nil" do
      assert MetadataPipeline.parse_budget("12abc") == nil
    end
  end

  describe "idempotency" do
    test "same ad_account_id twice produces no duplicate rows" do
      user = insert(:user)
      mc = insert(:meta_connection, user: user)
      ad_account = insert(:ad_account, meta_connection: mc)

      expect(AdButler.Meta.ClientMock, :list_campaigns, 2, fn _aa_meta_id, _token, _opts ->
        {:ok,
         [
           %{
             "id" => "campaign_1",
             "name" => "Test Campaign",
             "status" => "ACTIVE",
             "objective" => "OUTCOME_TRAFFIC"
           }
         ]}
      end)

      expect(AdButler.Meta.ClientMock, :list_ad_sets, 2, fn _aa_meta_id, _token, _opts ->
        {:ok, []}
      end)

      expect(AdButler.Meta.ClientMock, :list_ads, 2, fn _aa_meta_id, _token, _opts ->
        {:ok, []}
      end)

      payload = Jason.encode!(%{ad_account_id: ad_account.id, sync_type: "full"})

      ref1 = Broadway.test_message(MetadataPipeline, payload)
      assert_receive {:ack, ^ref1, [_], []}, 2_000

      ref2 = Broadway.test_message(MetadataPipeline, payload)
      assert_receive {:ack, ^ref2, [_], []}, 2_000

      assert length(Ads.list_campaigns(user)) == 1
    end
  end
end
