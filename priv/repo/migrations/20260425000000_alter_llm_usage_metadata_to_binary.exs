defmodule AdButler.Repo.Migrations.AlterLlmUsageMetadataToBinary do
  use Ecto.Migration

  def up do
    # Drop and re-add: table is empty so no data to preserve.
    # jsonb → bytea requires USING cast which Ecto's modify does not support.
    alter table(:llm_usage) do
      remove :metadata
    end

    alter table(:llm_usage) do
      add :metadata, :binary, null: true
    end
  end

  def down do
    alter table(:llm_usage) do
      remove :metadata
    end

    alter table(:llm_usage) do
      add :metadata, :jsonb, null: true, default: fragment("'{}'")
    end
  end
end
