defmodule AdButler.Workers.CreativeFatiguePredictorWorkerTest do
  # async: false — setup blocks call `create_insights_partition` (DDL), which is
  # not transactional in Postgres and races under concurrent sandbox checkouts.
  use AdButler.DataCase, async: false
  use Oban.Testing, repo: AdButler.Repo

  import AdButler.Factory
  import AdButler.InsightsHelpers, only: [insert_daily: 3]
  import Ecto.Query

  alias AdButler.Repo
  alias AdButler.Workers.CreativeFatiguePredictorWorker

  describe "perform/1 — scaffold" do
    test "returns :ok for a valid ad account" do
      mc = insert(:meta_connection)
      aa = insert(:ad_account, meta_connection: mc)

      assert :ok =
               perform_job(CreativeFatiguePredictorWorker, %{"ad_account_id" => aa.id})
    end

    test "returns :ok and logs when ad account is missing" do
      assert :ok =
               perform_job(CreativeFatiguePredictorWorker, %{
                 "ad_account_id" => Ecto.UUID.generate()
               })
    end
  end

  describe "Oban uniqueness" do
    test "second insert for the same ad_account_id within 6h is a unique conflict" do
      mc = insert(:meta_connection)
      aa = insert(:ad_account, meta_connection: mc)
      args = %{"ad_account_id" => aa.id}

      {:ok, _job1} = args |> CreativeFatiguePredictorWorker.new() |> Oban.insert()
      {:ok, job2} = args |> CreativeFatiguePredictorWorker.new() |> Oban.insert()

      assert job2.conflict? == true

      assert Repo.aggregate(
               from(j in Oban.Job,
                 where: j.worker == "AdButler.Workers.CreativeFatiguePredictorWorker",
                 where: fragment("? @> ?", j.args, ^args)
               ),
               :count
             ) == 1
    end

    test "different ad_account_ids do not collide" do
      mc1 = insert(:meta_connection)
      mc2 = insert(:meta_connection)
      aa1 = insert(:ad_account, meta_connection: mc1)
      aa2 = insert(:ad_account, meta_connection: mc2)

      {:ok, j1} =
        %{"ad_account_id" => aa1.id} |> CreativeFatiguePredictorWorker.new() |> Oban.insert()

      {:ok, j2} =
        %{"ad_account_id" => aa2.id} |> CreativeFatiguePredictorWorker.new() |> Oban.insert()

      refute j1.conflict?
      refute j2.conflict?
    end
  end

  describe "heuristic_frequency_ctr_decay/1" do
    setup do
      Repo.query!("SELECT create_insights_partition((CURRENT_DATE - INTERVAL '7 days')::DATE)")

      :ok
    end

    test "fires when frequency > 3.5 AND ctr_slope < -0.1" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)
      ad_set = insert(:ad_set, ad_account: ad_account)
      ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)

      # High frequency
      Enum.each(0..6, fn d ->
        insert_daily(ad, d, %{frequency: Decimal.new("4.5"), impressions: 1000, clicks: 50})
      end)

      # Re-seed with a steep declining CTR over the same 7 days
      Repo.delete_all(
        from i in "insights_daily",
          where: i.ad_id == type(^ad.id, :binary_id)
      )

      Enum.each(0..6, fn d ->
        # Day d ago. Newer days (d=0) have lower CTR.
        clicks = 80 - (6 - d) * 10
        insert_daily(ad, d, %{frequency: Decimal.new("4.5"), impressions: 1000, clicks: clicks})
      end)

      assert {:emit, %{frequency: freq, ctr_slope: slope}} =
               CreativeFatiguePredictorWorker.heuristic_frequency_ctr_decay(ad.id)

      assert freq > 3.5
      assert slope < -0.1
    end

    test "skips when frequency is below threshold" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)
      ad_set = insert(:ad_set, ad_account: ad_account)
      ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)

      Enum.each(0..6, fn d ->
        clicks = 80 - (6 - d) * 10
        insert_daily(ad, d, %{frequency: Decimal.new("2.0"), impressions: 1000, clicks: clicks})
      end)

      assert :skip = CreativeFatiguePredictorWorker.heuristic_frequency_ctr_decay(ad.id)
    end

    test "skips when CTR slope is flat" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)
      ad_set = insert(:ad_set, ad_account: ad_account)
      ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)

      Enum.each(0..6, fn d ->
        insert_daily(ad, d, %{frequency: Decimal.new("4.5"), impressions: 1000, clicks: 50})
      end)

      assert :skip = CreativeFatiguePredictorWorker.heuristic_frequency_ctr_decay(ad.id)
    end

    test "skips when no usable data exists" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)
      ad_set = insert(:ad_set, ad_account: ad_account)
      ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)

      assert :skip = CreativeFatiguePredictorWorker.heuristic_frequency_ctr_decay(ad.id)
    end
  end

  describe "heuristic_quality_drop/1" do
    defp put_history(ad, snapshots) do
      AdButler.Repo.update_all(
        from(a in AdButler.Ads.Ad, where: a.id == ^ad.id),
        set: [quality_ranking_history: %{"snapshots" => snapshots}]
      )
    end

    defp snap(days_ago, qr) do
      %{
        "date" => Date.add(Date.utc_today(), -days_ago) |> Date.to_iso8601(),
        "quality_ranking" => qr,
        "engagement_rate_ranking" => qr,
        "conversion_rate_ranking" => qr
      }
    end

    test "fires when ranking dropped from above_average to average within 7 days" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)
      ad_set = insert(:ad_set, ad_account: ad_account)
      ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)

      put_history(ad, [snap(5, "above_average"), snap(0, "average")])

      assert {:emit, %{from: "above_average", to: "average", from_date: _}} =
               CreativeFatiguePredictorWorker.heuristic_quality_drop(ad.id)
    end

    test "skips when ranking is stable" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)
      ad_set = insert(:ad_set, ad_account: ad_account)
      ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)

      put_history(ad, [snap(5, "average"), snap(0, "average")])

      assert :skip = CreativeFatiguePredictorWorker.heuristic_quality_drop(ad.id)
    end

    test "skips when no history yet" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)
      ad_set = insert(:ad_set, ad_account: ad_account)
      ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)

      assert :skip = CreativeFatiguePredictorWorker.heuristic_quality_drop(ad.id)
    end
  end

  describe "heuristic_cpm_saturation/1" do
    setup do
      Repo.query!("SELECT create_insights_partition((CURRENT_DATE - INTERVAL '7 days')::DATE)")
      Repo.query!("SELECT create_insights_partition((CURRENT_DATE - INTERVAL '14 days')::DATE)")

      :ok
    end

    test "fires when CPM jumped > 20% week over week" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)
      ad_set = insert(:ad_set, ad_account: ad_account)
      ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)

      Enum.each(8..13, fn d ->
        insert_daily(ad, d, %{impressions: 100_000})
      end)

      # Prior CPM = 5000*1000/100000=50; recent = 75 → +50%.
      Enum.each(8..13, fn d ->
        Repo.update_all(
          from(i in "insights_daily",
            where:
              i.ad_id == type(^ad.id, :binary_id) and
                i.date_start == ^Date.add(Date.utc_today(), -d)
          ),
          set: [spend_cents: 5_000]
        )
      end)

      Enum.each(0..6, fn d ->
        insert_daily(ad, d, %{impressions: 100_000, clicks: 0, frequency: nil})
      end)

      Enum.each(0..6, fn d ->
        Repo.update_all(
          from(i in "insights_daily",
            where:
              i.ad_id == type(^ad.id, :binary_id) and
                i.date_start == ^Date.add(Date.utc_today(), -d)
          ),
          set: [spend_cents: 7_500]
        )
      end)

      assert {:emit, %{cpm_change_pct: pct}} =
               CreativeFatiguePredictorWorker.heuristic_cpm_saturation(ad.id)

      assert pct > 20.0
    end

    test "skips when CPM change is within +/-20%" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)
      ad_set = insert(:ad_set, ad_account: ad_account)
      ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)

      # Equal CPM both windows
      Enum.each(0..13, fn d ->
        insert_daily(ad, d, %{spend_cents: 5_000, impressions: 100_000})
      end)

      assert :skip = CreativeFatiguePredictorWorker.heuristic_cpm_saturation(ad.id)
    end
  end

  describe "perform/1 — integration (scoring + findings)" do
    setup do
      Repo.query!("SELECT create_insights_partition((CURRENT_DATE - INTERVAL '7 days')::DATE)")
      Repo.query!("SELECT create_insights_partition((CURRENT_DATE - INTERVAL '14 days')::DATE)")

      :ok
    end

    test "single fired heuristic writes fatigue_score below the finding threshold" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)
      ad_set = insert(:ad_set, ad_account: ad_account)
      ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)

      # Frequency + CTR decay only (weight 35) — below 50 threshold.
      Enum.each(0..6, fn d ->
        clicks = 80 - (6 - d) * 10
        insert_daily(ad, d, %{frequency: Decimal.new("4.5"), impressions: 1000, clicks: clicks})
      end)

      assert :ok =
               perform_job(CreativeFatiguePredictorWorker, %{"ad_account_id" => ad_account.id})

      assert [%{fatigue_score: score, fatigue_factors: factors}] =
               Repo.all(from s in AdButler.Analytics.AdHealthScore, where: s.ad_id == ^ad.id)

      assert Decimal.equal?(score, 35)
      assert Map.has_key?(factors, "frequency_ctr_decay")

      # No finding because score < 50.
      assert Repo.aggregate(
               from(f in AdButler.Analytics.Finding, where: f.ad_id == ^ad.id),
               :count
             ) == 0
    end

    test "two heuristics together emit a finding with merged severity" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)
      ad_set = insert(:ad_set, ad_account: ad_account)
      ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)

      # Heuristic 1: frequency+CTR decay (35)
      Enum.each(0..6, fn d ->
        clicks = 80 - (6 - d) * 10
        insert_daily(ad, d, %{frequency: Decimal.new("4.5"), impressions: 1000, clicks: clicks})
      end)

      # Heuristic 2: quality drop (30) — write history directly
      Repo.update_all(
        from(a in AdButler.Ads.Ad, where: a.id == ^ad.id),
        set: [
          quality_ranking_history: %{
            "snapshots" => [
              %{
                "date" => Date.add(Date.utc_today(), -5) |> Date.to_iso8601(),
                "quality_ranking" => "above_average"
              },
              %{
                "date" => Date.utc_today() |> Date.to_iso8601(),
                "quality_ranking" => "average"
              }
            ]
          }
        ]
      )

      assert :ok =
               perform_job(CreativeFatiguePredictorWorker, %{"ad_account_id" => ad_account.id})

      assert [%{fatigue_score: score, fatigue_factors: factors}] =
               Repo.all(from s in AdButler.Analytics.AdHealthScore, where: s.ad_id == ^ad.id)

      assert Decimal.equal?(score, 65)
      assert Map.has_key?(factors, "frequency_ctr_decay")
      assert Map.has_key?(factors, "quality_drop")

      # 65 → medium severity.
      assert [%{kind: "creative_fatigue", severity: "medium"}] =
               Repo.all(from f in AdButler.Analytics.Finding, where: f.ad_id == ^ad.id)
    end

    test "all three signals together hit cap (90) and produce a high-severity finding" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)
      ad_set = insert(:ad_set, ad_account: ad_account)
      ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)

      # Recent week (0..6): high frequency + declining CTR + recent CPM 75¢.
      # d=0 is today (newer); d=6 is six days ago (older). Older days have more
      # clicks → CTR drops over time → slope ≈ -1 pp/day, below -0.1 threshold.
      Enum.each(0..6, fn d ->
        clicks = 2_000 + d * 1_000

        insert_daily(ad, d, %{
          frequency: Decimal.new("4.5"),
          impressions: 100_000,
          clicks: clicks,
          spend_cents: 7_500
        })
      end)

      # Prior week (7..13d ago): CPM 50¢ baseline.
      Enum.each(7..13, fn d ->
        insert_daily(ad, d, %{spend_cents: 5_000, impressions: 100_000})
      end)

      # H2: quality drop (30).
      Repo.update_all(
        from(a in AdButler.Ads.Ad, where: a.id == ^ad.id),
        set: [
          quality_ranking_history: %{
            "snapshots" => [
              %{
                "date" => Date.add(Date.utc_today(), -5) |> Date.to_iso8601(),
                "quality_ranking" => "above_average"
              },
              %{
                "date" => Date.utc_today() |> Date.to_iso8601(),
                "quality_ranking" => "below_average_10_percent"
              }
            ]
          }
        ]
      )

      assert :ok =
               perform_job(CreativeFatiguePredictorWorker, %{"ad_account_id" => ad_account.id})

      assert [%{fatigue_score: score, fatigue_factors: factors}] =
               Repo.all(from s in AdButler.Analytics.AdHealthScore, where: s.ad_id == ^ad.id)

      # 35 + 30 + 25 = 90 (capped at 100 anyway)
      assert Decimal.equal?(score, 90)
      assert Map.has_key?(factors, "frequency_ctr_decay")
      assert Map.has_key?(factors, "quality_drop")
      assert Map.has_key?(factors, "cpm_saturation")

      assert [%{kind: "creative_fatigue", severity: "high"}] =
               Repo.all(from f in AdButler.Analytics.Finding, where: f.ad_id == ^ad.id)
    end

    test "second run dedups finding by (ad_id, kind)" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)
      ad_set = insert(:ad_set, ad_account: ad_account)
      ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)

      Enum.each(0..6, fn d ->
        clicks = 80 - (6 - d) * 10
        insert_daily(ad, d, %{frequency: Decimal.new("4.5"), impressions: 1000, clicks: clicks})
      end)

      Repo.update_all(
        from(a in AdButler.Ads.Ad, where: a.id == ^ad.id),
        set: [
          quality_ranking_history: %{
            "snapshots" => [
              %{
                "date" => Date.add(Date.utc_today(), -5) |> Date.to_iso8601(),
                "quality_ranking" => "above_average"
              },
              %{
                "date" => Date.utc_today() |> Date.to_iso8601(),
                "quality_ranking" => "average"
              }
            ]
          }
        ]
      )

      assert :ok =
               perform_job(CreativeFatiguePredictorWorker, %{"ad_account_id" => ad_account.id})

      assert :ok =
               perform_job(CreativeFatiguePredictorWorker, %{"ad_account_id" => ad_account.id})

      assert Repo.aggregate(
               from(f in AdButler.Analytics.Finding,
                 where: f.ad_id == ^ad.id and f.kind == "creative_fatigue"
               ),
               :count
             ) == 1
    end
  end

  describe "tenant isolation" do
    setup do
      Repo.query!("SELECT create_insights_partition((CURRENT_DATE - INTERVAL '7 days')::DATE)")
      Repo.query!("SELECT create_insights_partition((CURRENT_DATE - INTERVAL '14 days')::DATE)")
      :ok
    end

    # Account A: ads with insights but NO triggering signals (frequency 1.0,
    #   stable CTR, no CPM growth, no quality drop).
    # Account B: ads loaded with all 3 firing signals — but the worker is
    #   invoked for account A only. Asserting zero Finding/AdHealthScore rows
    #   for account B's ads proves the scope filter actually filters, rather
    #   than passing by absence of any data on account B.
    test "perform/1 for account A leaves account B's firing-signal ads untouched" do
      mc_a = insert(:meta_connection)
      mc_b = insert(:meta_connection)
      account_a = insert(:ad_account, meta_connection: mc_a)
      account_b = insert(:ad_account, meta_connection: mc_b)
      ad_set_a = insert(:ad_set, ad_account: account_a)
      ad_set_b = insert(:ad_set, ad_account: account_b)
      ad_a = insert(:ad, ad_account: account_a, ad_set: ad_set_a)
      ad_b = insert(:ad, ad_account: account_b, ad_set: ad_set_b)

      # Account A: clean — frequency 1.0, flat CTR, no CPM growth.
      Enum.each(0..13, fn d ->
        insert_daily(ad_a, d, %{
          frequency: Decimal.new("1.0"),
          impressions: 1000,
          clicks: 50,
          spend_cents: 1_000
        })
      end)

      # Account B: would fire all 3 heuristics if audited.
      # Recent 7d: high frequency, declining CTR, and high CPM (75 cents).
      # `clicks = 80 - (6 - d) * 10` puts d=0 (today) at 20 clicks and d=6
      # (6 days ago) at 80, so OLS sorted oldest→newest is descending and
      # `heuristic_frequency_ctr_decay` fires for ad_b.
      Enum.each(0..6, fn d ->
        clicks = 80 - (6 - d) * 10

        insert_daily(ad_b, d, %{
          frequency: Decimal.new("4.5"),
          impressions: 100_000,
          clicks: clicks,
          spend_cents: 7_500
        })
      end)

      # Prior 7d: low CPM (50 cents) so recent week is +50% — saturation fires.
      Enum.each(8..13, fn d ->
        insert_daily(ad_b, d, %{spend_cents: 5_000, impressions: 100_000})
      end)

      # Quality drop: above_average → average within the lookback window.
      Repo.update_all(
        from(a in AdButler.Ads.Ad, where: a.id == ^ad_b.id),
        set: [
          quality_ranking_history: %{
            "snapshots" => [
              %{
                "date" => Date.add(Date.utc_today(), -5) |> Date.to_iso8601(),
                "quality_ranking" => "above_average"
              },
              %{
                "date" => Date.utc_today() |> Date.to_iso8601(),
                "quality_ranking" => "average"
              }
            ]
          }
        ]
      )

      # Run audit for account A only.
      assert :ok =
               perform_job(CreativeFatiguePredictorWorker, %{"ad_account_id" => account_a.id})

      # Account B's ad has all 3 firing signals but should not be scored or flagged.
      score_count_b =
        Repo.aggregate(
          from(s in AdButler.Analytics.AdHealthScore, where: s.ad_id == ^ad_b.id),
          :count
        )

      finding_count_b =
        Repo.aggregate(
          from(f in AdButler.Analytics.Finding, where: f.ad_account_id == ^account_b.id),
          :count
        )

      assert score_count_b == 0
      assert finding_count_b == 0
    end
  end
end
