defmodule AdButler.Ads.AdAccount do
  @moduledoc false
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
  @optional [:last_synced_at, :raw_jsonb]

  def changeset(ad_account, attrs) do
    ad_account
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> unique_constraint([:meta_connection_id, :meta_id])
  end
end
