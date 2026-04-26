defmodule AdButler.Ads.AdAccount do
  @moduledoc """
  Schema for a Meta ad account linked to a `MetaConnection`.

  One connection may have multiple ad accounts. `last_synced_at` tracks when the
  full metadata sync last completed for this account. Raw API payload is preserved
  in `raw_jsonb` for fields not mapped to explicit columns.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "ad_accounts" do
    field :meta_id, :string
    field :name, :string
    field :currency, :string
    field :timezone_name, :string
    field :status, :string
    field :bm_id, :string
    field :bm_name, :string
    field :last_synced_at, :utc_datetime_usec
    field :raw_jsonb, :map

    belongs_to :meta_connection, AdButler.Accounts.MetaConnection

    has_many :campaigns, AdButler.Ads.Campaign
    has_many :ad_sets, AdButler.Ads.AdSet
    has_many :ads, AdButler.Ads.Ad
    has_many :creatives, AdButler.Ads.Creative

    timestamps(type: :utc_datetime_usec)
  end

  @required [:meta_connection_id, :meta_id, :name, :currency, :timezone_name, :status]
  @optional [:bm_id, :bm_name, :last_synced_at, :raw_jsonb]

  @doc "Builds a changeset for an ad account. Validates required fields and the `(meta_connection_id, meta_id)` uniqueness constraint."
  def changeset(ad_account, attrs) do
    ad_account
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> unique_constraint([:meta_connection_id, :meta_id])
  end
end
