defmodule AdButler.Repo.Migrations.CreateAdHealthScores do
  use Ecto.Migration

  def change do
    create table(:ad_health_scores, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :ad_id, references(:ads, type: :binary_id, on_delete: :delete_all), null: false
      add :computed_at, :utc_datetime_usec, null: false
      add :leak_score, :decimal, precision: 5, scale: 2, null: false
      add :fatigue_score, :decimal, precision: 5, scale: 2
      add :leak_factors, :map
      add :fatigue_factors, :map
      add :recommended_action, :string
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("NOW()")
    end

    execute(
      "CREATE INDEX ad_health_scores_ad_id_computed_at_index ON ad_health_scores (ad_id, computed_at DESC)",
      "DROP INDEX IF EXISTS ad_health_scores_ad_id_computed_at_index"
    )
  end
end
