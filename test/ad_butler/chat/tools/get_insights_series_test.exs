defmodule AdButler.Chat.Tools.GetInsightsSeriesTest do
  use AdButler.DataCase, async: true

  import AdButler.Factory
  import AdButler.InsightsHelpers, only: [insert_daily: 3]

  alias AdButler.Chat.Tools.GetInsightsSeries
  alias AdButler.Repo

  setup do
    # Create the weekly partitions covering today and the prior week so 7-day
    # windows insert successfully.
    Repo.query!("SELECT create_insights_partition((CURRENT_DATE)::DATE)")
    Repo.query!("SELECT create_insights_partition((CURRENT_DATE - INTERVAL '7 days')::DATE)")

    Repo.query!("SELECT create_insights_partition((CURRENT_DATE - INTERVAL '14 days')::DATE)")
    :ok
  end

  defp insert_ad_for_user(user) do
    mc = insert(:meta_connection, user: user)
    ad_account = insert(:ad_account, meta_connection: mc)
    campaign = insert(:campaign, ad_account: ad_account)
    ad_set = insert(:ad_set, ad_account: ad_account, campaign: campaign)
    ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)
    %{ad | ad_set: %{ad_set | campaign_id: campaign.id, campaign: campaign}}
  end

  defp insert_insights_row(ad, opts) do
    today = Date.utc_today()
    date_start = Keyword.get(opts, :date_start, today)
    days_ago = Date.diff(today, date_start)

    insert_daily(ad, days_ago, %{
      spend_cents: Keyword.get(opts, :spend_cents, 100),
      impressions: Keyword.get(opts, :impressions, 1000),
      clicks: Keyword.get(opts, :clicks, 25),
      cpm_cents: 100,
      ctr_numeric: Decimal.new("0.025")
    })
  end

  defp run_tool(user_id, params) do
    GetInsightsSeries.run(params, %{session_context: %{user_id: user_id}})
  end

  describe "tenant isolation" do
    test "user_b cannot pull user_a's insights" do
      user_a = insert(:user)
      user_b = insert(:user)
      _ = insert(:meta_connection, user: user_b)
      ad = insert_ad_for_user(user_a)

      assert {:error, :not_found} =
               run_tool(user_b.id, %{ad_id: ad.id, metric: "spend", window: "last_7d"})
    end
  end

  describe "happy path" do
    test "returns series with correct shape" do
      user = insert(:user)
      ad = insert_ad_for_user(user)
      insert_insights_row(ad, date_start: Date.utc_today(), spend_cents: 500)

      assert {:ok, payload} =
               run_tool(user.id, %{ad_id: ad.id, metric: "spend", window: "last_7d"})

      assert %{
               ad_id: id,
               metric: :spend,
               window: :last_7d,
               points: points,
               summary: %{min: _, max: _, avg: _, slope: _}
             } = payload

      assert id == ad.id
      assert is_list(points)
      assert points != []
    end

    test "empty data returns empty points + zero summary" do
      user = insert(:user)
      ad = insert_ad_for_user(user)

      assert {:ok, %{points: [], summary: %{min: 0, max: 0, avg: +0.0, slope: +0.0}}} =
               run_tool(user.id, %{ad_id: ad.id, metric: "spend", window: "last_7d"})
    end

    test "payload < 4 KB" do
      user = insert(:user)
      ad = insert_ad_for_user(user)

      for offset <- 0..6 do
        insert_insights_row(ad, date_start: Date.add(Date.utc_today(), -offset))
      end

      assert {:ok, payload} =
               run_tool(user.id, %{ad_id: ad.id, metric: "spend", window: "last_7d"})

      assert byte_size(Jason.encode!(payload)) < 4_000
    end
  end

  describe "schema validation" do
    test "rejects unknown metric" do
      assert {:error, _} =
               GetInsightsSeries.validate_params(%{ad_id: "abc", metric: "bananas"})
    end

    test "accepts known metric" do
      assert {:ok, _} =
               GetInsightsSeries.validate_params(%{ad_id: "abc", metric: "ctr"})
    end

    test "run/2 returns :invalid_metric instead of raising on bypass" do
      user = insert(:user)
      ad = insert_ad_for_user(user)

      assert {:error, :invalid_metric} =
               run_tool(user.id, %{ad_id: ad.id, metric: "weird", window: "last_7d"})
    end

    test "run/2 returns :invalid_window instead of raising on bypass" do
      user = insert(:user)
      ad = insert_ad_for_user(user)

      assert {:error, :invalid_window} =
               run_tool(user.id, %{ad_id: ad.id, metric: "spend", window: "last_99y"})
    end
  end
end
