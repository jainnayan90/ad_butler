defmodule AdButler.Sync.InsightsPipelineTest do
  use AdButler.DataCase, async: false

  import AdButler.Factory
  import ExUnit.CaptureLog
  import Mox

  alias AdButler.Repo
  alias AdButler.Sync.InsightsPipeline

  setup :verify_on_exit!
  setup :set_mox_global

  setup do
    {:ok, _pid} =
      start_supervised({InsightsPipeline, queue: "ad_butler.insights.delivery"})

    :ok
  end

  describe "happy path: delivery message" do
    test "fetches insights and upserts rows into insights_daily" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)
      campaign = insert(:campaign, ad_account: ad_account)
      ad_set = insert(:ad_set, ad_account: ad_account, campaign: campaign)
      ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)
      today = Date.to_iso8601(Date.utc_today())

      expect(AdButler.Meta.ClientMock, :get_rate_limit_usage, fn _meta_id -> 0.0 end)

      expect(AdButler.Meta.ClientMock, :get_insights, fn _aa_meta_id, _token, _opts ->
        {:ok,
         [
           %{
             ad_id: ad.meta_id,
             date_start: today,
             spend_cents: 1500,
             impressions: 300,
             clicks: 15,
             reach_count: 250,
             frequency: nil,
             conversions: 2,
             conversion_value_cents: 5000,
             ctr_numeric: nil,
             cpm_cents: nil,
             cpc_cents: nil,
             cpa_cents: nil,
             by_placement_jsonb: nil,
             by_age_gender_jsonb: nil
           }
         ]}
      end)

      payload =
        Jason.encode!(%{ad_account_id: ad_account.id, sync_type: "delivery"})

      ref = Broadway.test_message(InsightsPipeline.Delivery, payload)

      assert_receive {:ack, ^ref, [_], []}, 3_000

      assert Repo.aggregate("insights_daily", :count) == 1
    end
  end

  describe "rate-limit skip" do
    test "skips fetch when rate limit > 0.85 and logs a warning" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)

      expect(AdButler.Meta.ClientMock, :get_rate_limit_usage, fn _meta_id -> 0.90 end)

      payload =
        Jason.encode!(%{ad_account_id: ad_account.id, sync_type: "delivery"})

      log =
        capture_log(fn ->
          ref = Broadway.test_message(InsightsPipeline.Delivery, payload)
          assert_receive {:ack, ^ref, [_], []}, 3_000
        end)

      assert log =~ "insights skipped: rate limit"
      assert Repo.aggregate("insights_daily", :count) == 0
    end
  end
end
