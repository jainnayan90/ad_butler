defmodule AdButler.Analytics.Finding do
  @moduledoc """
  Schema for budget leak findings produced by `BudgetLeakAuditorWorker`.

  A finding represents a detected inefficiency on an ad. It is scoped to an
  `AdAccount` for fast inbox queries. Findings are deduplicated by `(ad_id, kind)`
  while unresolved — enforced by a partial unique index and application-level check.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "findings" do
    field :ad_id, :binary_id
    field :ad_account_id, :binary_id
    field :acknowledged_by_user_id, :binary_id

    field :kind, :string
    field :severity, :string
    field :title, :string
    field :body, :string
    field :evidence, :map

    field :acknowledged_at, :utc_datetime_usec
    field :resolved_at, :utc_datetime_usec
    field :resolution, :string

    field :inserted_at, :utc_datetime_usec
  end

  @type t :: %__MODULE__{}

  @valid_severities ~w(low medium high)
  @valid_kinds ~w(dead_spend cpa_explosion bot_traffic placement_drag stalled_learning)

  @required [:ad_id, :ad_account_id, :kind, :severity]
  @content_fields [:ad_id, :ad_account_id, :kind, :severity, :title, :body, :evidence]

  @doc "Builds a changeset for creating a new finding. Casts content fields only."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(finding, attrs) do
    finding
    |> cast(attrs, @content_fields)
    |> validate_required(@required)
    |> validate_inclusion(:severity, @valid_severities)
    |> validate_inclusion(:kind, @valid_kinds)
  end

  @doc "Builds a changeset for acknowledging a finding."
  @spec acknowledge_changeset(t(), binary()) :: Ecto.Changeset.t()
  def acknowledge_changeset(finding, user_id) do
    change(finding,
      acknowledged_at: DateTime.utc_now(),
      acknowledged_by_user_id: user_id
    )
  end
end
