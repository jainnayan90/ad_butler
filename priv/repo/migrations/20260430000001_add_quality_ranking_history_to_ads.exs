defmodule AdButler.Repo.Migrations.AddQualityRankingHistoryToAds do
  use Ecto.Migration

  # Append-only JSONB log of {date, quality_ranking, engagement_rate_ranking,
  # conversion_rate_ranking} snapshots used by the creative-fatigue predictor
  # (heuristic_quality_drop). Cap of 14 entries enforced in app code on append —
  # the column itself imposes no size limit.
  def change do
    alter table(:ads) do
      add :quality_ranking_history, :map, default: %{"snapshots" => []}
    end
  end
end
