defmodule AdButler.Repo.Migrations.CreateInsightsDaily do
  use Ecto.Migration

  def up do
    execute """
    CREATE TABLE insights_daily (
      ad_id UUID NOT NULL REFERENCES ads(id) ON DELETE CASCADE,
      date_start DATE NOT NULL,
      spend_cents BIGINT NOT NULL DEFAULT 0,
      impressions BIGINT NOT NULL DEFAULT 0,
      clicks BIGINT NOT NULL DEFAULT 0,
      reach_count BIGINT NOT NULL DEFAULT 0,
      frequency NUMERIC(10,4),
      conversions BIGINT NOT NULL DEFAULT 0,
      conversion_value_cents BIGINT NOT NULL DEFAULT 0,
      ctr_numeric NUMERIC(10,6),
      cpm_cents BIGINT,
      cpc_cents BIGINT,
      cpa_cents BIGINT,
      by_placement_jsonb JSONB,
      by_age_gender_jsonb JSONB,
      inserted_at TIMESTAMP NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMP NOT NULL DEFAULT NOW(),
      PRIMARY KEY (ad_id, date_start)
    ) PARTITION BY RANGE (date_start)
    """

    execute "CREATE INDEX ON insights_daily (ad_id, date_start DESC)"
  end

  def down do
    execute "DROP TABLE IF EXISTS insights_daily"
  end
end
