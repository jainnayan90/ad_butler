defmodule AdButler.Ads.Ad do
  @moduledoc """
  Schema for a Meta ad, the leaf node of the campaign hierarchy.

  Belongs to an `AdAccount` and an `AdSet`. The `creative_id` association is
  nullable because Meta may delete a creative while the ad record persists
  (`on_delete: :nilify_all`). Raw API payload is preserved in `raw_jsonb`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "ads" do
    field :meta_id, :string
    field :name, :string
    field :status, :string
    field :raw_jsonb, :map

    belongs_to :ad_account, AdButler.Ads.AdAccount
    belongs_to :ad_set, AdButler.Ads.AdSet
    # creative_id may be nil (on_delete: :nilify_all)
    belongs_to :creative, AdButler.Ads.Creative

    timestamps(type: :utc_datetime_usec)
  end

  @required [:ad_account_id, :ad_set_id, :meta_id, :name, :status]
  @optional [:creative_id, :raw_jsonb]

  @doc "Returns the list of required field names for bulk-filtering."
  def required_fields, do: @required

  @doc "Builds a changeset for an ad. Validates required fields and the `(ad_account_id, meta_id)` uniqueness constraint."
  def changeset(ad, attrs) do
    ad
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> unique_constraint([:ad_account_id, :meta_id])
  end
end
