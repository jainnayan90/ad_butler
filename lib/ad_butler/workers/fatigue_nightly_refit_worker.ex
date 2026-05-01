defmodule AdButler.Workers.FatigueNightlyRefitWorker do
  @moduledoc """
  Oban cron worker (03:00 daily) that re-fans `CreativeFatiguePredictorWorker`
  jobs across all active ad accounts to refresh the predictive layer's
  regression baselines once a day, decoupled from the 6-hour heuristic cycle.

  Heuristics still run on the existing `AuditSchedulerWorker` 6-hour cadence —
  this worker only ensures the predictive layer's day-over-day fit reflects
  the latest 14-day window every morning. Per-account dedup on
  `CreativeFatiguePredictorWorker.unique` collapses the late-night refit into
  the next 6-hour audit if both fall in the same Oban unique window.
  """
  use Oban.Worker,
    queue: :audit,
    max_attempts: 3,
    unique: [period: 82_800, fields: [:queue, :worker]]

  require Logger

  alias AdButler.Accounts
  alias AdButler.Ads
  alias AdButler.Workers.CreativeFatiguePredictorWorker

  @doc "Enqueues a `CreativeFatiguePredictorWorker` job per active ad account."
  @impl Oban.Worker
  def perform(_job) do
    fatigue_enabled? = Application.get_env(:ad_butler, :fatigue_enabled, true)

    if fatigue_enabled? do
      enqueue_fatigue_jobs()
    else
      Logger.info("fatigue_nightly_refit: skipping (FATIGUE_ENABLED=false)")
      :ok
    end
  end

  defp enqueue_fatigue_jobs do
    mc_ids = Accounts.list_all_active_meta_connection_ids()
    ad_accounts = Ads.list_ad_accounts_by_mc_ids(mc_ids)

    results =
      Enum.flat_map(ad_accounts, fn aa ->
        case Oban.insert(CreativeFatiguePredictorWorker.new(%{"ad_account_id" => aa.id})) do
          {:ok, job} ->
            [job]

          {:error, reason} ->
            Logger.error("fatigue_nightly_refit: unexpected insert error",
              ad_account_id: aa.id,
              reason: reason
            )

            []
        end
      end)

    {inserted, conflicted} = Enum.split_with(results, fn job -> not job.conflict? end)

    if conflicted != [],
      do:
        Logger.info("fatigue_nightly_refit: jobs skipped (unique conflict)",
          count: length(conflicted)
        )

    Logger.info("fatigue_nightly_refit: enqueued jobs", count: length(inserted))
    :ok
  end
end
