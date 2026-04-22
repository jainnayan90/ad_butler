defmodule AdButler.Ads.Creative do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "creatives" do
    field :meta_id, :string
    field :name, :string
    field :asset_specs_jsonb, :map
    field :raw_jsonb, :map

    belongs_to :ad_account, AdButler.Ads.AdAccount

    timestamps(type: :utc_datetime_usec)
  end

  @required [:ad_account_id, :meta_id]
  @optional [:name, :asset_specs_jsonb, :raw_jsonb]

  def changeset(creative, attrs) do
    creative
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> unique_constraint([:ad_account_id, :meta_id])
  end
end
