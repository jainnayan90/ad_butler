defmodule AdButler.Repo.Migrations.CreateMetaConnections do
  use Ecto.Migration

  def change do
    create table(:meta_connections, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :meta_user_id, :string, null: false
      add :access_token, :binary, null: false
      add :token_expires_at, :utc_datetime_usec, null: false
      add :scopes, {:array, :string}, null: false, default: []
      add :status, :string, null: false, default: "active"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:meta_connections, [:user_id])
    create unique_index(:meta_connections, [:user_id, :meta_user_id])

    create constraint(:meta_connections, :status_values,
             check: "status IN ('active','revoked','expired','error')"
           )
  end
end
