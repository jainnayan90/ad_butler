defmodule AdButler.Workers.AuditHelpers do
  @moduledoc false
  # Shared helpers for the audit workers (`BudgetLeakAuditorWorker` and
  # `CreativeFatiguePredictorWorker`). Internal to the workers — no public API.

  @doc """
  Returns the current 6-hour bucket as a `DateTime` aligned to 00:00, 06:00,
  12:00, or 18:00 UTC. Both audit workers use the same bucket so they write
  the same `computed_at` row in `ad_health_scores`, with each worker
  populating its own column-isolated `on_conflict` replace clause.
  """
  @spec six_hour_bucket() :: DateTime.t()
  def six_hour_bucket do
    now = DateTime.utc_now()
    bucket_hour = div(now.hour, 6) * 6
    DateTime.new!(DateTime.to_date(now), Time.new!(bucket_hour, 0, 0, 0))
  end

  @doc """
  Returns `true` when `changeset` carries the `findings_ad_id_kind_unresolved_index`
  unique-constraint error. Audit workers re-classify this as a dedup `:skipped`
  rather than a generic `{:error, _}` because a concurrent-worker race past
  the in-process `MapSet` pre-check is functionally identical to dedup.

  See `Finding.create_changeset/2` for the matching `unique_constraint/3`
  declaration.
  """
  @spec dedup_constraint_error?(Ecto.Changeset.t()) :: boolean()
  def dedup_constraint_error?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:kind, {_, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
  end
end
