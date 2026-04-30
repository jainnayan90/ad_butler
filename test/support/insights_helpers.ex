defmodule AdButler.InsightsHelpers do
  @moduledoc false
  # Canonical `insert_daily/3` for tests that seed `insights_daily` rows.
  # Replaces the previously-duplicated copies in `analytics_test.exs` and
  # `creative_fatigue_predictor_worker_test.exs`. Accepts every column the
  # heuristics inspect; defaults match what either test expected.

  alias AdButler.Repo

  @doc """
  Inserts one `insights_daily` row for `ad`, dated `days_ago` days back from
  today. `attrs` is a map of optional column overrides:

    * `:spend_cents` (default 0)
    * `:impressions` (default 0)
    * `:clicks` (default 0)
    * `:reach_count` (default 0)
    * `:frequency` (default nil — ad never ran)
    * `:conversions` (default 0)
    * `:conversion_value_cents` (default 0)
    * `:ctr_numeric` (default `Decimal.new("0.0")`)
    * `:cpm_cents` (default nil)
    * `:by_placement_jsonb` (default nil)

  Tests that need the partition created should call
  `Repo.query!("SELECT create_insights_partition(...)")` in their own setup.
  """
  @spec insert_daily(map(), non_neg_integer(), map()) ::
          {non_neg_integer(), nil | [term()]}
  def insert_daily(ad, days_ago, attrs \\ %{}) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Repo.insert_all("insights_daily", [
      %{
        ad_id: Ecto.UUID.dump!(ad.id),
        date_start: Date.add(Date.utc_today(), -days_ago),
        spend_cents: Map.get(attrs, :spend_cents, 0),
        impressions: Map.get(attrs, :impressions, 0),
        clicks: Map.get(attrs, :clicks, 0),
        reach_count: Map.get(attrs, :reach_count, 0),
        frequency: Map.get(attrs, :frequency, nil),
        conversions: Map.get(attrs, :conversions, 0),
        conversion_value_cents: Map.get(attrs, :conversion_value_cents, 0),
        ctr_numeric: Map.get(attrs, :ctr_numeric, Decimal.new("0.0")),
        cpm_cents: Map.get(attrs, :cpm_cents, nil),
        by_placement_jsonb: Map.get(attrs, :by_placement_jsonb, nil),
        inserted_at: now,
        updated_at: now
      }
    ])
  end
end
