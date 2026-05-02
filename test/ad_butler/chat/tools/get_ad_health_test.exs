defmodule AdButler.Chat.Tools.GetAdHealthTest do
  use AdButler.DataCase, async: true

  import AdButler.Factory

  alias AdButler.Chat.Tools.{GetAdHealth, Helpers}

  defp insert_ad_for_user(user, opts \\ []) do
    mc = insert(:meta_connection, user: user)
    ad_account = insert(:ad_account, meta_connection: mc)
    campaign = insert(:campaign, ad_account: ad_account)
    ad_set = insert(:ad_set, ad_account: ad_account, campaign: campaign)

    insert(
      :ad,
      Keyword.merge(
        [ad_account: ad_account, ad_set: ad_set, name: "Ad A", status: "ACTIVE"],
        opts
      )
    )
  end

  defp run_tool(user_id, ad_id) do
    GetAdHealth.run(%{ad_id: ad_id}, %{session_context: %{user_id: user_id}})
  end

  describe "tenant isolation" do
    test "user_b cannot see user_a's ad — returns :not_found" do
      user_a = insert(:user)
      user_b = insert(:user)
      _mc_b = insert(:meta_connection, user: user_b)
      ad = insert_ad_for_user(user_a)

      assert {:error, :not_found} = run_tool(user_b.id, ad.id)
    end

    test "missing session_context returns :missing_session_context" do
      user = insert(:user)
      ad = insert_ad_for_user(user)

      assert {:error, :missing_session_context} = GetAdHealth.run(%{ad_id: ad.id}, %{})
    end
  end

  describe "happy path" do
    test "returns the expected payload shape" do
      user = insert(:user)
      ad = insert_ad_for_user(user, name: "Cool Ad")

      assert {:ok, payload} = run_tool(user.id, ad.id)

      assert %{
               ad_id: id,
               name: "Cool Ad",
               status: "ACTIVE",
               fatigue_score: _,
               leak_score: _,
               latest_findings: findings,
               latest_finding_summary: _summary
             } = payload

      assert id == ad.id
      assert is_list(findings)
    end

    test "payload < 4 KB serialised JSON" do
      user = insert(:user)
      ad = insert_ad_for_user(user)

      assert {:ok, payload} = run_tool(user.id, ad.id)
      assert byte_size(Jason.encode!(payload)) < 4_000
    end

    test "syntactically valid but non-existent UUID returns :not_found" do
      user = insert(:user)

      assert {:error, :not_found} = run_tool(user.id, "00000000-0000-0000-0000-000000000000")
    end

    test "non-uuid string returns :not_found (no leak via cast error)" do
      user = insert(:user)
      assert {:error, :not_found} = run_tool(user.id, "not-a-uuid")
    end
  end

  describe "schema validation" do
    test "missing required ad_id is rejected by validate_params/1" do
      assert {:error, _reason} = GetAdHealth.validate_params(%{})
    end

    test "valid params pass validate_params/1" do
      assert {:ok, %{ad_id: "abc"}} = GetAdHealth.validate_params(%{ad_id: "abc"})
    end
  end

  describe "Helpers.decimal_to_float/1 fall-through" do
    test "returns nil for unexpected input instead of raising" do
      assert Helpers.decimal_to_float("not a number") == nil
      assert Helpers.decimal_to_float(:atom) == nil
    end
  end

  describe "truncate/2 safety" do
    test "returns nil for non-encodable maps instead of raising" do
      # `self()` is a pid — Jason cannot encode it. The previous Jason.encode!
      # implementation would crash the GenServer turn; the safe variant must
      # return nil so the calling payload remains shippable.
      non_encodable = %{trap: self()}

      assert GetAdHealth.truncate(non_encodable, 100) == nil
    end

    test "encodes a normal map and slices it to len bytes" do
      assert GetAdHealth.truncate(%{a: 1, b: 2}, 1_000) =~ ~r/^\{/
      assert byte_size(GetAdHealth.truncate(%{a: 1, b: 2}, 5)) <= 5
    end

    test "returns nil for nil input" do
      assert GetAdHealth.truncate(nil, 100) == nil
    end
  end
end
