defmodule AdButler.Repo.Migrations.AddIndexMetaConnectionsStatus do
  use Ecto.Migration

  def change do
    create index(:meta_connections, [:status])
  end
end
