defmodule AdButler.Chat.Tools.CompareCreatives do
  @moduledoc """
  Read tool — aggregates 7-day insights across up to 5 of the user's ads
  so the agent can recommend a winner.

  Bulk-scopes the supplied ad_ids via `Ads.fetch_ads/2` (single scoped
  query); cross-tenant ids are silently dropped (the agent never learns
  which were rejected). Returns `{:error, :no_valid_ads}` if every ad_id
  was foreign.
  """

  use Jido.Action,
    name: "compare_creatives",
    description: "Compare 7-day delivery + health for up to 5 of the user's ads.",
    schema: [
      ad_ids: [
        type: {:list, :string},
        required: true,
        doc: "List of ad UUIDs (max 5). Cross-tenant entries are dropped silently."
      ]
    ]

  require Logger

  alias AdButler.Ads
  alias AdButler.Analytics
  alias AdButler.Analytics.AdHealthScore
  alias AdButler.Chat.Tools.Helpers

  @max_ads 5

  @impl true
  def run(%{ad_ids: ad_ids}, context) when is_list(ad_ids) do
    capped = Enum.take(ad_ids, @max_ads)

    case Helpers.context_user(context) do
      {:ok, user} ->
        case Ads.fetch_ads(user, capped) do
          [] ->
            {:error, :no_valid_ads}

          ads ->
            owned_ids = Enum.map(ads, & &1.id)
            summaries = Analytics.get_ads_delivery_summary_bulk(user, owned_ids)

            rows =
              ads
              |> Enum.map(&summary_row(&1, Map.get(summaries, &1.id, %{})))
              |> Enum.sort_by(& &1.spend_cents, :desc)

            {:ok, %{rows: rows}}
        end

      {:error, _} = err ->
        err
    end
  end

  defp summary_row(ad, summary) do
    health = Map.get(summary, :health)

    %{
      ad_id: ad.id,
      name: ad.name,
      spend_cents: Map.get(summary, :spend_cents, 0),
      impressions: Map.get(summary, :impressions, 0),
      avg_ctr: Map.get(summary, :avg_ctr),
      avg_cpm_cents: Map.get(summary, :avg_cpm_cents),
      fatigue_score: health_metric(health, :fatigue_score),
      leak_score: health_metric(health, :leak_score)
    }
  end

  defp health_metric(nil, _), do: nil

  defp health_metric(%AdHealthScore{fatigue_score: v}, :fatigue_score),
    do: Helpers.decimal_to_float(v)

  defp health_metric(%AdHealthScore{leak_score: v}, :leak_score),
    do: Helpers.decimal_to_float(v)

  # Defensive — fires if a future caller adds a third metric atom without a
  # matching head. Logs the unknown key so the gap surfaces in observability
  # rather than crashing the chat turn with FunctionClauseError.
  defp health_metric(%AdHealthScore{} = score, key) do
    Logger.warning("chat: unknown health metric key", key: key, ad_id: score.ad_id)
    nil
  end
end
