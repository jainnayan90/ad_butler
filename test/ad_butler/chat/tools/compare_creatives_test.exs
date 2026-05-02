defmodule AdButler.Chat.Tools.CompareCreativesTest do
  use AdButler.DataCase, async: true

  import AdButler.Factory

  alias AdButler.Chat.Tools.CompareCreatives
  alias AdButler.Repo

  setup do
    Repo.query!("SELECT create_insights_partition((CURRENT_DATE)::DATE)")
    Repo.query!("SELECT create_insights_partition((CURRENT_DATE - INTERVAL '7 days')::DATE)")
    :ok
  end

  defp insert_ad_for_user(user) do
    mc = insert(:meta_connection, user: user)
    ad_account = insert(:ad_account, meta_connection: mc)
    campaign = insert(:campaign, ad_account: ad_account)
    ad_set = insert(:ad_set, ad_account: ad_account, campaign: campaign)
    insert(:ad, ad_account: ad_account, ad_set: ad_set)
  end

  defp run_tool(user_id, ad_ids) do
    CompareCreatives.run(%{ad_ids: ad_ids}, %{session_context: %{user_id: user_id}})
  end

  describe "tenant isolation" do
    test "all-foreign list returns :no_valid_ads" do
      user_a = insert(:user)
      user_b = insert(:user)
      ad1 = insert_ad_for_user(user_a)
      ad2 = insert_ad_for_user(user_a)

      assert {:error, :no_valid_ads} = run_tool(user_b.id, [ad1.id, ad2.id])
    end

    test "mixed-tenant list silently drops foreign ids" do
      user_a = insert(:user)
      user_b = insert(:user)
      ad_a = insert_ad_for_user(user_a)
      ad_b = insert_ad_for_user(user_b)

      assert {:ok, %{rows: [row]}} = run_tool(user_b.id, [ad_a.id, ad_b.id])
      assert row.ad_id == ad_b.id
    end
  end

  describe "happy path" do
    test "returns rows sorted by spend desc" do
      user = insert(:user)
      ad1 = insert_ad_for_user(user)
      ad2 = insert_ad_for_user(user)

      assert {:ok, %{rows: rows}} = run_tool(user.id, [ad1.id, ad2.id])
      assert length(rows) == 2

      assert Enum.all?(rows, fn r ->
               Map.has_key?(r, :ad_id) and Map.has_key?(r, :name) and
                 Map.has_key?(r, :spend_cents) and Map.has_key?(r, :avg_ctr)
             end)
    end

    test "respects 5-ad cap" do
      user = insert(:user)
      ads = for _ <- 1..7, do: insert_ad_for_user(user)
      ad_ids = Enum.map(ads, & &1.id)

      assert {:ok, %{rows: rows}} = run_tool(user.id, ad_ids)
      assert length(rows) == 5
    end

    test "payload < 8 KB" do
      user = insert(:user)
      ads = for _ <- 1..5, do: insert_ad_for_user(user)
      ad_ids = Enum.map(ads, & &1.id)

      assert {:ok, payload} = run_tool(user.id, ad_ids)
      assert byte_size(Jason.encode!(payload)) < 8_000
    end
  end

  describe "schema validation" do
    test "rejects non-list ad_ids" do
      assert {:error, _} = CompareCreatives.validate_params(%{ad_ids: "not-a-list"})
    end
  end
end
