defmodule AdButler.Repo.Migrations.CreateAds do
  use Ecto.Migration

  def change do
    create table(:ads, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :ad_account_id, references(:ad_accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :ad_set_id, references(:ad_sets, type: :binary_id, on_delete: :delete_all), null: false
      add :creative_id, references(:creatives, type: :binary_id, on_delete: :nilify_all)
      add :meta_id, :string, null: false
      add :name, :string, null: false
      add :status, :string, null: false
      add :raw_jsonb, :jsonb, default: "{}"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:ads, [:ad_account_id])
    create index(:ads, [:ad_set_id])
    create index(:ads, [:creative_id])
    create unique_index(:ads, [:ad_account_id, :meta_id])
  end
end
