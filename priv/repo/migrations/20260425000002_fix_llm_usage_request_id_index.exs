defmodule AdButler.Repo.Migrations.FixLlmUsageRequestIdIndex do
  use Ecto.Migration

  def up do
    drop_if_exists index(:llm_usage, [:request_id], name: :llm_usage_request_id_unique)
    # Non-partial index: PostgreSQL treats each NULL as distinct so multiple
    # NULL request_ids are allowed. ON CONFLICT (request_id) requires a
    # non-partial unique index.
    create unique_index(:llm_usage, [:request_id], name: :llm_usage_request_id_unique)
  end

  def down do
    drop_if_exists index(:llm_usage, [:request_id], name: :llm_usage_request_id_unique)

    create unique_index(:llm_usage, [:request_id],
             where: "request_id IS NOT NULL",
             name: :llm_usage_request_id_unique
           )
  end
end
