defmodule AdButler.Repo.Migrations.AddPartialIndexMetaConnectionsActiveTokenExpiresAt do
  use Ecto.Migration

  def change do
    create index(:meta_connections, [:token_expires_at],
             where: "status = 'active'",
             name: "meta_connections_active_token_expires_at_idx"
           )
  end
end
