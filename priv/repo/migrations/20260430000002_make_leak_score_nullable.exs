defmodule AdButler.Repo.Migrations.MakeLeakScoreNullable do
  use Ecto.Migration

  # leak_score and fatigue_score are independent signals computed by separate
  # workers. Either may write a row first; the column-level NOT NULL on
  # leak_score forced the fatigue worker to backfill a fake zero. Drop the
  # constraint so each worker writes only its own column on conflict.
  def up do
    alter table(:ad_health_scores) do
      modify :leak_score, :decimal, precision: 5, scale: 2, null: true
    end
  end

  def down do
    # Backfill any null leak_score with 0 before re-imposing NOT NULL.
    execute "UPDATE ad_health_scores SET leak_score = 0 WHERE leak_score IS NULL"

    alter table(:ad_health_scores) do
      modify :leak_score, :decimal, precision: 5, scale: 2, null: false
    end
  end
end
