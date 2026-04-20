defmodule AdButler.Repo.Migrations.CreateCampaigns do
  use Ecto.Migration

  def change do
    create table(:campaigns, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :ad_account_id, references(:ad_accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :meta_id, :string, null: false
      add :name, :string, null: false
      add :status, :string, null: false
      add :objective, :string, null: false
      add :daily_budget_cents, :bigint
      add :lifetime_budget_cents, :bigint
      add :raw_jsonb, :jsonb, default: "{}"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:campaigns, [:ad_account_id])
    create unique_index(:campaigns, [:ad_account_id, :meta_id])
  end
end
