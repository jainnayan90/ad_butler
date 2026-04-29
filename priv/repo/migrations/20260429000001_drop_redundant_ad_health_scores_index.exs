defmodule AdButler.Repo.Migrations.DropRedundantAdHealthScoresIndex do
  use Ecto.Migration

  def change do
    execute(
      "DROP INDEX IF EXISTS ad_health_scores_ad_id_computed_at_index",
      "CREATE INDEX ad_health_scores_ad_id_computed_at_index ON ad_health_scores (ad_id, computed_at DESC)"
    )
  end
end
