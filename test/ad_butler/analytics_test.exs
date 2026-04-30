defmodule AdButler.AnalyticsTest do
  use AdButler.DataCase, async: true

  import AdButler.Factory
  import AdButler.InsightsHelpers, only: [insert_daily: 3]
  import Ecto.Query

  alias AdButler.Analytics
  alias AdButler.Repo

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

  describe "compute_ctr_slope/2 / get_7d_frequency/1" do
    setup do
      # Tests below seed insights up to 14 days back; ensure partitions exist.
      Repo.query!("SELECT create_insights_partition((CURRENT_DATE - INTERVAL '7 days')::DATE)")

      Repo.query!("SELECT create_insights_partition((CURRENT_DATE - INTERVAL '14 days')::DATE)")

      :ok
    end

    test "returns negative slope (in pp/day) for declining CTR series" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)
      ad_set = insert(:ad_set, ad_account: ad_account)
      ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)

      # 5-day descending CTR: 0.06, 0.05, 0.04, 0.03, 0.02
      # Day index 0..4 (oldest first). Slope of CTR fraction = -0.01/day → -1.0 pp/day.
      Enum.each([{4, 60}, {3, 50}, {2, 40}, {1, 30}, {0, 20}], fn {days_ago, clicks} ->
        insert_daily(ad, days_ago, %{impressions: 1000, clicks: clicks})
      end)

      slope = Analytics.compute_ctr_slope(ad.id, 7)

      assert_in_delta slope, -1.0, 0.01
    end

    test "returns ~0.0 for stable CTR series" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)
      ad_set = insert(:ad_set, ad_account: ad_account)
      ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)

      Enum.each(0..4, fn d -> insert_daily(ad, d, %{impressions: 1000, clicks: 50}) end)

      slope = Analytics.compute_ctr_slope(ad.id, 7)
      assert_in_delta slope, 0.0, 0.01
    end

    test "returns 0.0 when fewer than 2 days of data exist" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)
      ad_set = insert(:ad_set, ad_account: ad_account)
      ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)

      insert_daily(ad, 0, %{impressions: 1000, clicks: 50})

      assert Analytics.compute_ctr_slope(ad.id, 7) == 0.0
    end

    test "returns 0.0 when no data exists for ad" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)
      ad_set = insert(:ad_set, ad_account: ad_account)
      ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)

      assert Analytics.compute_ctr_slope(ad.id, 7) == 0.0
    end
  end

  describe "get_7d_frequency/1" do
    setup do
      Repo.query!("SELECT create_insights_partition((CURRENT_DATE - INTERVAL '7 days')::DATE)")

      :ok
    end

    test "returns avg of populated frequency values" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)
      ad_set = insert(:ad_set, ad_account: ad_account)
      ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)

      Enum.each([{0, "4.0"}, {1, "3.0"}, {2, "5.0"}], fn {days_ago, freq} ->
        insert_daily(ad, days_ago, %{
          impressions: 1000,
          clicks: 50,
          frequency: Decimal.new(freq)
        })
      end)

      assert Analytics.get_7d_frequency(ad.id) == 4.0
    end

    test "ignores rows with nil/zero frequency" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)
      ad_set = insert(:ad_set, ad_account: ad_account)
      ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)

      insert_daily(ad, 0, %{frequency: Decimal.new("4.0")})
      insert_daily(ad, 1, %{frequency: nil})
      insert_daily(ad, 2, %{frequency: Decimal.new("0.0")})

      # Only the first row contributes to the average.
      assert Analytics.get_7d_frequency(ad.id) == 4.0
    end

    test "returns nil when no qualifying rows exist" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)
      ad_set = insert(:ad_set, ad_account: ad_account)
      ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)

      assert Analytics.get_7d_frequency(ad.id) == nil
    end

    test "ignores rows older than 7 days" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)
      ad_set = insert(:ad_set, ad_account: ad_account)
      ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)

      insert_daily(ad, 10, %{frequency: Decimal.new("9.0")})

      assert Analytics.get_7d_frequency(ad.id) == nil
    end
  end

  describe "get_cpm_change_pct/1" do
    setup do
      Repo.query!("SELECT create_insights_partition((CURRENT_DATE - INTERVAL '7 days')::DATE)")
      Repo.query!("SELECT create_insights_partition((CURRENT_DATE - INTERVAL '14 days')::DATE)")

      :ok
    end

    test "returns positive pct when recent CPM exceeds prior week" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)
      ad_set = insert(:ad_set, ad_account: ad_account)
      ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)

      # Prior week (8-14d ago): CPM = spend*1000/imps = 5000*1000/100000 = 50 cents.
      Enum.each(8..13, fn d ->
        insert_daily(ad, d, %{spend_cents: 5_000, impressions: 100_000})
      end)

      # Recent week (0-6d ago): CPM = 7500*1000/100000 = 75 cents = 50% higher.
      Enum.each(0..6, fn d ->
        insert_daily(ad, d, %{spend_cents: 7_500, impressions: 100_000})
      end)

      pct = Analytics.get_cpm_change_pct(ad.id)

      assert_in_delta pct, 50.0, 0.5
    end

    test "returns nil when prior window has no spend" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)
      ad_set = insert(:ad_set, ad_account: ad_account)
      ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)

      Enum.each(0..6, fn d ->
        insert_daily(ad, d, %{spend_cents: 7_500, impressions: 100_000})
      end)

      assert Analytics.get_cpm_change_pct(ad.id) == nil
    end

    test "returns nil when no rows at all" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)
      ad_set = insert(:ad_set, ad_account: ad_account)
      ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)

      assert Analytics.get_cpm_change_pct(ad.id) == nil
    end
  end

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
