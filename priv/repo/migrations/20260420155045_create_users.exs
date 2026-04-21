defmodule AdButler.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    execute("CREATE EXTENSION IF NOT EXISTS citext", "DROP EXTENSION IF EXISTS citext")

    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :email, :citext, null: false
      add :meta_user_id, :string
      add :name, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:email])
    create unique_index(:users, [:meta_user_id])
  end
end
