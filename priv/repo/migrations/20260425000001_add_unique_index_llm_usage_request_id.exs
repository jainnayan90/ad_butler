defmodule AdButler.Repo.Migrations.AddUniqueIndexLlmUsageRequestId do
  use Ecto.Migration

  def change do
    create unique_index(:llm_usage, [:request_id],
             where: "request_id IS NOT NULL",
             name: :llm_usage_request_id_unique
           )
  end
end
