defmodule AdButler.Repo.Migrations.CreateCreatives do
  use Ecto.Migration

  def change do
    create table(:creatives, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :ad_account_id, references(:ad_accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :meta_id, :string, null: false
      add :name, :string
      add :asset_specs_jsonb, :jsonb, default: "{}"
      add :raw_jsonb, :jsonb, default: "{}"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:creatives, [:ad_account_id])
    create unique_index(:creatives, [:ad_account_id, :meta_id])
  end
end
