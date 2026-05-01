defmodule AdButler.Integration.Week8E2ESmokeTest do
  @moduledoc """
  Week 8 end-to-end smoke test (W8D5-T1):

  Seeds an ad with 14 days of declining CTR + high recent frequency, then
  drives the full fatigue → finding → embedding pipeline:

    1. `FatigueNightlyRefitWorker` enqueues `CreativeFatiguePredictorWorker`.
    2. The predictor's heuristic + predictive layers fire → fatigue_score 60,
       a `creative_fatigue` finding with `evidence.predicted == true`.
    3. `EmbeddingsRefreshWorker` upserts an `ad` embedding for the ad and a
       `finding` embedding for the new finding.

  async: false — schedule worker drives `perform_job/2` chains; setup also
  uses `create_insights_partition` which is non-transactional DDL.
  """
  use AdButler.DataCase, async: false
  use Oban.Testing, repo: AdButler.Repo

  @moduletag :integration

  import AdButler.Factory
  import AdButler.InsightsHelpers, only: [insert_daily: 3]
  import Ecto.Query
  import Mox

  alias AdButler.Analytics.Finding
  alias AdButler.Embeddings.Embedding
  alias AdButler.Repo

  alias AdButler.Workers.{
    CreativeFatiguePredictorWorker,
    EmbeddingsRefreshWorker,
    FatigueNightlyRefitWorker
  }

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    Enum.each([7, 14, 21], fn d ->
      Repo.query!("SELECT create_insights_partition((CURRENT_DATE - INTERVAL '#{d} days')::DATE)")
    end)

    :ok
  end

  defp random_vector, do: for(_ <- 1..1536, do: :rand.uniform())

  test "declining ad → predictive creative_fatigue finding → ad + finding embeddings" do
    mc = insert(:meta_connection)
    ad_account = insert(:ad_account, meta_connection: mc)
    ad_set = insert(:ad_set, ad_account: ad_account)
    ad = insert(:ad, ad_account: ad_account, ad_set: ad_set, name: "Decline Promo")

    # 14 days. CTR drops 0.05 → 0.024 (linear in day_index). Recent half has
    # frequency > 3.5 + sufficient impressions so heuristic_frequency_ctr_decay
    # also fires (35 weight) — combined with predicted_fatigue (25) → score 60.
    reaches = [800, 1100, 950, 1200, 1050, 900, 1300, 1000, 1150, 1250, 1050, 1100, 950, 1200]

    Enum.with_index(reaches)
    |> Enum.each(fn {reach, d_index} ->
      days_ago = 13 - d_index
      impressions = 2_000
      ctr_target = 0.05 - 0.002 * d_index
      clicks = round(impressions * ctr_target)
      freq = if d_index >= 7, do: 4.5 + rem(d_index, 2) * 0.3, else: 1.5 + rem(d_index, 3) * 0.2

      insert_daily(ad, days_ago, %{
        impressions: impressions,
        clicks: clicks,
        reach_count: reach,
        frequency: Decimal.from_float(Float.round(freq, 4))
      })
    end)

    # Step 1: nightly refit fan-out enqueues the per-account predictor job.
    assert :ok = perform_job(FatigueNightlyRefitWorker, %{})

    assert_enqueued(
      worker: CreativeFatiguePredictorWorker,
      args: %{"ad_account_id" => ad_account.id}
    )

    # Step 2: drain the enqueued predictor job(s). The factory chain may
    # create incidental ad_accounts, so we don't pin an exact success count
    # — but at least one job must drain successfully (the one for our ad)
    # and zero may fail. Anchors the predictive finding assertion below.
    assert %{success: success, failure: 0} = Oban.drain_queue(queue: :fatigue_audit)
    assert success >= 1, "expected the predictor job for our ad_account to drain successfully"

    # Predictive finding emitted with predicted=true + forecast date.
    assert [finding] =
             Repo.all(
               from f in Finding, where: f.ad_id == ^ad.id and f.kind == "creative_fatigue"
             )

    assert finding.title =~ "Predicted fatigue"
    assert finding.evidence["predicted"] == true
    assert {:ok, _} = Date.from_iso8601(finding.evidence["forecast_window_end"])

    # Step 3: drive embeddings — one batch per kind (ad + finding).
    expect(AdButler.Embeddings.ServiceMock, :embed, fn texts ->
      assert length(texts) == 1
      {:ok, [random_vector()]}
    end)

    expect(AdButler.Embeddings.ServiceMock, :embed, fn texts ->
      assert length(texts) == 1
      {:ok, [random_vector()]}
    end)

    assert :ok = perform_job(EmbeddingsRefreshWorker, %{})

    assert Repo.one(from e in Embedding, where: e.kind == "ad" and e.ref_id == ^ad.id)

    assert Repo.one(
             from e in Embedding,
               where: e.kind == "finding" and e.ref_id == ^finding.id
           )
  end
end
