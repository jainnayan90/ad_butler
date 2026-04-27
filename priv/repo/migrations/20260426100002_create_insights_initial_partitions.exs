defmodule AdButler.Repo.Migrations.CreateInsightsInitialPartitions do
  use Ecto.Migration

  def up do
    # Create current week + next 3 weeks (4 partitions total)
    execute """
    CREATE OR REPLACE FUNCTION create_insights_partition(p_date DATE)
    RETURNS VOID AS $$
    DECLARE
      week_start DATE;
      week_end DATE;
      partition_name TEXT;
    BEGIN
      week_start := date_trunc('week', p_date)::DATE;
      week_end := (week_start + INTERVAL '7 days')::DATE;
      partition_name := 'insights_daily_' || to_char(week_start, 'YYYY') || '_W' || to_char(week_start, 'IW');

      EXECUTE format(
        'CREATE TABLE IF NOT EXISTS %I PARTITION OF insights_daily FOR VALUES FROM (%L) TO (%L)',
        partition_name, week_start, week_end
      );
    END;
    $$ LANGUAGE plpgsql;
    """

    execute "SELECT create_insights_partition(CURRENT_DATE::DATE)"
    execute "SELECT create_insights_partition((CURRENT_DATE + INTERVAL '7 days')::DATE)"
    execute "SELECT create_insights_partition((CURRENT_DATE + INTERVAL '14 days')::DATE)"
    execute "SELECT create_insights_partition((CURRENT_DATE + INTERVAL '21 days')::DATE)"
  end

  def down do
    execute """
    DO $$
    DECLARE r RECORD;
    BEGIN
      FOR r IN SELECT child.relname FROM pg_inherits
               JOIN pg_class child ON child.oid = pg_inherits.inhrelid
               JOIN pg_class parent ON parent.oid = pg_inherits.inhparent
               WHERE parent.relname = 'insights_daily'
      LOOP
        EXECUTE 'DROP TABLE IF EXISTS ' || quote_ident(r.relname);
      END LOOP;
    END $$;
    """

    execute "DROP FUNCTION IF EXISTS create_insights_partition(DATE)"
  end
end
