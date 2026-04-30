defmodule AdButler.AdsTest do
  use AdButler.DataCase, async: true

  import AdButler.Factory
  import Ecto.Query

  alias AdButler.Accounts
  alias AdButler.Ads

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp insert_ad_account_for_user(user) do
    mc = insert(:meta_connection, user: user)
    insert(:ad_account, meta_connection: mc)
  end

  defp insert_campaign_for_ad_account(ad_account) do
    insert(:campaign, ad_account: ad_account)
  end

  defp insert_ad_set_for(ad_account, campaign) do
    insert(:ad_set, ad_account: ad_account, campaign: campaign)
  end

  # ---------------------------------------------------------------------------
  # list_ad_accounts/1
  # ---------------------------------------------------------------------------

  describe "list_ad_accounts/1" do
    test "returns only the calling user's ad accounts" do
      user_a = insert(:user)
      user_b = insert(:user)
      aa_a = insert_ad_account_for_user(user_a)
      _aa_b = insert_ad_account_for_user(user_b)

      result = Ads.list_ad_accounts(user_a)
      assert length(result) == 1
      assert hd(result).id == aa_a.id
    end

    test "returns empty list when user has no ad accounts" do
      user = insert(:user)
      assert [] = Ads.list_ad_accounts(user)
    end
  end

  # ---------------------------------------------------------------------------
  # get_ad_account!/2
  # ---------------------------------------------------------------------------

  describe "get_ad_account!/2" do
    test "returns ad account for correct user" do
      user = insert(:user)
      aa = insert_ad_account_for_user(user)

      assert Ads.get_ad_account!(user, aa.id).id == aa.id
    end

    test "raises when user_a fetches user_b's account" do
      user_a = insert(:user)
      user_b = insert(:user)
      aa_b = insert_ad_account_for_user(user_b)

      assert_raise Ecto.NoResultsError, fn ->
        Ads.get_ad_account!(user_a, aa_b.id)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # upsert_ad_account/2
  # ---------------------------------------------------------------------------

  describe "upsert_ad_account/2" do
    test "inserts a new ad account" do
      mc = insert(:meta_connection)

      attrs = %{
        meta_id: "act_001",
        name: "Test",
        currency: "USD",
        timezone_name: "UTC",
        status: "ACTIVE"
      }

      assert {:ok, aa} = Ads.upsert_ad_account(mc.id, attrs)
      assert aa.meta_id == "act_001"
    end

    test "is idempotent on (meta_connection_id, meta_id) — updates name on second call" do
      mc = insert(:meta_connection)

      attrs = %{
        meta_id: "act_001",
        name: "Original",
        currency: "USD",
        timezone_name: "UTC",
        status: "ACTIVE"
      }

      {:ok, _} = Ads.upsert_ad_account(mc.id, attrs)
      {:ok, updated} = Ads.upsert_ad_account(mc.id, %{attrs | name: "Updated"})

      assert updated.name == "Updated"
      assert AdButler.Repo.aggregate(AdButler.Ads.AdAccount, :count) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # list_ad_account_ids_for_mc_ids/1
  # ---------------------------------------------------------------------------

  describe "list_ad_account_ids_for_mc_ids/1" do
    test "empty list returns []" do
      assert Ads.list_ad_account_ids_for_mc_ids([]) == []
    end

    test "returns only ad_account_ids for the given mc_ids" do
      mc_a = insert(:meta_connection)
      mc_b = insert(:meta_connection)
      aa_a = insert(:ad_account, meta_connection: mc_a)
      _aa_b = insert(:ad_account, meta_connection: mc_b)

      result = Ads.list_ad_account_ids_for_mc_ids([mc_a.id])
      assert result == [aa_a.id]
    end
  end

  # ---------------------------------------------------------------------------
  # list_campaigns/2
  # ---------------------------------------------------------------------------

  describe "list_campaigns/2" do
    test "user isolation — user_a sees only their campaigns" do
      user_a = insert(:user)
      user_b = insert(:user)
      aa_a = insert_ad_account_for_user(user_a)
      aa_b = insert_ad_account_for_user(user_b)
      c_a = insert_campaign_for_ad_account(aa_a)
      _c_b = insert_campaign_for_ad_account(aa_b)

      result = Ads.list_campaigns(user_a)
      assert length(result) == 1
      assert hd(result).id == c_a.id
    end

    test "filters by status" do
      user = insert(:user)
      aa = insert_ad_account_for_user(user)
      insert(:campaign, ad_account: aa, status: "ACTIVE")
      insert(:campaign, ad_account: aa, status: "PAUSED")

      result = Ads.list_campaigns(user, status: "ACTIVE")
      assert length(result) == 1
      assert hd(result).status == "ACTIVE"
    end

    test "filters by ad_account_id" do
      user = insert(:user)
      mc = insert(:meta_connection, user: user)
      aa1 = insert(:ad_account, meta_connection: mc)
      aa2 = insert(:ad_account, meta_connection: mc, meta_id: "act_999")
      insert(:campaign, ad_account: aa1)
      insert(:campaign, ad_account: aa2)

      result = Ads.list_campaigns(user, ad_account_id: aa1.id)
      assert length(result) == 1
      assert hd(result).ad_account_id == aa1.id
    end
  end

  # ---------------------------------------------------------------------------
  # get_campaign!/2
  # ---------------------------------------------------------------------------

  describe "get_campaign!/2" do
    test "returns campaign for owning user" do
      user = insert(:user)
      aa = insert_ad_account_for_user(user)
      campaign = insert_campaign_for_ad_account(aa)
      result = Ads.get_campaign!(user, campaign.id)
      assert %AdButler.Ads.Campaign{id: id} = result
      assert id == campaign.id
    end

    test "raises on cross-tenant access" do
      user_a = insert(:user)
      user_b = insert(:user)
      aa_b = insert_ad_account_for_user(user_b)
      c_b = insert_campaign_for_ad_account(aa_b)

      assert_raise Ecto.NoResultsError, fn ->
        Ads.get_campaign!(user_a, c_b.id)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # upsert_campaign/2
  # ---------------------------------------------------------------------------

  describe "upsert_campaign/2" do
    test "is idempotent on (ad_account_id, meta_id)" do
      aa = insert(:ad_account)

      attrs = %{
        meta_id: "campaign_001",
        name: "Original",
        status: "ACTIVE",
        objective: "OUTCOME_TRAFFIC"
      }

      {:ok, _} = Ads.upsert_campaign(aa, attrs)
      {:ok, updated} = Ads.upsert_campaign(aa, %{attrs | name: "Updated"})

      assert updated.name == "Updated"
      assert AdButler.Repo.aggregate(AdButler.Ads.Campaign, :count) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # upsert_ad_set/2
  # ---------------------------------------------------------------------------

  describe "upsert_ad_set/2" do
    test "inserts on first call" do
      aa = insert(:ad_account)
      campaign = insert(:campaign, ad_account: aa)
      attrs = %{meta_id: "s_1", name: "Original", status: "ACTIVE", campaign_id: campaign.id}

      assert {:ok, ad_set} = Ads.upsert_ad_set(aa, attrs)
      assert ad_set.meta_id == "s_1"
    end

    test "updates on duplicate (ad_account_id, meta_id)" do
      aa = insert(:ad_account)
      campaign = insert(:campaign, ad_account: aa)
      attrs = %{meta_id: "s_1", name: "Original", status: "ACTIVE", campaign_id: campaign.id}

      {:ok, first} = Ads.upsert_ad_set(aa, attrs)
      {:ok, second} = Ads.upsert_ad_set(aa, %{attrs | name: "Updated"})

      assert first.id == second.id
      assert second.name == "Updated"
    end
  end

  # ---------------------------------------------------------------------------
  # upsert_ad/2
  # ---------------------------------------------------------------------------

  describe "upsert_ad/2" do
    test "inserts on first call" do
      aa = insert(:ad_account)
      ad_set = insert_ad_set_for(aa, insert_campaign_for_ad_account(aa))
      attrs = %{meta_id: "ad_1", name: "Original", status: "ACTIVE", ad_set_id: ad_set.id}

      assert {:ok, ad} = Ads.upsert_ad(aa, attrs)
      assert ad.meta_id == "ad_1"
    end

    test "updates on duplicate (ad_account_id, meta_id)" do
      aa = insert(:ad_account)
      ad_set = insert_ad_set_for(aa, insert_campaign_for_ad_account(aa))
      attrs = %{meta_id: "ad_1", name: "Original", status: "ACTIVE", ad_set_id: ad_set.id}

      {:ok, first} = Ads.upsert_ad(aa, attrs)
      {:ok, second} = Ads.upsert_ad(aa, %{attrs | name: "Updated"})

      assert first.id == second.id
      assert second.name == "Updated"
    end
  end

  # ---------------------------------------------------------------------------
  # bulk_upsert_campaigns/2
  # ---------------------------------------------------------------------------

  describe "bulk_upsert_campaigns/2" do
    test "upserts on conflict (ad_account_id, meta_id)" do
      aa = insert(:ad_account)

      attrs = [
        %{meta_id: "c_1", name: "Original", status: "ACTIVE", objective: "OUTCOME_TRAFFIC"}
      ]

      {1, [%{id: id, meta_id: "c_1"}]} = Ads.bulk_upsert_campaigns(aa, attrs)
      {1, [%{id: ^id}]} = Ads.bulk_upsert_campaigns(aa, [%{hd(attrs) | name: "Updated"}])

      assert AdButler.Repo.aggregate(AdButler.Ads.Campaign, :count) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # bulk_upsert_ad_sets/2
  # ---------------------------------------------------------------------------

  describe "bulk_upsert_ad_sets/2" do
    test "inserts rows and returns {count, [%{id, meta_id}]}" do
      aa = insert(:ad_account)
      campaign = insert(:campaign, ad_account: aa)

      attrs = [
        %{meta_id: "s_1", name: "Set One", status: "ACTIVE", campaign_id: campaign.id}
      ]

      assert {1, [%{id: id, meta_id: "s_1"}]} = Ads.bulk_upsert_ad_sets(aa, attrs)
      assert is_binary(id)
    end

    test "is idempotent on (ad_account_id, meta_id) — row count stays 1" do
      aa = insert(:ad_account)
      campaign = insert(:campaign, ad_account: aa)

      attrs = [%{meta_id: "s_1", name: "Original", status: "ACTIVE", campaign_id: campaign.id}]

      {1, [%{id: id}]} = Ads.bulk_upsert_ad_sets(aa, attrs)
      {1, [%{id: ^id}]} = Ads.bulk_upsert_ad_sets(aa, [%{hd(attrs) | name: "Updated"}])

      assert AdButler.Repo.aggregate(AdButler.Ads.AdSet, :count) == 1
      reloaded = AdButler.Repo.get!(AdButler.Ads.AdSet, id)
      assert reloaded.name == "Updated"
    end
  end

  # ---------------------------------------------------------------------------
  # bulk_upsert_ads/2
  # ---------------------------------------------------------------------------

  describe "bulk_upsert_ads/2" do
    test "inserts rows and returns {count, [%{id, meta_id}]}" do
      aa = insert(:ad_account)
      ad_set = insert_ad_set_for(aa, insert_campaign_for_ad_account(aa))

      attrs = [
        %{meta_id: "ad_1", name: "Ad One", status: "ACTIVE", ad_set_id: ad_set.id}
      ]

      assert {1, [%{id: id, meta_id: "ad_1"}]} = Ads.bulk_upsert_ads(aa, attrs)
      assert is_binary(id)
    end

    test "is idempotent on (ad_account_id, meta_id) — same ID returned, name updated" do
      aa = insert(:ad_account)
      ad_set = insert_ad_set_for(aa, insert_campaign_for_ad_account(aa))
      attrs = [%{meta_id: "ad_1", name: "Original", status: "ACTIVE", ad_set_id: ad_set.id}]

      {1, [%{id: id}]} = Ads.bulk_upsert_ads(aa, attrs)
      {1, [%{id: ^id}]} = Ads.bulk_upsert_ads(aa, [%{hd(attrs) | name: "Updated"}])

      assert AdButler.Repo.aggregate(AdButler.Ads.Ad, :count) == 1
      reloaded = AdButler.Repo.get!(AdButler.Ads.Ad, id)
      assert reloaded.name == "Updated"
    end
  end

  # ---------------------------------------------------------------------------
  # append_quality_ranking_snapshots/2
  # ---------------------------------------------------------------------------

  describe "append_quality_ranking_snapshots/2" do
    test "appends a snapshot for every upserted ad" do
      aa = insert(:ad_account)
      ad_set = insert_ad_set_for(aa, insert_campaign_for_ad_account(aa))

      attrs =
        Enum.map(1..30, fn n ->
          %{
            meta_id: "ad_#{n}",
            name: "Ad #{n}",
            status: "ACTIVE",
            ad_set_id: ad_set.id
          }
        end)

      {30, upserted} = Ads.bulk_upsert_ads(aa, attrs)

      raw_ads =
        Enum.map(1..30, fn n ->
          %{
            "id" => "ad_#{n}",
            "quality_ranking" => "average",
            "engagement_rate_ranking" => "average",
            "conversion_rate_ranking" => "average"
          }
        end)

      assert :ok = Ads.append_quality_ranking_snapshots(upserted, raw_ads)

      ids = Enum.map(upserted, & &1.id)

      rows =
        AdButler.Repo.all(
          from a in AdButler.Ads.Ad,
            where: a.id in ^ids,
            select: {a.id, a.quality_ranking_history}
        )

      assert length(rows) == 30

      Enum.each(rows, fn {_id, history} ->
        assert %{"snapshots" => [snap]} = history
        assert snap["quality_ranking"] == "average"
      end)
    end

    test "appends to existing history without losing prior snapshots and caps at 14" do
      aa = insert(:ad_account)
      ad_set = insert_ad_set_for(aa, insert_campaign_for_ad_account(aa))

      {1, [%{id: ad_id, meta_id: meta_id} = upserted_row]} =
        Ads.bulk_upsert_ads(aa, [
          %{meta_id: "ad_capped", name: "Ad", status: "ACTIVE", ad_set_id: ad_set.id}
        ])

      # Pre-seed 14 prior snapshots — at the cap.
      prior =
        Enum.map(1..14, fn n ->
          %{
            "date" => Date.add(Date.utc_today(), -n) |> Date.to_iso8601(),
            "quality_ranking" => "above_average"
          }
        end)

      AdButler.Repo.update_all(
        from(a in AdButler.Ads.Ad, where: a.id == ^ad_id),
        set: [quality_ranking_history: %{"snapshots" => prior}]
      )

      raw = [
        %{
          "id" => meta_id,
          "quality_ranking" => "below_average_10_percent",
          "engagement_rate_ranking" => nil,
          "conversion_rate_ranking" => nil
        }
      ]

      assert :ok = Ads.append_quality_ranking_snapshots([upserted_row], raw)

      reloaded = AdButler.Repo.get!(AdButler.Ads.Ad, ad_id)
      snapshots = reloaded.quality_ranking_history["snapshots"]
      assert length(snapshots) == 14
      assert List.last(snapshots)["quality_ranking"] == "below_average_10_percent"
    end

    test "skips ads whose all three rankings are nil" do
      aa = insert(:ad_account)
      ad_set = insert_ad_set_for(aa, insert_campaign_for_ad_account(aa))

      {1, [%{id: ad_id, meta_id: meta_id} = upserted_row]} =
        Ads.bulk_upsert_ads(aa, [
          %{meta_id: "ad_nil", name: "Ad", status: "ACTIVE", ad_set_id: ad_set.id}
        ])

      raw = [
        %{
          "id" => meta_id,
          "quality_ranking" => nil,
          "engagement_rate_ranking" => nil,
          "conversion_rate_ranking" => nil
        }
      ]

      assert :ok = Ads.append_quality_ranking_snapshots([upserted_row], raw)

      reloaded = AdButler.Repo.get!(AdButler.Ads.Ad, ad_id)
      # Migration sets default `%{"snapshots" => []}` — confirm we did NOT write
      # a null-filled snapshot on top of it.
      assert reloaded.quality_ranking_history == %{"snapshots" => []}
    end
  end

  # ---------------------------------------------------------------------------
  # upsert_creative/2
  # ---------------------------------------------------------------------------

  describe "upsert_creative/2" do
    test "inserts a new creative" do
      aa = insert(:ad_account)
      attrs = %{meta_id: "cr_1", name: "Creative One", asset_specs_jsonb: %{}}

      assert {:ok, creative} = Ads.upsert_creative(aa, attrs)
      assert creative.meta_id == "cr_1"
    end

    test "is idempotent on (ad_account_id, meta_id) — updates name on second call" do
      aa = insert(:ad_account)
      attrs = %{meta_id: "cr_1", name: "Original", asset_specs_jsonb: %{}}

      {:ok, _} = Ads.upsert_creative(aa, attrs)
      {:ok, updated} = Ads.upsert_creative(aa, %{attrs | name: "Updated"})

      assert updated.name == "Updated"
      assert AdButler.Repo.aggregate(AdButler.Ads.Creative, :count) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # get_ad_account_for_sync/1 and get_ad_account_by_meta_id/2
  # ---------------------------------------------------------------------------

  describe "unsafe_get_ad_account_for_sync/1" do
    test "returns ad account by UUID" do
      aa = insert(:ad_account)
      assert Ads.unsafe_get_ad_account_for_sync(aa.id).id == aa.id
    end

    test "returns nil for unknown id" do
      assert Ads.unsafe_get_ad_account_for_sync(Ecto.UUID.generate()) == nil
    end
  end

  describe "get_ad_account_by_meta_id/2" do
    test "returns ad account for matching (meta_connection_id, meta_id)" do
      mc = insert(:meta_connection)
      aa = insert(:ad_account, meta_connection: mc, meta_id: "act_123")

      result = Ads.get_ad_account_by_meta_id(mc.id, "act_123")
      assert result.id == aa.id
    end

    test "returns nil when meta_id does not match" do
      mc = insert(:meta_connection)
      _aa = insert(:ad_account, meta_connection: mc, meta_id: "act_123")

      assert Ads.get_ad_account_by_meta_id(mc.id, "act_999") == nil
    end
  end

  # ---------------------------------------------------------------------------
  # get_ad_set!/2 cross-tenant
  # ---------------------------------------------------------------------------

  describe "get_ad_set!/2" do
    test "returns ad set for owning user" do
      user = insert(:user)
      aa = insert_ad_account_for_user(user)
      campaign = insert_campaign_for_ad_account(aa)
      ad_set = insert_ad_set_for(aa, campaign)
      result = Ads.get_ad_set!(user, ad_set.id)
      assert %AdButler.Ads.AdSet{id: id} = result
      assert id == ad_set.id
    end

    test "raises on cross-tenant access" do
      user_a = insert(:user)
      user_b = insert(:user)
      aa_b = insert_ad_account_for_user(user_b)
      c_b = insert_campaign_for_ad_account(aa_b)
      s_b = insert_ad_set_for(aa_b, c_b)

      assert_raise Ecto.NoResultsError, fn ->
        Ads.get_ad_set!(user_a, s_b.id)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # get_ad!/2 cross-tenant
  # ---------------------------------------------------------------------------

  describe "get_ad!/2" do
    test "returns ad for owning user" do
      user = insert(:user)
      aa = insert_ad_account_for_user(user)
      campaign = insert_campaign_for_ad_account(aa)
      ad_set = insert_ad_set_for(aa, campaign)
      ad = insert(:ad, ad_account: aa, ad_set: ad_set)
      result = Ads.get_ad!(user, ad.id)
      assert %AdButler.Ads.Ad{id: id} = result
      assert id == ad.id
    end

    test "raises on cross-tenant access" do
      user_a = insert(:user)
      user_b = insert(:user)
      aa_b = insert_ad_account_for_user(user_b)
      c_b = insert_campaign_for_ad_account(aa_b)
      s_b = insert_ad_set_for(aa_b, c_b)
      ad_b = insert(:ad, ad_account: aa_b, ad_set: s_b)

      assert_raise Ecto.NoResultsError, fn ->
        Ads.get_ad!(user_a, ad_b.id)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # list_ad_sets/2
  # ---------------------------------------------------------------------------

  describe "list_ad_sets/2" do
    test "user isolation" do
      user_a = insert(:user)
      user_b = insert(:user)
      aa_a = insert_ad_account_for_user(user_a)
      aa_b = insert_ad_account_for_user(user_b)
      c_a = insert_campaign_for_ad_account(aa_a)
      c_b = insert_campaign_for_ad_account(aa_b)
      s_a = insert_ad_set_for(aa_a, c_a)
      _s_b = insert_ad_set_for(aa_b, c_b)

      result = Ads.list_ad_sets(user_a)
      assert length(result) == 1
      assert hd(result).id == s_a.id
    end

    test "filters by campaign_id" do
      user = insert(:user)
      aa = insert_ad_account_for_user(user)
      c1 = insert_campaign_for_ad_account(aa)
      c2 = insert_campaign_for_ad_account(aa)
      s1 = insert_ad_set_for(aa, c1)
      _s2 = insert_ad_set_for(aa, c2)

      result = Ads.list_ad_sets(user, campaign_id: c1.id)
      assert length(result) == 1
      assert hd(result).id == s1.id
    end
  end

  # ---------------------------------------------------------------------------
  # list_ads/2
  # ---------------------------------------------------------------------------

  describe "list_ads/2" do
    test "user isolation" do
      user_a = insert(:user)
      user_b = insert(:user)
      aa_a = insert_ad_account_for_user(user_a)
      aa_b = insert_ad_account_for_user(user_b)
      c_a = insert_campaign_for_ad_account(aa_a)
      c_b = insert_campaign_for_ad_account(aa_b)
      s_a = insert_ad_set_for(aa_a, c_a)
      s_b = insert_ad_set_for(aa_b, c_b)
      ad_a = insert(:ad, ad_account: aa_a, ad_set: s_a)
      _ad_b = insert(:ad, ad_account: aa_b, ad_set: s_b)

      result = Ads.list_ads(user_a)
      assert length(result) == 1
      assert hd(result).id == ad_a.id
    end
  end

  # ---------------------------------------------------------------------------
  # paginate_ad_accounts/2
  # ---------------------------------------------------------------------------

  describe "paginate_ad_accounts/2" do
    test "returns correct items and total count" do
      user = insert(:user)
      for _ <- 1..3, do: insert_ad_account_for_user(user)

      {items, total} = Ads.paginate_ad_accounts(user, per_page: 2, page: 1)
      assert total == 3
      assert length(items) == 2
    end

    test "tenant isolation: user B gets empty results" do
      user_a = insert(:user)
      user_b = insert(:user)
      insert_ad_account_for_user(user_a)

      {items, total} = Ads.paginate_ad_accounts(user_b)
      assert total == 0
      assert items == []
    end
  end

  # ---------------------------------------------------------------------------
  # paginate_campaigns/2
  # ---------------------------------------------------------------------------

  describe "paginate_campaigns/2" do
    test "returns correct items and total count" do
      user = insert(:user)
      aa = insert_ad_account_for_user(user)
      for _ <- 1..3, do: insert_campaign_for_ad_account(aa)

      mc_ids = Accounts.list_meta_connection_ids_for_user(user)
      {items, total} = Ads.paginate_campaigns(mc_ids, per_page: 2, page: 1)
      assert total == 3
      assert length(items) == 2
    end

    test "tenant isolation: user B gets empty results" do
      user_a = insert(:user)
      user_b = insert(:user)
      aa_a = insert_ad_account_for_user(user_a)
      insert_campaign_for_ad_account(aa_a)

      mc_ids_b = Accounts.list_meta_connection_ids_for_user(user_b)
      {items, total} = Ads.paginate_campaigns(mc_ids_b)
      assert total == 0
      assert items == []
    end
  end

  # ---------------------------------------------------------------------------
  # paginate_ad_sets/2
  # ---------------------------------------------------------------------------

  describe "paginate_ad_sets/2" do
    test "returns correct items and total count" do
      user = insert(:user)
      aa = insert_ad_account_for_user(user)
      campaign = insert_campaign_for_ad_account(aa)
      for _ <- 1..3, do: insert_ad_set_for(aa, campaign)

      mc_ids = Accounts.list_meta_connection_ids_for_user(user)
      {items, total} = Ads.paginate_ad_sets(mc_ids, per_page: 2, page: 1)
      assert total == 3
      assert length(items) == 2
    end

    test "tenant isolation: user B gets empty results" do
      user_a = insert(:user)
      user_b = insert(:user)
      aa_a = insert_ad_account_for_user(user_a)
      campaign_a = insert_campaign_for_ad_account(aa_a)
      insert_ad_set_for(aa_a, campaign_a)

      mc_ids_b = Accounts.list_meta_connection_ids_for_user(user_b)
      {items, total} = Ads.paginate_ad_sets(mc_ids_b)
      assert total == 0
      assert items == []
    end
  end

  # ---------------------------------------------------------------------------
  # paginate_ads/2
  # ---------------------------------------------------------------------------

  describe "paginate_ads/2" do
    test "returns correct items and total count" do
      user = insert(:user)
      aa = insert_ad_account_for_user(user)
      campaign = insert_campaign_for_ad_account(aa)
      ad_set = insert_ad_set_for(aa, campaign)
      for _ <- 1..3, do: insert(:ad, ad_account: aa, ad_set: ad_set)

      mc_ids = Accounts.list_meta_connection_ids_for_user(user)
      {items, total} = Ads.paginate_ads(mc_ids, per_page: 2, page: 1)
      assert total == 3
      assert length(items) == 2
    end

    test "tenant isolation: user B gets empty results" do
      user_a = insert(:user)
      user_b = insert(:user)
      aa_a = insert_ad_account_for_user(user_a)
      campaign_a = insert_campaign_for_ad_account(aa_a)
      ad_set_a = insert_ad_set_for(aa_a, campaign_a)
      insert(:ad, ad_account: aa_a, ad_set: ad_set_a)

      mc_ids_b = Accounts.list_meta_connection_ids_for_user(user_b)
      {items, total} = Ads.paginate_ads(mc_ids_b)
      assert total == 0
      assert items == []
    end
  end
end
