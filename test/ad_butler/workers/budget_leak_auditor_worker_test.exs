defmodule AdButler.Workers.BudgetLeakAuditorWorkerTest do
  # async: false — tests share insights_daily partitions and ad_insights_30d mat-view;
  # concurrent processes would see each other's seeded rows and could deadlock on mat-view refresh
  use AdButler.DataCase, async: false
  use Oban.Testing, repo: AdButler.Repo

  import AdButler.Factory
  import Ecto.Query

  alias AdButler.Ads.AdSet
  alias AdButler.Analytics
  alias AdButler.Analytics.Finding
  alias AdButler.Repo
  alias AdButler.Workers.BudgetLeakAuditorWorker

  # Refresh mat view without CONCURRENTLY (required inside a sandbox transaction).
  setup do
    Repo.query!("REFRESH MATERIALIZED VIEW ad_insights_30d")
    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp insert_ad_with_account do
    mc = insert(:meta_connection)
    ad_account = insert(:ad_account, meta_connection: mc)
    ad_set = insert(:ad_set, ad_account: ad_account)
    ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)
    {ad_account, ad}
  end

  defp insert_insight(ad, opts) do
    Repo.insert_all("insights_daily", [
      %{
        ad_id: Ecto.UUID.dump!(ad.id),
        date_start: Keyword.get(opts, :date_start, Date.utc_today()),
        spend_cents: Keyword.get(opts, :spend_cents, 0),
        impressions: Keyword.get(opts, :impressions, 0),
        clicks: Keyword.get(opts, :clicks, 0),
        reach_count: Keyword.get(opts, :reach_count, 0),
        conversions: Keyword.get(opts, :conversions, 0),
        conversion_value_cents: 0,
        ctr_numeric: Keyword.get(opts, :ctr_numeric, Decimal.new("0.0")),
        by_placement_jsonb: Keyword.get(opts, :by_placement_jsonb, nil),
        inserted_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second),
        updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      }
    ])
  end

  defp count_findings(ad, kind) do
    Repo.aggregate(
      from(f in Finding, where: f.ad_id == ^ad.id and f.kind == ^kind),
      :count
    )
  end

  # ---------------------------------------------------------------------------
  # Heuristic 1: Dead Spend
  # ---------------------------------------------------------------------------

  describe "dead_spend heuristic" do
    test "creates finding when spend > $5 and zero conversions" do
      {ad_account, ad} = insert_ad_with_account()
      insert_insight(ad, spend_cents: 1000, conversions: 0, reach_count: 100)

      assert :ok = perform_job(BudgetLeakAuditorWorker, %{"ad_account_id" => ad_account.id})

      assert count_findings(ad, "dead_spend") == 1
    end

    test "skips when spend < $5 (500 cents)" do
      {ad_account, ad} = insert_ad_with_account()
      insert_insight(ad, spend_cents: 400, conversions: 0, reach_count: 100)

      assert :ok = perform_job(BudgetLeakAuditorWorker, %{"ad_account_id" => ad_account.id})

      assert count_findings(ad, "dead_spend") == 0
    end

    test "skips when there are conversions" do
      {ad_account, ad} = insert_ad_with_account()
      insert_insight(ad, spend_cents: 2000, conversions: 5, reach_count: 100)

      assert :ok = perform_job(BudgetLeakAuditorWorker, %{"ad_account_id" => ad_account.id})

      assert count_findings(ad, "dead_spend") == 0
    end

    test "skips when reach uplift >= 5% of max_reach (growing reach)" do
      {ad_account, ad} = insert_ad_with_account()

      # Two rows on different dates: reach goes from 100 to 110 → uplift = 10, max_reach = 110, 5% = 5.5
      # 10 >= 5.5 → should skip
      insert_insight(ad,
        date_start: Date.add(Date.utc_today(), -1),
        spend_cents: 1000,
        conversions: 0,
        reach_count: 100
      )

      insert_insight(ad, spend_cents: 1000, conversions: 0, reach_count: 110)

      assert :ok = perform_job(BudgetLeakAuditorWorker, %{"ad_account_id" => ad_account.id})

      assert count_findings(ad, "dead_spend") == 0
    end

    test "fires when reach is stagnant (uplift < 5% of max_reach)" do
      {ad_account, ad} = insert_ad_with_account()
      # Two rows: same reach_count → uplift = 0 → 0 < max_reach * 0.05 → fires
      insert_insight(ad,
        date_start: Date.add(Date.utc_today(), -1),
        spend_cents: 1000,
        conversions: 0,
        reach_count: 100
      )

      insert_insight(ad, spend_cents: 1000, conversions: 0, reach_count: 100)
      assert :ok = perform_job(BudgetLeakAuditorWorker, %{"ad_account_id" => ad_account.id})
      assert count_findings(ad, "dead_spend") == 1
    end

    test "upserts health score even when no heuristic fires" do
      {ad_account, ad} = insert_ad_with_account()
      insert_insight(ad, spend_cents: 0, conversions: 0)

      assert :ok = perform_job(BudgetLeakAuditorWorker, %{"ad_account_id" => ad_account.id})

      score = Analytics.unsafe_get_latest_health_score(ad.id)
      assert score != nil
      assert Decimal.compare(score.leak_score, Decimal.new("0")) == :eq
    end
  end

  # ---------------------------------------------------------------------------
  # Health score upsert
  # ---------------------------------------------------------------------------

  describe "health score upsert" do
    test "running worker twice produces exactly one health score row" do
      {ad_account, ad} = insert_ad_with_account()
      insert_insight(ad, spend_cents: 0, conversions: 0)

      assert :ok = perform_job(BudgetLeakAuditorWorker, %{"ad_account_id" => ad_account.id})
      assert :ok = perform_job(BudgetLeakAuditorWorker, %{"ad_account_id" => ad_account.id})

      count =
        Repo.aggregate(
          from(s in AdButler.Analytics.AdHealthScore, where: s.ad_id == ^ad.id),
          :count
        )

      assert count == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Heuristic 2: CPA Explosion
  # ---------------------------------------------------------------------------

  describe "cpa_explosion heuristic" do
    test "skips when 30d baseline is nil (new ad with no view data)" do
      {ad_account, ad} = insert_ad_with_account()
      insert_insight(ad, spend_cents: 5000, conversions: 2)

      # No 30d view data — baseline will be nil
      assert :ok = perform_job(BudgetLeakAuditorWorker, %{"ad_account_id" => ad_account.id})

      assert count_findings(ad, "cpa_explosion") == 0
    end

    test "creates finding when 3-day CPA > 2.5x 30-day baseline" do
      {ad_account, ad} = insert_ad_with_account()

      # Partitions only exist for current week+. Create last week's partition so we
      # can seed baseline rows with date_start outside the 48h window.
      Repo.query!("SELECT create_insights_partition((CURRENT_DATE - INTERVAL '7 days')::DATE)")

      # Seed 30d baseline: 10 conversions on 10_000 cents → CPA = 1000 cents (outside 48h window)
      insert_insight(ad,
        date_start: Date.add(Date.utc_today(), -7),
        spend_cents: 10_000,
        conversions: 10
      )

      Repo.query!("REFRESH MATERIALIZED VIEW ad_insights_30d")

      # Seed recent high-spend: 2 conversions on 10_000 cents → CPA = 5000 cents (5x baseline)
      insert_insight(ad, spend_cents: 10_000, conversions: 2)

      assert :ok = perform_job(BudgetLeakAuditorWorker, %{"ad_account_id" => ad_account.id})

      assert count_findings(ad, "cpa_explosion") == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Deduplication
  # ---------------------------------------------------------------------------

  describe "deduplication" do
    test "running worker twice creates only 1 finding per (ad_id, kind)" do
      {ad_account, ad} = insert_ad_with_account()
      insert_insight(ad, spend_cents: 1000, conversions: 0, reach_count: 50)

      assert :ok = perform_job(BudgetLeakAuditorWorker, %{"ad_account_id" => ad_account.id})
      assert :ok = perform_job(BudgetLeakAuditorWorker, %{"ad_account_id" => ad_account.id})

      assert count_findings(ad, "dead_spend") == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Missing ad account
  # ---------------------------------------------------------------------------

  describe "perform/1 with missing ad account" do
    test "returns :ok and skips when ad_account not found" do
      assert :ok =
               perform_job(BudgetLeakAuditorWorker, %{
                 "ad_account_id" => Ecto.UUID.generate()
               })
    end
  end

  # ---------------------------------------------------------------------------
  # Heuristic 3: Bot Traffic
  # ---------------------------------------------------------------------------

  describe "bot_traffic heuristic" do
    test "creates finding when CTR > 5%, low conversion rate, risky placement" do
      {ad_account, ad} = insert_ad_with_account()

      # CTR = 120/2000 = 0.06 > 0.05; conversion_rate = 1/600 ≈ 0.0017 < 0.003
      insert_insight(ad,
        impressions: 2000,
        clicks: 600,
        conversions: 1,
        ctr_numeric: Decimal.new("0.06"),
        by_placement_jsonb: %{
          "audience_network" => %{"impressions" => 2000, "spend_cents" => 500}
        }
      )

      assert :ok = perform_job(BudgetLeakAuditorWorker, %{"ad_account_id" => ad_account.id})

      assert count_findings(ad, "bot_traffic") == 1
    end

    test "skips when impressions < 1000 (not enough data)" do
      {ad_account, ad} = insert_ad_with_account()

      insert_insight(ad,
        impressions: 500,
        clicks: 30,
        conversions: 0,
        ctr_numeric: Decimal.new("0.06"),
        by_placement_jsonb: %{"audience_network" => %{"impressions" => 500}}
      )

      assert :ok = perform_job(BudgetLeakAuditorWorker, %{"ad_account_id" => ad_account.id})

      assert count_findings(ad, "bot_traffic") == 0
    end
  end

  # ---------------------------------------------------------------------------
  # Heuristic 4: Placement Drag
  # ---------------------------------------------------------------------------

  describe "placement_drag heuristic" do
    test "creates finding when max/min placement CPA ratio > 3x" do
      {ad_account, ad} = insert_ad_with_account()

      insert_insight(ad,
        spend_cents: 1000,
        impressions: 5000,
        by_placement_jsonb: %{
          "facebook_feed" => %{"spend_cents" => 200, "conversions" => 10},
          "audience_network" => %{"spend_cents" => 800, "conversions" => 2}
        }
      )

      assert :ok = perform_job(BudgetLeakAuditorWorker, %{"ad_account_id" => ad_account.id})

      assert count_findings(ad, "placement_drag") == 1
    end

    test "skips when only a single placement in by_placement_jsonb" do
      {ad_account, ad} = insert_ad_with_account()

      insert_insight(ad,
        spend_cents: 1000,
        by_placement_jsonb: %{
          "facebook_feed" => %{"spend_cents" => 1000, "conversions" => 5}
        }
      )

      assert :ok = perform_job(BudgetLeakAuditorWorker, %{"ad_account_id" => ad_account.id})

      assert count_findings(ad, "placement_drag") == 0
    end

    test "skips when placement CPA ratio is less than 3x" do
      {ad_account, ad} = insert_ad_with_account()

      # facebook_feed CPA = 200/10 = 20; audience_network CPA = 400/10 = 40 → ratio = 2x
      insert_insight(ad,
        spend_cents: 600,
        by_placement_jsonb: %{
          "facebook_feed" => %{"spend_cents" => 200, "conversions" => 10},
          "audience_network" => %{"spend_cents" => 400, "conversions" => 10}
        }
      )

      assert :ok = perform_job(BudgetLeakAuditorWorker, %{"ad_account_id" => ad_account.id})

      assert count_findings(ad, "placement_drag") == 0
    end
  end

  # ---------------------------------------------------------------------------
  # Heuristic 5: Stalled Learning
  # ---------------------------------------------------------------------------

  describe "stalled_learning heuristic" do
    defp insert_learning_ad_set(ad_account, days_ago) do
      cutoff = DateTime.add(DateTime.utc_now(), -days_ago * 24 * 3600, :second)

      ad_set =
        insert(:ad_set,
          ad_account: ad_account,
          raw_jsonb: %{"effective_status" => "LEARNING"}
        )

      Repo.update_all(from(s in AdSet, where: s.id == ^ad_set.id),
        set: [updated_at: cutoff]
      )

      ad_set
    end

    test "creates finding when ad_set in LEARNING > 7 days and conversions < 50" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)
      ad_set = insert_learning_ad_set(ad_account, 8)
      ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)
      insert_insight(ad, conversions: 10)

      assert :ok = perform_job(BudgetLeakAuditorWorker, %{"ad_account_id" => ad_account.id})

      assert count_findings(ad, "stalled_learning") == 1
    end

    test "skips when conversions >= 50 in 7d" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)
      ad_set = insert_learning_ad_set(ad_account, 8)
      ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)
      insert_insight(ad, conversions: 55)

      assert :ok = perform_job(BudgetLeakAuditorWorker, %{"ad_account_id" => ad_account.id})

      assert count_findings(ad, "stalled_learning") == 0
    end

    test "skips when ad_set effective_status is not LEARNING" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)

      ad_set =
        insert(:ad_set, ad_account: ad_account, raw_jsonb: %{"effective_status" => "ACTIVE"})

      ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)
      insert_insight(ad, conversions: 5)

      assert :ok = perform_job(BudgetLeakAuditorWorker, %{"ad_account_id" => ad_account.id})

      assert count_findings(ad, "stalled_learning") == 0
    end
  end

  # ---------------------------------------------------------------------------
  # Scoring
  # ---------------------------------------------------------------------------

  describe "scoring" do
    test "dead_spend fires and health score reflects weight 40" do
      {ad_account, ad} = insert_ad_with_account()
      insert_insight(ad, spend_cents: 2000, conversions: 0, reach_count: 100)

      assert :ok = perform_job(BudgetLeakAuditorWorker, %{"ad_account_id" => ad_account.id})

      score = Analytics.unsafe_get_latest_health_score(ad.id)
      assert score != nil
      # dead_spend weight = 40
      assert Decimal.compare(score.leak_score, Decimal.new("40")) == :eq
    end
  end
end
