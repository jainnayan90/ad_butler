defmodule AdButler.Repo.Migrations.CreateAdAccounts do
  use Ecto.Migration

  def change do
    create table(:ad_accounts, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :meta_connection_id,
          references(:meta_connections, type: :binary_id, on_delete: :delete_all),
          null: false

      add :meta_id, :string, null: false
      add :name, :string, null: false
      add :currency, :string, null: false
      add :timezone_name, :string, null: false
      add :status, :string, null: false
      add :last_synced_at, :utc_datetime_usec
      add :raw_jsonb, :jsonb, default: "{}"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:ad_accounts, [:meta_connection_id])
    create unique_index(:ad_accounts, [:meta_connection_id, :meta_id])
  end
end
