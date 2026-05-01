defmodule AdButler.AnalyticsInsightsTest do
  @moduledoc """
  Analytics tests that touch `insights_daily` partitions via the
  non-transactional `create_insights_partition` DDL function. Lifted out of
  `analytics_test.exs` (which is `async: true`) because the DDL races with
  parallel async tests creating the same partition.

  Carries forward from week 7 — see week 7/8 review notes (S6).
  """
  use AdButler.DataCase, async: false

  import AdButler.Factory
  import AdButler.InsightsHelpers, only: [insert_daily: 3]

  alias AdButler.Analytics
  alias AdButler.Repo

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

      assert_in_delta Analytics.get_7d_frequency(ad.id), 4.0, 0.0001
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
      assert_in_delta Analytics.get_7d_frequency(ad.id), 4.0, 0.0001
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

  describe "get_ad_honeymoon_baseline/1" do
    setup do
      Repo.query!("SELECT create_insights_partition((CURRENT_DATE - INTERVAL '7 days')::DATE)")
      Repo.query!("SELECT create_insights_partition((CURRENT_DATE - INTERVAL '14 days')::DATE)")
      Repo.query!("SELECT create_insights_partition((CURRENT_DATE - INTERVAL '21 days')::DATE)")

      :ok
    end

    test "returns avg CTR over the first 3 days with > 1000 impressions" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)
      ad_set = insert(:ad_set, ad_account: ad_account)
      ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)

      # First 3 qualifying days (oldest first, 14/13/12d ago):
      #   imps 2000/2000/2000, clicks 60/40/50 → CTR = 150 / 6000 = 0.025
      # Days 11/10 (2000 imps) come AFTER honeymoon and must not affect avg.
      insert_daily(ad, 14, %{impressions: 2_000, clicks: 60})
      insert_daily(ad, 13, %{impressions: 2_000, clicks: 40})
      insert_daily(ad, 12, %{impressions: 2_000, clicks: 50})
      insert_daily(ad, 11, %{impressions: 2_000, clicks: 100})

      assert {:ok, %{baseline_ctr: ctr, window_dates: dates}} =
               Analytics.get_ad_honeymoon_baseline(ad.id)

      assert_in_delta ctr, 0.025, 0.0001
      assert length(dates) == 3
      assert Enum.sort(dates) == dates
    end

    test "skips days at or below 1000 impressions when picking the window" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)
      ad_set = insert(:ad_set, ad_account: ad_account)
      ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)

      # 14/13d ago: under threshold (skipped). 12/11/10d ago: qualifying days.
      insert_daily(ad, 14, %{impressions: 500, clicks: 50})
      insert_daily(ad, 13, %{impressions: 1_000, clicks: 50})
      insert_daily(ad, 12, %{impressions: 2_000, clicks: 40})
      insert_daily(ad, 11, %{impressions: 2_000, clicks: 60})
      insert_daily(ad, 10, %{impressions: 2_000, clicks: 50})

      assert {:ok, %{baseline_ctr: ctr, window_dates: dates}} =
               Analytics.get_ad_honeymoon_baseline(ad.id)

      assert_in_delta ctr, 150 / 6_000, 0.0001
      today = Date.utc_today()
      assert dates == [Date.add(today, -12), Date.add(today, -11), Date.add(today, -10)]
    end

    test "returns :insufficient_data with fewer than 3 qualifying days" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)
      ad_set = insert(:ad_set, ad_account: ad_account)
      ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)

      insert_daily(ad, 5, %{impressions: 1_500, clicks: 50})
      insert_daily(ad, 4, %{impressions: 1_500, clicks: 50})

      assert {:error, :insufficient_data} = Analytics.get_ad_honeymoon_baseline(ad.id)
    end

    test "returns :insufficient_data with no insights" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)
      ad_set = insert(:ad_set, ad_account: ad_account)
      ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)

      assert {:error, :insufficient_data} = Analytics.get_ad_honeymoon_baseline(ad.id)
    end

    test "reads the cached baseline from the latest health score's metadata" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)
      ad_set = insert(:ad_set, ad_account: ad_account)
      ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)

      cached_dates = [
        Date.add(Date.utc_today(), -20),
        Date.add(Date.utc_today(), -19),
        Date.add(Date.utc_today(), -18)
      ]

      :ok =
        Analytics.bulk_insert_fatigue_scores([
          %{
            ad_id: ad.id,
            computed_at: DateTime.utc_now(),
            fatigue_score: Decimal.new("0.0"),
            fatigue_factors: %{},
            metadata: %{
              "honeymoon_baseline" => %{
                "baseline_ctr" => 0.0321,
                "window_dates" => Enum.map(cached_dates, &Date.to_iso8601/1)
              }
            },
            inserted_at: DateTime.utc_now()
          }
        ])

      # NO insights_daily rows seeded — proves the cache is used.
      assert {:ok, %{baseline_ctr: ctr, window_dates: dates}} =
               Analytics.get_ad_honeymoon_baseline(ad.id)

      assert_in_delta ctr, 0.0321, 0.00001
      assert dates == cached_dates
    end

    test "ignores malformed cached metadata and recomputes" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)
      ad_set = insert(:ad_set, ad_account: ad_account)
      ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)

      # Cache says window_dates is a string instead of a list — should be ignored.
      :ok =
        Analytics.bulk_insert_fatigue_scores([
          %{
            ad_id: ad.id,
            computed_at: DateTime.utc_now(),
            fatigue_score: Decimal.new("0.0"),
            fatigue_factors: %{},
            metadata: %{"honeymoon_baseline" => %{"baseline_ctr" => "not-a-number"}},
            inserted_at: DateTime.utc_now()
          }
        ])

      insert_daily(ad, 14, %{impressions: 2_000, clicks: 50})
      insert_daily(ad, 13, %{impressions: 2_000, clicks: 50})
      insert_daily(ad, 12, %{impressions: 2_000, clicks: 50})

      assert {:ok, %{baseline_ctr: ctr}} = Analytics.get_ad_honeymoon_baseline(ad.id)
      assert_in_delta ctr, 0.025, 0.0001
    end
  end

  describe "fit_ctr_regression/1" do
    setup do
      Enum.each([7, 14, 21], fn d ->
        Repo.query!(
          "SELECT create_insights_partition((CURRENT_DATE - INTERVAL '#{d} days')::DATE)"
        )
      end)

      :ok
    end

    test "declining series: negative slope, high r², projected CTR within tolerance" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)
      ad_set = insert(:ad_set, ad_account: ad_account)
      ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)

      # 14 days. CTR depends linearly on day_index: CTR = 0.05 - 0.002 * d.
      # Frequency follows a non-linear pattern (sin-like) so it isn't
      # collinear with day_index — otherwise XᵀX is singular.
      # Reach varies non-uniformly so cumulative_reach has its own profile.
      reaches = [800, 1100, 950, 1200, 1050, 900, 1300, 1000, 1150, 1250, 1050, 1100, 950, 1200]

      freqs = [1.0, 1.5, 1.2, 1.8, 1.3, 2.0, 1.4, 1.9, 1.6, 2.1, 1.7, 2.2, 1.5, 2.3]

      Enum.zip([reaches, freqs, 0..13])
      |> Enum.each(fn {reach, freq, d_index} ->
        days_ago = 13 - d_index
        impressions = 10_000
        # CTR target: 0.05 - 0.002 * d_index → clicks = imps * CTR
        ctr_target = 0.05 - 0.002 * d_index
        clicks = round(impressions * ctr_target)

        insert_daily(ad, days_ago, %{
          impressions: impressions,
          clicks: clicks,
          reach_count: reach,
          frequency: Decimal.from_float(Float.round(freq, 4))
        })
      end)

      assert {:ok, %{slope_per_day: slope, r_squared: r2, projected_ctr_3d: proj}} =
               Analytics.fit_ctr_regression(ad.id)

      # Series is near-perfectly linear in day_index → r² should be very close to 1.
      assert r2 > 0.99

      # Combined slope-per-day across all features should reflect the dominant
      # day_index effect (≈ -0.002). Some of the trend may be absorbed by the
      # collinear frequency feature, so allow a wide tolerance — but require a
      # meaningful negative slope, not a vanishing one (P4-T7).
      assert slope < -0.001

      # Projected at d=16 (= 13 + 3) on the underlying line: 0.05 - 0.002*16 = 0.018.
      assert_in_delta proj, 0.018, 0.005
    end

    test "stable series: ~zero slope, projected CTR near observed mean" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)
      ad_set = insert(:ad_set, ad_account: ad_account)
      ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)

      Enum.each(0..13, fn d_index ->
        days_ago = 13 - d_index

        insert_daily(ad, days_ago, %{
          impressions: 10_000,
          # Constant 300 clicks → CTR exactly 0.03 every day.
          clicks: 300,
          reach_count: 1000 + rem(d_index, 5) * 50,
          frequency: Decimal.from_float(2.0 + rem(d_index, 3) * 0.1)
        })
      end)

      assert {:ok, %{slope_per_day: slope, r_squared: r2, projected_ctr_3d: proj}} =
               Analytics.fit_ctr_regression(ad.id)

      # Constant CTR → ss_tot is 0 → r² is clamped to 0.
      assert r2 == 0.0
      assert_in_delta slope, 0.0, 1.0e-6
      assert_in_delta proj, 0.03, 0.005
    end

    test "noisy series: low r²" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)
      ad_set = insert(:ad_set, ad_account: ad_account)
      ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)

      # Deterministic but high-variance CTRs around 0.03 — alternating 0.02 / 0.04 / 0.025…
      ctrs = [
        0.02,
        0.04,
        0.025,
        0.045,
        0.022,
        0.038,
        0.028,
        0.041,
        0.024,
        0.043,
        0.027,
        0.039,
        0.026,
        0.042
      ]

      Enum.with_index(ctrs)
      |> Enum.each(fn {ctr, d_index} ->
        days_ago = 13 - d_index
        impressions = 10_000
        clicks = round(impressions * ctr)
        freq = 1.0 + rem(d_index, 4) * 0.3

        insert_daily(ad, days_ago, %{
          impressions: impressions,
          clicks: clicks,
          reach_count: 1000 + rem(d_index * 7, 500),
          frequency: Decimal.from_float(Float.round(freq, 4))
        })
      end)

      assert {:ok, %{r_squared: r2}} = Analytics.fit_ctr_regression(ad.id)

      # Zig-zag pattern around 0.03 with no underlying day_index trend → low r².
      assert r2 < 0.5
    end

    test "returns :insufficient_data when fewer than 10 usable days exist" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)
      ad_set = insert(:ad_set, ad_account: ad_account)
      ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)

      Enum.each(0..8, fn d ->
        insert_daily(ad, d, %{impressions: 1_000, clicks: 30, reach_count: 500})
      end)

      assert {:error, :insufficient_data} = Analytics.fit_ctr_regression(ad.id)
    end

    test "skips rows with zero impressions when counting usable days" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)
      ad_set = insert(:ad_set, ad_account: ad_account)
      ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)

      # 11 rows but 2 with zero impressions → only 9 usable.
      Enum.each(0..10, fn d ->
        impressions = if d in [3, 7], do: 0, else: 1_000
        clicks = if impressions == 0, do: 0, else: 30
        insert_daily(ad, d, %{impressions: impressions, clicks: clicks, reach_count: 500})
      end)

      assert {:error, :insufficient_data} = Analytics.fit_ctr_regression(ad.id)
    end
  end
end
