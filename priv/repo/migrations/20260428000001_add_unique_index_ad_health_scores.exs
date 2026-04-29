defmodule AdButler.Repo.Migrations.AddUniqueIndexAdHealthScores do
  use Ecto.Migration

  def change do
    create unique_index(:ad_health_scores, [:ad_id, :computed_at],
             name: :ad_health_scores_ad_id_computed_at_unique
           )
  end
end
