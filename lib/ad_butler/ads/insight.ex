defmodule AdButler.Ads.Insight do
  @moduledoc """
  Read-only Ecto schema for the `insights_daily` partitioned table.

  Rows are written exclusively via `AdButler.Ads.bulk_upsert_insights/1` — no
  changeset is defined. The table is partitioned by `date_start` (weekly ranges),
  so `(ad_id, date_start)` is the composite primary key.
  """
  use Ecto.Schema

  @primary_key false
  schema "insights_daily" do
    belongs_to :ad, AdButler.Ads.Ad, type: :binary_id, foreign_key: :ad_id

    field :date_start, :date

    field :spend_cents, :integer
    field :impressions, :integer
    field :clicks, :integer
    field :reach_count, :integer
    field :frequency, :decimal
    field :conversions, :integer
    field :conversion_value_cents, :integer
    field :ctr_numeric, :decimal
    field :cpm_cents, :integer
    field :cpc_cents, :integer
    field :cpa_cents, :integer

    field :by_placement_jsonb, :map
    field :by_age_gender_jsonb, :map

    field :inserted_at, :naive_datetime
    field :updated_at, :naive_datetime
  end
end
