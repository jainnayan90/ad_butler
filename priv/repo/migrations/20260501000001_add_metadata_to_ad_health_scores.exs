defmodule AdButler.Repo.Migrations.AddMetadataToAdHealthScores do
  use Ecto.Migration

  # W8D1: stores per-ad cached values that are stable across audit runs — the
  # honeymoon CTR baseline lands here first (computed once from the ad's first
  # 3 days >1000 impressions, then reused every 6h refit). Future stable
  # signals (CPM baseline, baseline quality ranking) extend the same JSONB.
  def change do
    alter table(:ad_health_scores) do
      add :metadata, :map
    end
  end
end
