defmodule AdButler.AnalyticsTest do
  use AdButler.DataCase, async: true

  import AdButler.Factory
  import Ecto.Query

  alias AdButler.Analytics

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp insert_ad_account_for_user(user) do
    mc = insert(:meta_connection, user: user)
    insert(:ad_account, meta_connection: mc)
  end

  defp insert_finding_for(ad_account, opts \\ []) do
    ad = insert(:ad, ad_account: ad_account, ad_set: build(:ad_set, ad_account: ad_account))

    insert(:finding,
      ad_id: ad.id,
      ad_account_id: ad_account.id,
      kind: Keyword.get(opts, :kind, "dead_spend"),
      severity: Keyword.get(opts, :severity, "high")
    )
  end

  # ---------------------------------------------------------------------------
  # paginate_findings/2
  # ---------------------------------------------------------------------------

  describe "paginate_findings/2 tenant isolation" do
    test "user_b cannot see user_a's findings" do
      user_a = insert(:user)
      user_b = insert(:user)
      aa_a = insert_ad_account_for_user(user_a)
      _aa_b = insert_ad_account_for_user(user_b)
      insert_finding_for(aa_a)

      {items, total} = Analytics.paginate_findings(user_b)
      assert items == []
      assert total == 0
    end

    test "user_a sees only their own findings" do
      user_a = insert(:user)
      user_b = insert(:user)
      aa_a = insert_ad_account_for_user(user_a)
      aa_b = insert_ad_account_for_user(user_b)
      f = insert_finding_for(aa_a)
      _f_b = insert_finding_for(aa_b)

      {items, total} = Analytics.paginate_findings(user_a)
      assert total == 1
      assert hd(items).id == f.id
    end
  end

  describe "paginate_findings/2 filters" do
    setup do
      user = insert(:user)
      aa = insert_ad_account_for_user(user)
      %{user: user, aa: aa}
    end

    test "filters by severity", %{user: user, aa: aa} do
      insert_finding_for(aa, severity: "high")
      insert_finding_for(aa, severity: "low")

      {items, total} = Analytics.paginate_findings(user, severity: "high")
      assert total == 1
      assert hd(items).severity == "high"
    end

    test "filters by kind", %{user: user, aa: aa} do
      insert_finding_for(aa, kind: "dead_spend")
      insert_finding_for(aa, kind: "cpa_explosion")

      {items, total} = Analytics.paginate_findings(user, kind: "dead_spend")
      assert total == 1
      assert hd(items).kind == "dead_spend"
    end

    test "filters by ad_account_id", %{user: user, aa: aa} do
      mc = insert(:meta_connection, user: user)
      aa2 = insert(:ad_account, meta_connection: mc)
      insert_finding_for(aa)
      insert_finding_for(aa2)

      {items, total} = Analytics.paginate_findings(user, ad_account_id: aa.id)
      assert total == 1
      assert hd(items).ad_account_id == aa.id
    end

    test "returns page 2", %{user: user, aa: aa} do
      for _ <- 1..3, do: insert_finding_for(aa)

      {items, total} = Analytics.paginate_findings(user, page: 2, per_page: 2)
      assert total == 3
      assert length(items) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # get_finding/2
  # ---------------------------------------------------------------------------

  describe "get_finding/2" do
    test "returns {:ok, finding} for owning user" do
      user = insert(:user)
      aa = insert_ad_account_for_user(user)
      finding = insert_finding_for(aa)

      assert {:ok, result} = Analytics.get_finding(user, finding.id)
      assert result.id == finding.id
    end

    test "returns {:error, :not_found} for cross-tenant access" do
      user_a = insert(:user)
      user_b = insert(:user)
      aa_a = insert_ad_account_for_user(user_a)
      _aa_b = insert_ad_account_for_user(user_b)
      finding = insert_finding_for(aa_a)

      assert {:error, :not_found} = Analytics.get_finding(user_b, finding.id)
    end

    test "returns {:error, :not_found} for nonexistent UUID" do
      user = insert(:user)
      _aa = insert_ad_account_for_user(user)

      assert {:error, :not_found} = Analytics.get_finding(user, Ecto.UUID.generate())
    end

    test "returns {:error, :not_found} for malformed UUID string" do
      user = insert(:user)
      _aa = insert_ad_account_for_user(user)

      assert {:error, :not_found} = Analytics.get_finding(user, "not-a-uuid")
    end
  end

  # ---------------------------------------------------------------------------
  # get_finding!/2
  # ---------------------------------------------------------------------------

  describe "get_finding!/2" do
    test "raises for cross-tenant access" do
      user_a = insert(:user)
      user_b = insert(:user)
      aa_a = insert_ad_account_for_user(user_a)
      _aa_b = insert_ad_account_for_user(user_b)
      finding = insert_finding_for(aa_a)

      assert_raise Ecto.NoResultsError, fn ->
        Analytics.get_finding!(user_b, finding.id)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # acknowledge_finding/2
  # ---------------------------------------------------------------------------

  describe "acknowledge_finding/2" do
    test "returns {:error, :not_found} for finding belonging to another user" do
      user_a = insert(:user)
      user_b = insert(:user)
      mc_a = insert(:meta_connection, user: user_a)
      ad_account_a = insert(:ad_account, meta_connection: mc_a)

      ad_a =
        insert(:ad, ad_account: ad_account_a, ad_set: build(:ad_set, ad_account: ad_account_a))

      finding_a = insert(:finding, ad_id: ad_a.id, ad_account_id: ad_account_a.id)

      assert {:error, :not_found} = Analytics.acknowledge_finding(user_b, finding_a.id)
    end

    test "sets acknowledged_at and acknowledged_by_user_id" do
      user = insert(:user)
      aa = insert_ad_account_for_user(user)
      finding = insert_finding_for(aa)

      {:ok, updated} = Analytics.acknowledge_finding(user, finding.id)
      assert updated.acknowledged_at != nil
      assert updated.acknowledged_by_user_id == user.id
    end

    test "re-acknowledging overwrites with current time" do
      user = insert(:user)
      aa = insert_ad_account_for_user(user)
      finding = insert_finding_for(aa)

      {:ok, first} = Analytics.acknowledge_finding(user, finding.id)
      {:ok, second} = Analytics.acknowledge_finding(user, finding.id)
      assert second.acknowledged_at != nil
      assert second.acknowledged_by_user_id == user.id
      # Both calls succeed (idempotent)
      assert first.id == second.id
    end
  end

  # ---------------------------------------------------------------------------
  # bulk_insert_health_scores/1
  # ---------------------------------------------------------------------------

  describe "bulk_insert_health_scores/1" do
    setup do
      user = insert(:user)
      mc = insert(:meta_connection, user: user)
      ad_account = insert(:ad_account, meta_connection: mc)
      campaign = insert(:campaign, ad_account: ad_account)
      ad_set = insert(:ad_set, ad_account: ad_account, campaign: campaign)
      ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)
      %{ad: ad}
    end

    test "empty list returns :ok without touching the DB" do
      assert :ok = Analytics.bulk_insert_health_scores([])
    end

    test "single entry inserts a row", %{ad: ad} do
      computed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      entry = %{
        id: Ecto.UUID.generate(),
        ad_id: ad.id,
        computed_at: computed_at,
        leak_score: Decimal.new("40"),
        leak_factors: %{},
        inserted_at: now
      }

      assert :ok = Analytics.bulk_insert_health_scores([entry])
      assert AdButler.Repo.aggregate(AdButler.Analytics.AdHealthScore, :count) == 1
    end

    test "same (ad_id, computed_at) upserts instead of inserting a duplicate", %{ad: ad} do
      computed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      entry = %{
        id: Ecto.UUID.generate(),
        ad_id: ad.id,
        computed_at: computed_at,
        leak_score: Decimal.new("30"),
        leak_factors: %{},
        inserted_at: now
      }

      assert :ok = Analytics.bulk_insert_health_scores([entry])
      assert :ok = Analytics.bulk_insert_health_scores([%{entry | leak_score: Decimal.new("50")}])

      assert AdButler.Repo.aggregate(AdButler.Analytics.AdHealthScore, :count) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # unsafe_list_open_finding_keys/1
  # ---------------------------------------------------------------------------

  describe "unsafe_list_open_finding_keys/1" do
    test "empty list returns empty MapSet" do
      assert Analytics.unsafe_list_open_finding_keys([]) == MapSet.new()
    end

    test "open findings return {ad_id, kind} tuples" do
      user = insert(:user)
      aa = insert_ad_account_for_user(user)
      f1 = insert_finding_for(aa, kind: "dead_spend")
      f2 = insert_finding_for(aa, kind: "cpa_explosion")

      result = Analytics.unsafe_list_open_finding_keys([f1.ad_id, f2.ad_id])

      assert MapSet.member?(result, {f1.ad_id, "dead_spend"})
      assert MapSet.member?(result, {f2.ad_id, "cpa_explosion"})
    end

    test "resolved findings are excluded" do
      user = insert(:user)
      aa = insert_ad_account_for_user(user)
      finding = insert_finding_for(aa, kind: "dead_spend")

      AdButler.Repo.update_all(
        from(f in AdButler.Analytics.Finding, where: f.id == ^finding.id),
        set: [resolved_at: DateTime.utc_now()]
      )

      result = Analytics.unsafe_list_open_finding_keys([finding.ad_id])
      refute MapSet.member?(result, {finding.ad_id, "dead_spend"})
    end

    test "ad_id not in input is excluded even if open finding exists" do
      user = insert(:user)
      aa = insert_ad_account_for_user(user)
      finding = insert_finding_for(aa, kind: "dead_spend")
      other_ad_id = Ecto.UUID.generate()

      result = Analytics.unsafe_list_open_finding_keys([other_ad_id])
      refute MapSet.member?(result, {finding.ad_id, "dead_spend"})
    end
  end

  # ---------------------------------------------------------------------------
  # get_unresolved_finding/2
  # ---------------------------------------------------------------------------

  describe "get_unresolved_finding/2" do
    test "returns nil when no open finding exists" do
      assert Analytics.get_unresolved_finding(Ecto.UUID.generate(), "dead_spend") == nil
    end

    test "returns existing open finding" do
      user = insert(:user)
      aa = insert_ad_account_for_user(user)
      finding = insert_finding_for(aa, kind: "dead_spend")

      result = Analytics.get_unresolved_finding(finding.ad_id, "dead_spend")
      assert result.id == finding.id
    end

    test "returns nil after finding is resolved" do
      user = insert(:user)
      aa = insert_ad_account_for_user(user)
      finding = insert_finding_for(aa, kind: "dead_spend")

      AdButler.Repo.update_all(
        from(f in AdButler.Analytics.Finding, where: f.id == ^finding.id),
        set: [resolved_at: DateTime.utc_now()]
      )

      assert Analytics.get_unresolved_finding(finding.ad_id, "dead_spend") == nil
    end
  end
end
