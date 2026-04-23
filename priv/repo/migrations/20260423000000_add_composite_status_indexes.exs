defmodule AdButler.Repo.Migrations.AddCompositeStatusIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_campaigns_account_status
    ON campaigns(ad_account_id, status)
    """

    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_ad_sets_account_status
    ON ad_sets(ad_account_id, status)
    """
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS idx_campaigns_account_status"
    execute "DROP INDEX CONCURRENTLY IF EXISTS idx_ad_sets_account_status"
  end
end
