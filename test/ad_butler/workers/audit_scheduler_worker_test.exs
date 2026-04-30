defmodule AdButler.Workers.AuditSchedulerWorkerTest do
  # async: false — tests share insights_daily partitions and ad_insights_30d mat-view;
  # concurrent processes would see each other's seeded rows and could deadlock on mat-view refresh
  use AdButler.DataCase, async: false
  use Oban.Testing, repo: AdButler.Repo

  import AdButler.Factory
  import Ecto.Query

  alias AdButler.Repo
  alias AdButler.Workers.AuditSchedulerWorker
  alias AdButler.Workers.BudgetLeakAuditorWorker
  alias AdButler.Workers.CreativeFatiguePredictorWorker

  setup do
    Repo.query!("REFRESH MATERIALIZED VIEW ad_insights_30d")
    :ok
  end

  describe "perform/1" do
    test "enqueues one BudgetLeakAuditorWorker and one CreativeFatiguePredictorWorker per active ad account" do
      mc1 = insert(:meta_connection)
      mc2 = insert(:meta_connection)
      aa1 = insert(:ad_account, meta_connection: mc1)
      aa2 = insert(:ad_account, meta_connection: mc2)

      assert :ok = perform_job(AuditSchedulerWorker, %{})

      assert_enqueued(worker: BudgetLeakAuditorWorker, args: %{"ad_account_id" => aa1.id})
      assert_enqueued(worker: BudgetLeakAuditorWorker, args: %{"ad_account_id" => aa2.id})
      assert_enqueued(worker: CreativeFatiguePredictorWorker, args: %{"ad_account_id" => aa1.id})
      assert_enqueued(worker: CreativeFatiguePredictorWorker, args: %{"ad_account_id" => aa2.id})
    end

    test "kill-switch (fatigue_enabled: false) enqueues only budget worker" do
      mc = insert(:meta_connection)
      aa = insert(:ad_account, meta_connection: mc)

      original = Application.get_env(:ad_butler, :fatigue_enabled, true)
      Application.put_env(:ad_butler, :fatigue_enabled, false)
      on_exit(fn -> Application.put_env(:ad_butler, :fatigue_enabled, original) end)

      assert :ok = perform_job(AuditSchedulerWorker, %{})

      assert_enqueued(worker: BudgetLeakAuditorWorker, args: %{"ad_account_id" => aa.id})

      refute_enqueued(
        worker: CreativeFatiguePredictorWorker,
        args: %{"ad_account_id" => aa.id}
      )
    end

    test "skips ad accounts for expired/inactive meta connections" do
      active_mc = insert(:meta_connection, status: "active")
      inactive_mc = insert(:meta_connection, status: "expired")
      active_aa = insert(:ad_account, meta_connection: active_mc)
      inactive_aa = insert(:ad_account, meta_connection: inactive_mc)

      assert :ok = perform_job(AuditSchedulerWorker, %{})

      assert_enqueued(worker: BudgetLeakAuditorWorker, args: %{"ad_account_id" => active_aa.id})

      refute_enqueued(
        worker: BudgetLeakAuditorWorker,
        args: %{"ad_account_id" => inactive_aa.id}
      )
    end

    test "returns :ok when no active ad accounts exist" do
      assert :ok = perform_job(AuditSchedulerWorker, %{})
    end
  end

  describe "job uniqueness" do
    test "inserting two jobs for same ad_account_id within 6h deduplicates to one" do
      mc = insert(:meta_connection)
      aa = insert(:ad_account, meta_connection: mc)

      args = %{"ad_account_id" => aa.id}

      {:ok, _job1} =
        args
        |> BudgetLeakAuditorWorker.new()
        |> Oban.insert()

      {:ok, job2} =
        args
        |> BudgetLeakAuditorWorker.new()
        |> Oban.insert()

      assert job2.conflict? == true

      assert Repo.aggregate(
               from(j in Oban.Job,
                 where: j.worker == "AdButler.Workers.BudgetLeakAuditorWorker",
                 where: fragment("? @> ?", j.args, ^%{"ad_account_id" => aa.id})
               ),
               :count
             ) == 1
    end
  end

  describe "smoke test — drain audit queue" do
    test "findings are created after draining audit queue for seeded account with spend + no conversions" do
      mc = insert(:meta_connection)
      ad_account = insert(:ad_account, meta_connection: mc)
      ad_set = insert(:ad_set, ad_account: ad_account)
      ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)

      Repo.insert_all("insights_daily", [
        %{
          ad_id: Ecto.UUID.dump!(ad.id),
          date_start: Date.utc_today(),
          spend_cents: 1500,
          impressions: 200,
          clicks: 10,
          reach_count: 150,
          conversions: 0,
          conversion_value_cents: 0,
          ctr_numeric: Decimal.new("0.05"),
          by_placement_jsonb: nil,
          inserted_at: NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second),
          updated_at: NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)
        }
      ])

      assert :ok = perform_job(AuditSchedulerWorker, %{})

      assert_enqueued(worker: BudgetLeakAuditorWorker, args: %{"ad_account_id" => ad_account.id})

      Oban.drain_queue(queue: :audit)

      findings_count =
        Repo.aggregate(
          from(f in AdButler.Analytics.Finding, where: f.ad_account_id == ^ad_account.id),
          :count
        )

      assert findings_count >= 1
    end
  end
end
