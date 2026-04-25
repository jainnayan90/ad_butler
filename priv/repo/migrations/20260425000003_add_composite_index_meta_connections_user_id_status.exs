defmodule AdButler.Repo.Migrations.AddCompositeIndexMetaConnectionsUserIdStatus do
  use Ecto.Migration

  def up do
    create index(:meta_connections, [:user_id, :status],
             name: :meta_connections_user_id_status_index
           )
  end

  def down do
    drop_if_exists index(:meta_connections, [:user_id, :status],
                     name: :meta_connections_user_id_status_index
                   )
  end
end
