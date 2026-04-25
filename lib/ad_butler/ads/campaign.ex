defmodule AdButler.Ads.Campaign do
  @moduledoc """
  Schema for a Meta campaign within an ad account.

  `status` is validated against Meta's allowed values (`ACTIVE`, `PAUSED`,
  `DELETED`, `ARCHIVED`). Budget fields store amounts in cents. `raw_jsonb`
  preserves the full API payload for fields not mapped to explicit columns.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_statuses ~w(ACTIVE PAUSED DELETED ARCHIVED)

  schema "campaigns" do
    field :meta_id, :string
    field :name, :string
    field :status, :string
    field :objective, :string
    field :daily_budget_cents, :integer
    field :lifetime_budget_cents, :integer
    field :raw_jsonb, :map

    belongs_to :ad_account, AdButler.Ads.AdAccount
    has_many :ad_sets, AdButler.Ads.AdSet

    timestamps(type: :utc_datetime_usec)
  end

  @required [:ad_account_id, :meta_id, :name, :status, :objective]
  @optional [:daily_budget_cents, :lifetime_budget_cents, :raw_jsonb]

  @doc "Returns the list of required field names for bulk-filtering."
  def required_fields, do: @required

  @doc "Builds a changeset for a campaign. Validates required fields, `status` inclusion, and the `(ad_account_id, meta_id)` uniqueness constraint."
  def changeset(campaign, attrs) do
    campaign
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint([:ad_account_id, :meta_id])
  end
end
