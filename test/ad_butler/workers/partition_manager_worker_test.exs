defmodule AdButler.Workers.PartitionManagerWorkerTest do
  # async: false — DDL touches shared pg_inherits
  use AdButler.DataCase, async: false
  use Oban.Testing, repo: AdButler.Repo

  alias AdButler.Repo
  alias AdButler.Workers.PartitionManagerWorker

  defp partition_count do
    %{rows: [[n]]} =
      Repo.query!("""
      SELECT COUNT(*) FROM pg_inherits
      JOIN pg_class parent ON parent.oid = pg_inherits.inhparent
      WHERE parent.relname = 'insights_daily'
      """)

    n
  end

  defp create_old_partition do
    # Create a partition for a date > 13 months ago so it qualifies for detachment
    old_date = Date.add(Date.utc_today(), -400)
    {iso_year, week} = :calendar.iso_week_number({old_date.year, old_date.month, old_date.day})
    week_str = String.pad_leading(Integer.to_string(week), 2, "0")
    partition_name = "insights_daily_#{iso_year}_W#{week_str}"

    # Calculate week bounds
    day_of_week = Date.day_of_week(old_date, :monday)
    week_start = Date.add(old_date, -(day_of_week - 1))
    week_end = Date.add(week_start, 7)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS "#{partition_name}"
    PARTITION OF insights_daily
    FOR VALUES FROM ('#{Date.to_iso8601(week_start)}') TO ('#{Date.to_iso8601(week_end)}')
    """)

    partition_name
  end

  describe "perform/1" do
    test "ensures future partitions exist and job completes successfully" do
      before_count = partition_count()
      assert :ok = perform_job(PartitionManagerWorker, %{})
      # Count stays >= before: existing partitions survive and no errors occur
      assert partition_count() >= before_count
    end

    test "is idempotent — second perform creates 0 new partitions" do
      assert :ok = perform_job(PartitionManagerWorker, %{})
      count_after_first = partition_count()

      assert :ok = perform_job(PartitionManagerWorker, %{})
      assert partition_count() == count_after_first
    end

    test "detaches partitions older than 13 months" do
      partition_name = create_old_partition()
      before_count = partition_count()
      assert before_count >= 1

      assert :ok = perform_job(PartitionManagerWorker, %{})

      after_count = partition_count()
      assert after_count < before_count

      # The partition table still exists but is no longer attached
      %{rows: rows} =
        Repo.query!("""
        SELECT relname FROM pg_class WHERE relname = '#{partition_name}'
        """)

      assert rows != []
    end
  end
end
