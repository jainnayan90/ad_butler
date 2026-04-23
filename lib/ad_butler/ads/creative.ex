defmodule AdButler.Ads.Creative do
  @moduledoc """
  Schema for a Meta ad creative belonging to an ad account.

  `asset_specs_jsonb` holds the structured creative spec (images, videos, copy).
  `raw_jsonb` preserves the full API payload. Creatives are nilified on ads
  (`on_delete: :nilify_all`) rather than cascading so ad records survive creative
  deletion.
  """
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

  @doc "Builds a changeset for a creative. Validates required fields and the `(ad_account_id, meta_id)` uniqueness constraint."
  def changeset(creative, attrs) do
    creative
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> unique_constraint([:ad_account_id, :meta_id])
  end
end
