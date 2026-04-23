defmodule AdButler.Repo.Migrations.AddIndexMetaConnectionsStatus do
  use Ecto.Migration

  # CONCURRENTLY avoids a table-level ShareLock that would block writes.
  # Requires disabling the DDL transaction wrapper — a failed run leaves a
  # partially-built index; drop it with `DROP INDEX CONCURRENTLY` before re-running.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index(:meta_connections, [:status], concurrently: true)
  end
end
