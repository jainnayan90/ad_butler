defmodule AdButler.Repo.Migrations.CreateEmbeddings do
  use Ecto.Migration

  # The pgvector extension is provisioned alongside the table — the type
  # `vector(1536)` requires the extension to exist before column creation.
  def up do
    execute "CREATE EXTENSION IF NOT EXISTS vector"

    create table(:embeddings, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :kind, :string, null: false
      add :ref_id, :binary_id, null: false
      # 1536 = OpenAI text-embedding-3-small; dimension change requires a new migration.
      add :embedding, :vector, size: 1536, null: false
      add :content_hash, :string, null: false
      add :content_excerpt, :text
      add :metadata, :map

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:embeddings, [:kind, :ref_id])

    create constraint(:embeddings, :embeddings_kind_check,
             check: "kind IN ('ad', 'finding', 'doc_chunk')"
           )
  end

  def down do
    drop table(:embeddings)
    # If a future migration adds a second `vector` column elsewhere in the schema,
    # this rollback must be updated — dropping the extension here would break it.
    execute "DROP EXTENSION IF EXISTS vector"
  end
end
