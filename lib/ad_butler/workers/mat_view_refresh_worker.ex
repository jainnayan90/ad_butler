defmodule AdButler.Workers.MatViewRefreshWorker do
  @moduledoc """
  Oban worker that refreshes `ad_insights_7d` and `ad_insights_30d` materialized views.

  Dispatched via cron with `%{"view" => "7d"}` (every 15 min) or
  `%{"view" => "30d"}` (every hour). Delegates to `AdButler.Analytics.refresh_view/1`.
  """
  use Oban.Worker, queue: :analytics, max_attempts: 3

  alias AdButler.Analytics

  @doc ~S'Refreshes `ad_insights_7d` (args `%{"view" => "7d"}`) or `ad_insights_30d` (args `%{"view" => "30d"}`).'
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"view" => period}}) do
    refresh_fn().(period)
  end

  defp refresh_fn do
    Application.get_env(:ad_butler, :analytics_refresh_fn, &Analytics.refresh_view/1)
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)
end
