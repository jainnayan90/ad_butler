defmodule AdButler.Repo.Migrations.CreateAdInsights7dView do
  use Ecto.Migration

  def up do
    execute """
    CREATE MATERIALIZED VIEW ad_insights_7d AS
    SELECT
      ad_id,
      SUM(spend_cents) AS spend_cents,
      SUM(impressions) AS impressions,
      SUM(clicks) AS clicks,
      SUM(conversions) AS conversions,
      SUM(conversion_value_cents) AS conversion_value_cents,
      CASE WHEN SUM(impressions) > 0 THEN SUM(clicks)::numeric / SUM(impressions) ELSE 0 END AS ctr,
      CASE WHEN SUM(impressions) > 0 THEN SUM(spend_cents) * 1000 / SUM(impressions) ELSE 0 END AS cpm_cents,
      CASE WHEN SUM(clicks) > 0 THEN SUM(spend_cents) / SUM(clicks) ELSE 0 END AS cpc_cents,
      CASE WHEN SUM(conversions) > 0 THEN SUM(spend_cents) / SUM(conversions) ELSE 0 END AS cpa_cents
    FROM insights_daily
    WHERE date_start >= CURRENT_DATE - INTERVAL '7 days'
    GROUP BY ad_id
    WITH NO DATA
    """

    execute "CREATE UNIQUE INDEX ON ad_insights_7d (ad_id)"
  end

  def down do
    execute "DROP MATERIALIZED VIEW IF EXISTS ad_insights_7d"
  end
end
