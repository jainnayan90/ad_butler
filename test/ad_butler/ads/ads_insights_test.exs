defmodule AdButler.Ads.AdsInsightsTest do
  # async: false — REFRESH MATERIALIZED VIEW touches shared state
  use AdButler.DataCase, async: false

  import AdButler.Factory

  alias AdButler.{Ads, Repo}

  defp insert_ad do
    ad_account = insert(:ad_account)
    campaign = insert(:campaign, ad_account: ad_account)
    ad_set = insert(:ad_set, ad_account: ad_account, campaign: campaign)
    insert(:ad, ad_account: ad_account, ad_set: ad_set)
  end

  defp insert_insight_row(ad, date_start, overrides) do
    base = %{
      ad_id: Ecto.UUID.dump!(ad.id),
      date_start: date_start,
      spend_cents: 1000,
      impressions: 500,
      clicks: 10,
      reach_count: 400,
      conversions: 2,
      conversion_value_cents: 5000,
      inserted_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    }

    Repo.insert_all("insights_daily", [Map.merge(base, overrides)])
  end

  defp refresh_views do
    # Non-concurrent refresh is safe inside a test transaction
    Repo.query!("REFRESH MATERIALIZED VIEW ad_insights_7d")
    Repo.query!("REFRESH MATERIALIZED VIEW ad_insights_30d")
  end

  # ---------------------------------------------------------------------------
  # bulk_upsert_insights/1
  # ---------------------------------------------------------------------------

  describe "bulk_upsert_insights/1" do
    test "inserts rows and returns {:ok, count}" do
      ad = insert_ad()
      today = Date.utc_today()

      rows = [
        %{
          ad_id: ad.id,
          date_start: today,
          spend_cents: 2000,
          impressions: 1000,
          clicks: 20,
          reach_count: 800,
          conversions: 4,
          conversion_value_cents: 10_000,
          inserted_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
        }
      ]

      assert {:ok, 1} = Ads.bulk_upsert_insights(rows)
      assert Repo.aggregate("insights_daily", :count) == 1
    end

    test "upserts existing rows and updates changed values" do
      ad1 = insert_ad()
      ad2 = insert_ad()
      ad3 = insert_ad()
      today = Date.utc_today()

      # Insert 3 rows
      {:ok, 3} =
        Ads.bulk_upsert_insights([
          %{
            ad_id: ad1.id,
            date_start: today,
            spend_cents: 1000,
            impressions: 100,
            clicks: 5,
            reach_count: 80,
            conversions: 1,
            conversion_value_cents: 2000,
            inserted_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
          },
          %{
            ad_id: ad2.id,
            date_start: today,
            spend_cents: 2000,
            impressions: 200,
            clicks: 10,
            reach_count: 160,
            conversions: 2,
            conversion_value_cents: 4000,
            inserted_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
          },
          %{
            ad_id: ad3.id,
            date_start: today,
            spend_cents: 3000,
            impressions: 300,
            clicks: 15,
            reach_count: 240,
            conversions: 3,
            conversion_value_cents: 6000,
            inserted_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
          }
        ])

      # Upsert 2 of them with updated spend
      {:ok, 2} =
        Ads.bulk_upsert_insights([
          %{
            ad_id: ad1.id,
            date_start: today,
            spend_cents: 9999,
            impressions: 100,
            clicks: 5,
            reach_count: 80,
            conversions: 1,
            conversion_value_cents: 2000,
            inserted_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
          },
          %{
            ad_id: ad2.id,
            date_start: today,
            spend_cents: 8888,
            impressions: 200,
            clicks: 10,
            reach_count: 160,
            conversions: 2,
            conversion_value_cents: 4000,
            inserted_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
          }
        ])

      # Total row count stays at 3
      assert Repo.aggregate("insights_daily", :count) == 3

      # Updated values persisted
      %{rows: [[spend1]]} =
        Repo.query!(
          "SELECT spend_cents FROM insights_daily WHERE ad_id = $1",
          [Ecto.UUID.dump!(ad1.id)]
        )

      assert spend1 == 9999

      %{rows: [[spend2]]} =
        Repo.query!(
          "SELECT spend_cents FROM insights_daily WHERE ad_id = $1",
          [Ecto.UUID.dump!(ad2.id)]
        )

      assert spend2 == 8888
    end
  end

  # ---------------------------------------------------------------------------
  # get_7d_insights/1 and get_30d_baseline/1
  # ---------------------------------------------------------------------------

  describe "unsafe_get_7d_insights/1" do
    test "returns aggregated spend for an ad in the last 7 days" do
      ad = insert_ad()
      today = Date.utc_today()

      insert_insight_row(ad, today, %{spend_cents: 5000, impressions: 1000, clicks: 50})

      refresh_views()

      assert {:ok, %{spend_cents: 5000, impressions: 1000, clicks: 50}} =
               Ads.unsafe_get_7d_insights(ad.id)
    end

    test "returns {:ok, nil} for an ad with no recent data" do
      ad = insert_ad()
      refresh_views()

      assert {:ok, nil} = Ads.unsafe_get_7d_insights(ad.id)
    end

    test "tenant isolation: user_b's ad_id returns nil even when user_a has data" do
      ad_a = insert_ad()
      ad_b = insert_ad()
      today = Date.utc_today()

      insert_insight_row(ad_a, today, %{spend_cents: 9999, impressions: 100, clicks: 5})

      refresh_views()

      assert {:ok, %{spend_cents: 9999}} = Ads.unsafe_get_7d_insights(ad_a.id)
      assert {:ok, nil} = Ads.unsafe_get_7d_insights(ad_b.id)
    end
  end

  describe "unsafe_get_30d_baseline/1" do
    test "returns aggregated spend for an ad in the last 30 days" do
      ad = insert_ad()
      today = Date.utc_today()

      insert_insight_row(ad, today, %{spend_cents: 5000, impressions: 500, clicks: 50})

      refresh_views()

      assert {:ok, %{spend_cents: 5000}} = Ads.unsafe_get_30d_baseline(ad.id)
    end

    test "returns {:ok, nil} for an ad with no data" do
      ad = insert_ad()
      refresh_views()

      assert {:ok, nil} = Ads.unsafe_get_30d_baseline(ad.id)
    end

    test "tenant isolation: user_b's ad_id returns nil even when user_a has data" do
      ad_a = insert_ad()
      ad_b = insert_ad()
      today = Date.utc_today()

      insert_insight_row(ad_a, today, %{spend_cents: 7777, impressions: 200, clicks: 10})

      refresh_views()

      assert {:ok, %{spend_cents: 7777}} = Ads.unsafe_get_30d_baseline(ad_a.id)
      assert {:ok, nil} = Ads.unsafe_get_30d_baseline(ad_b.id)
    end
  end
end
