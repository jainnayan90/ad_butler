defmodule AdButler.Workers.PartitionManagerWorker do
  @moduledoc """
  Oban worker that manages `insights_daily` table partitions.

  Runs weekly (Sunday 3am) to:
  1. Create the next 2 weekly partitions (idempotent — uses `CREATE TABLE IF NOT EXISTS`).
  2. Detach partitions older than 13 months to keep the partition list bounded.
  3. Log a critical error if fewer than 2 future partitions exist after creation.

  Delegates all DB work to `AdButler.Analytics`.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  alias AdButler.Analytics

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  @doc "Creates next 2 weekly partitions and detaches partitions older than 13 months."
  @impl Oban.Worker
  def perform(_job) do
    Analytics.create_future_partitions()
    Analytics.detach_old_partitions()
    Analytics.check_future_partition_count()
    :ok
  end
end
