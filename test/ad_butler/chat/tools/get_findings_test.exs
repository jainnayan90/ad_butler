defmodule AdButler.Chat.Tools.GetFindingsTest do
  use AdButler.DataCase, async: true

  import AdButler.Factory

  alias AdButler.Chat.Tools.GetFindings

  defp insert_ad_account_for_user(user) do
    mc = insert(:meta_connection, user: user)
    insert(:ad_account, meta_connection: mc)
  end

  defp insert_finding_for_user(user, opts \\ []) do
    ad_account = insert_ad_account_for_user(user)
    campaign = insert(:campaign, ad_account: ad_account)
    ad_set = insert(:ad_set, ad_account: ad_account, campaign: campaign)
    ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)

    insert(
      :finding,
      Keyword.merge(
        [ad_id: ad.id, ad_account_id: ad_account.id, kind: "dead_spend", severity: "high"],
        opts
      )
    )
  end

  defp run_tool(user_id, params \\ %{}) do
    GetFindings.run(params, %{session_context: %{user_id: user_id}})
  end

  describe "tenant isolation" do
    test "user_b sees no findings owned by user_a" do
      user_a = insert(:user)
      user_b = insert(:user)
      insert_finding_for_user(user_a)
      _ = insert_ad_account_for_user(user_b)

      assert {:ok, %{total_matching: 0, findings: []}} = run_tool(user_b.id)
    end
  end

  describe "happy path" do
    test "returns id/kind/severity/title/ad_id/inserted_at only" do
      user = insert(:user)
      _ = insert_finding_for_user(user, severity: "high", kind: "dead_spend", title: "T1")

      assert {:ok, %{total_matching: 1, findings: [row]}} = run_tool(user.id)

      assert Map.keys(row) |> Enum.sort() ==
               [:ad_id, :id, :inserted_at, :kind, :severity, :title]
    end

    test "limit > 25 is clamped" do
      user = insert(:user)
      for _ <- 1..30, do: insert_finding_for_user(user, kind: "dead_spend")

      assert {:ok, %{findings: findings}} = run_tool(user.id, %{limit: 1000})
      assert length(findings) <= 25
    end

    test "filters by severity" do
      user = insert(:user)
      _high = insert_finding_for_user(user, severity: "high")
      _low = insert_finding_for_user(user, severity: "low", kind: "creative_fatigue")

      assert {:ok, %{total_matching: 1, findings: [row]}} =
               run_tool(user.id, %{severity_filter: "high"})

      assert row.severity == "high"
    end
  end

  describe "schema validation" do
    test "validate_params/1 rejects unknown severity" do
      assert {:error, _reason} = GetFindings.validate_params(%{severity_filter: "extreme"})
    end

    test "validate_params/1 accepts valid severity" do
      assert {:ok, _} = GetFindings.validate_params(%{severity_filter: "high"})
    end
  end

  describe "payload size" do
    test "result < 8 KB even with 25 findings" do
      user = insert(:user)
      for i <- 1..30, do: insert_finding_for_user(user, kind: "dead_spend", title: "Finding #{i}")

      assert {:ok, payload} = run_tool(user.id, %{limit: 25})
      assert byte_size(Jason.encode!(payload)) < 8_000
    end
  end
end
