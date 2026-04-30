defmodule AdButler.Analytics.AdHealthScore do
  @moduledoc """
  Schema for ad health scores written by two auditors:

    * `AdButler.Workers.BudgetLeakAuditorWorker` — populates `leak_score` and
      `leak_factors`.
    * `AdButler.Workers.CreativeFatiguePredictorWorker` — populates
      `fatigue_score` and `fatigue_factors`.

  Both workers share the same 6-hour `computed_at` bucket so a single row per
  `(ad_id, computed_at)` carries both signals. Each worker upserts only its own
  columns via a column-isolated `on_conflict` replace clause — neither writer
  clobbers the other's values when both run in the same window.

  Append-only across buckets: each new 6-hour window inserts fresh rows. The
  most-recent row per `ad_id` (ordered by `computed_at DESC`) represents the
  current health state.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "ad_health_scores" do
    field :ad_id, :binary_id

    field :computed_at, :utc_datetime_usec
    field :leak_score, :decimal
    field :fatigue_score, :decimal
    field :leak_factors, :map
    field :fatigue_factors, :map
    field :recommended_action, :string

    field :inserted_at, :utc_datetime_usec
  end

  @type t :: %__MODULE__{}

  @required [:ad_id, :computed_at]
  @optional [
    :leak_score,
    :fatigue_score,
    :leak_factors,
    :fatigue_factors,
    :recommended_action
  ]

  @doc """
  Builds a changeset for an ad health score. `leak_score` and `fatigue_score`
  are both optional so each worker can populate its own column without
  clobbering the other on a shared `(ad_id, computed_at)` row.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(score, attrs) do
    score
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_number(:leak_score, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_number(:fatigue_score, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
  end
end
