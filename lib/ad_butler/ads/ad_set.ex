defmodule AdButler.Ads.AdSet do
  @moduledoc """
  Schema for a Meta ad set within a campaign.

  Budget fields (`daily_budget_cents`, `lifetime_budget_cents`, `bid_amount_cents`)
  store amounts in cents as returned by the Meta API. `targeting_jsonb` holds the
  raw targeting spec; `raw_jsonb` preserves the full API response.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "ad_sets" do
    field :meta_id, :string
    field :name, :string
    field :status, :string
    field :daily_budget_cents, :integer
    field :lifetime_budget_cents, :integer
    field :bid_amount_cents, :integer
    field :targeting_jsonb, :map
    field :raw_jsonb, :map

    belongs_to :ad_account, AdButler.Ads.AdAccount
    belongs_to :campaign, AdButler.Ads.Campaign

    timestamps(type: :utc_datetime_usec)
  end

  @required [:ad_account_id, :campaign_id, :meta_id, :name, :status]
  @optional [
    :daily_budget_cents,
    :lifetime_budget_cents,
    :bid_amount_cents,
    :targeting_jsonb,
    :raw_jsonb
  ]

  @doc "Returns the list of required field names for bulk-filtering."
  def required_fields, do: @required

  @doc "Builds a changeset for an ad set. Validates required fields and the `(ad_account_id, meta_id)` uniqueness constraint."
  def changeset(ad_set, attrs) do
    ad_set
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> unique_constraint([:ad_account_id, :meta_id])
  end
end
