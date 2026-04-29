defmodule AdButler.Repo.Migrations.CreateFindings do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create table(:findings, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :ad_id, references(:ads, type: :binary_id, on_delete: :delete_all), null: false

      add :ad_account_id,
          references(:ad_accounts, type: :binary_id, on_delete: :delete_all),
          null: false

      add :kind, :string, null: false
      add :severity, :string, null: false
      add :title, :string
      add :body, :text
      add :evidence, :map
      add :acknowledged_at, :utc_datetime_usec
      add :acknowledged_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :resolved_at, :utc_datetime_usec
      add :resolution, :text
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("NOW()")
    end

    execute(
      "CREATE INDEX findings_ad_account_id_severity_inserted_at_index ON findings (ad_account_id, severity, inserted_at DESC)",
      "DROP INDEX IF EXISTS findings_ad_account_id_severity_inserted_at_index"
    )

    create index(:findings, [:ad_id, :kind])

    # Partial unique index: deduplicates open findings by (ad_id, kind).
    # CONCURRENTLY cannot run inside a DDL transaction, so we use @disable_ddl_transaction.
    execute """
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS findings_ad_id_kind_unresolved_index
    ON findings (ad_id, kind)
    WHERE resolved_at IS NULL
    """
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS findings_ad_id_kind_unresolved_index"
    drop table(:findings)
  end
end
