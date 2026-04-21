defmodule AdButler.Repo.Migrations.CreateAdSets do
  use Ecto.Migration

  def change do
    create table(:ad_sets, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :ad_account_id, references(:ad_accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :campaign_id, references(:campaigns, type: :binary_id, on_delete: :delete_all),
        null: false

      add :meta_id, :string, null: false
      add :name, :string, null: false
      add :status, :string, null: false
      add :daily_budget_cents, :bigint
      add :lifetime_budget_cents, :bigint
      add :bid_amount_cents, :bigint
      add :targeting_jsonb, :jsonb, default: "{}"
      add :raw_jsonb, :jsonb, default: "{}"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:ad_sets, [:ad_account_id])
    create index(:ad_sets, [:campaign_id])
    create unique_index(:ad_sets, [:ad_account_id, :meta_id])
  end
end
