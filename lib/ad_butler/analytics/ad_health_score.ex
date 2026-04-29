defmodule AdButler.Analytics.AdHealthScore do
  @moduledoc """
  Schema for ad health scores computed by `BudgetLeakAuditorWorker`.

  Append-only — each audit run inserts a new row. The most-recent row per
  `ad_id` (ordered by `computed_at DESC`) represents the current health state.
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

  @required [:ad_id, :computed_at, :leak_score]
  @optional [:fatigue_score, :leak_factors, :fatigue_factors, :recommended_action]

  @doc "Builds a changeset for an ad health score. Validates required fields."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(score, attrs) do
    score
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_number(:leak_score, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
  end
end
