defmodule AdButler.Repo.Migrations.AddEmbeddingsHnswIndex do
  use Ecto.Migration

  # CONCURRENTLY cannot run inside a DDL transaction. HNSW build is the slow
  # path we want non-blocking — D0011 pegged HNSW at m=16, ef_construction=64
  # (suitable up to ~1M rows; revisit IVFFlat at >1M).
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS embeddings_hnsw_idx
    ON embeddings
    USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64)
    """
  end

  def down do
    # DROP INDEX CONCURRENTLY also requires `@disable_ddl_transaction true`
    # (already set at the top of the module).
    execute "DROP INDEX CONCURRENTLY IF EXISTS embeddings_hnsw_idx"
  end
end
