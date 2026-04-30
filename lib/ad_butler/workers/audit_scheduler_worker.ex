defmodule AdButler.Workers.AuditSchedulerWorker do
  @moduledoc """
  Oban worker that fans out one `BudgetLeakAuditorWorker` job and (when enabled)
  one `CreativeFatiguePredictorWorker` job per active ad account.

  Runs every 6 hours. Each enqueued auditor job is deduplicated by `ad_account_id`
  within a 6-hour window so a scheduler retry cannot double-queue accounts.

  ## Kill-switch

  Read at runtime from `Application.get_env(:ad_butler, :fatigue_enabled, true)`.
  The value is set in `config/runtime.exs` from the `FATIGUE_ENABLED` env var
  (`"true"` / `"false"`, default `"true"`). Flip the env var and restart the
  worker process to pause fatigue audits without redeploying. Tests can also
  toggle via `Application.put_env/3`.
  """
  # fields: [:queue, :worker] ignores args — one scheduler job per 6h window regardless of args
  use Oban.Worker,
    queue: :audit,
    max_attempts: 3,
    unique: [period: 21_600, fields: [:queue, :worker]]

  require Logger

  alias AdButler.Accounts
  alias AdButler.Ads
  alias AdButler.Workers.BudgetLeakAuditorWorker
  alias AdButler.Workers.CreativeFatiguePredictorWorker

  @doc "Enqueues budget-leak and creative-fatigue auditor jobs per active ad account."
  @impl Oban.Worker
  def perform(_job) do
    mc_ids = Accounts.list_all_active_meta_connection_ids()
    ad_accounts = Ads.list_ad_accounts_by_mc_ids(mc_ids)
    fatigue_enabled? = Application.get_env(:ad_butler, :fatigue_enabled, true)

    changesets =
      Enum.flat_map(ad_accounts, fn aa ->
        args = %{"ad_account_id" => aa.id}

        leak = BudgetLeakAuditorWorker.new(args)

        if fatigue_enabled? do
          [leak, CreativeFatiguePredictorWorker.new(args)]
        else
          [leak]
        end
      end)

    {valid, invalid} = Enum.split_with(changesets, & &1.valid?)
    Enum.each(invalid, &Logger.error("audit_scheduler: invalid job changeset", errors: &1.errors))
    # insert/2 (not insert_all) so Oban's unique-job resolution fires on the Basic Engine;
    # Basic Engine returns {:ok, %Job{conflict?: true}} for unique-conflict skips, not {:error, _}
    results =
      Enum.flat_map(valid, fn cs ->
        case Oban.insert(cs) do
          {:ok, job} ->
            [job]

          {:error, reason} ->
            Logger.error("audit_scheduler: unexpected insert error", reason: inspect(reason))
            []
        end
      end)

    {inserted, conflicted} = Enum.split_with(results, fn job -> not job.conflict? end)

    if conflicted != [],
      do:
        Logger.info("audit_scheduler: jobs skipped (unique conflict)", count: length(conflicted))

    Logger.info("audit_scheduler: enqueued jobs", count: length(inserted))
    :ok
  end
end
