defmodule AdButler.Repo.Migrations.AddCompositeIndexAdsAdAccountIdStatus do
  use Ecto.Migration

  def up do
    create index(:ads, [:ad_account_id, :status], name: :ads_ad_account_id_status_index)
  end

  def down do
    drop_if_exists index(:ads, [:ad_account_id, :status], name: :ads_ad_account_id_status_index)
  end
end
