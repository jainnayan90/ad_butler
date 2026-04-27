defmodule AdButler.Ads.InsightTest do
  # async: false — DDL queries touch shared schema state (pg_inherits)
  use AdButler.DataCase, async: false

  import AdButler.Factory

  alias AdButler.Repo

  defp insert_ad do
    ad_account = insert(:ad_account)
    campaign = insert(:campaign, ad_account: ad_account)
    ad_set = insert(:ad_set, ad_account: ad_account, campaign: campaign)
    insert(:ad, ad_account: ad_account, ad_set: ad_set)
  end

  defp insert_insight(ad, date_start) do
    Repo.insert_all("insights_daily", [
      %{
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
    ])
  end

  describe "partition routing" do
    test "row with date_start in current week routes to a child partition" do
      ad = insert_ad()
      date_start = Date.utc_today()

      {1, _} = insert_insight(ad, date_start)

      # The row must exist in a child table (pg_inherits has ≥1 row for insights_daily)
      %{rows: [[child_count]]} =
        Repo.query!("""
        SELECT COUNT(*) FROM pg_inherits
        JOIN pg_class parent ON parent.oid = pg_inherits.inhparent
        WHERE parent.relname = 'insights_daily'
        """)

      assert child_count >= 1

      # The row is accessible via the parent table
      assert Repo.aggregate("insights_daily", :count) == 1
    end
  end

  describe "uniqueness constraint" do
    test "inserting a duplicate (ad_id, date_start) raises a constraint error" do
      ad = insert_ad()
      date_start = Date.utc_today()

      {1, _} = insert_insight(ad, date_start)

      assert_raise Postgrex.Error, ~r/duplicate key value/, fn ->
        insert_insight(ad, date_start)
      end
    end
  end
end
