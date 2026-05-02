defmodule AdButler.Chat.Tools.GetInsightsSeries do
  @moduledoc """
  Read tool — returns a time series of one metric for one ad over a 7- or
  30-day window. Output drives Week 10's chart rendering; Week 9 produces
  the data shape only.

  Caps the series at 30 points (natural ceiling of `:last_30d`). Re-scopes
  via `Ads.fetch_ad/2`; cross-tenant id → `{:error, :not_found}`.
  """

  use Jido.Action,
    name: "get_insights_series",
    description: "Time-series data (last 7 or 30 days) for one metric on one ad.",
    schema: [
      ad_id: [type: :string, required: true],
      metric: [
        type: {:in, ["spend", "impressions", "ctr", "cpm", "cpc", "cpa"]},
        required: true
      ],
      window: [
        type: {:in, ["last_7d", "last_30d"]},
        default: "last_7d"
      ]
    ]

  alias AdButler.Ads
  alias AdButler.Analytics
  alias AdButler.Chat.Tools.Helpers

  @impl true
  def run(%{ad_id: ad_id, metric: metric} = params, context) do
    window = Map.get(params, :window, "last_7d")

    with {:ok, user} <- Helpers.context_user(context),
         {:ok, ad} <- Ads.fetch_ad(user, ad_id),
         {:ok, metric_atom} <- metric_to_atom(metric),
         {:ok, window_atom} <- window_to_atom(window) do
      series = Analytics.get_insights_series(ad.id, metric_atom, window_atom)
      {:ok, series}
    end
  end

  defp metric_to_atom("spend"), do: {:ok, :spend}
  defp metric_to_atom("impressions"), do: {:ok, :impressions}
  defp metric_to_atom("ctr"), do: {:ok, :ctr}
  defp metric_to_atom("cpm"), do: {:ok, :cpm}
  defp metric_to_atom("cpc"), do: {:ok, :cpc}
  defp metric_to_atom("cpa"), do: {:ok, :cpa}
  defp metric_to_atom(_), do: {:error, :invalid_metric}

  defp window_to_atom("last_7d"), do: {:ok, :last_7d}
  defp window_to_atom("last_30d"), do: {:ok, :last_30d}
  defp window_to_atom(_), do: {:error, :invalid_window}
end
