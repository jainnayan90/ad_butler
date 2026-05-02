defmodule AdButler.Chat.Tools.SimulateBudgetChange do
  @moduledoc """
  Read-only tool — projects how a budget change on an ad set might affect
  reach + frequency, given the past 30 days of delivery.

  No Meta API call, no DB writes. Pure function of historical
  `insights_daily` data + a saturation curve. Confidence drops to `:low`
  when fewer than 7 days of data are observed.

  ## Saturation model

  Approximate reach response under a budget change:

      projected_reach = current_reach × (1 - exp(-spend_ratio · k))

  with `spend_ratio = new_spend / current_spend` (and asymptotic at
  `1 - 1/e ≈ 63%` of the upper-bound cap when `spend_ratio · k ≈ 1`). The
  saturation constant `k = #{0.7}` is a hand-tuned default — eval harness
  in W11 will revisit. The model is **directional, not predictive**: agents
  should describe outputs as estimates with caveats.
  """

  use Jido.Action,
    name: "simulate_budget_change",
    description:
      "Project reach + frequency for a hypothetical budget change on an ad set (read-only).",
    schema: [
      ad_set_id: [type: :string, required: true],
      new_budget_cents: [type: :pos_integer, required: true]
    ]

  alias AdButler.Ads
  alias AdButler.Analytics
  alias AdButler.Chat.Tools.Helpers

  @saturation_constant 0.7
  @low_confidence_days 7
  @high_confidence_days 21

  @impl true
  def run(%{ad_set_id: ad_set_id, new_budget_cents: new_budget}, context) do
    with {:ok, user} <- Helpers.context_user(context),
         {:ok, ad_set} <- Ads.fetch_ad_set(user, ad_set_id) do
      ad_ids = Ads.list_ad_ids_in_ad_set(ad_set.id)
      summary = Analytics.get_ad_set_delivery_summary(ad_ids, 30)
      current_budget = ad_set.daily_budget_cents || ad_set.lifetime_budget_cents || 0

      {:ok, project(ad_set, current_budget, new_budget, summary)}
    end
  end

  defp project(ad_set, current_budget, new_budget, summary) do
    spend_ratio = budget_ratio(current_budget, new_budget)
    growth = 1.0 - :math.exp(-spend_ratio * @saturation_constant)
    base_reach = summary.reach_estimate

    projected_reach = trunc(base_reach * growth)
    projected_freq = projected_frequency(summary, projected_reach)

    %{
      ad_set_id: ad_set.id,
      current_budget_cents: current_budget,
      new_budget_cents: new_budget,
      observed_30d: summary,
      projected_reach: projected_reach,
      projected_frequency: projected_freq,
      saturation_warning: spend_ratio * @saturation_constant > 1.5,
      confidence: confidence(summary.days_with_data)
    }
  end

  defp budget_ratio(0, _new), do: 1.0
  defp budget_ratio(current, new) when current > 0, do: new / current
  defp budget_ratio(_, _), do: 1.0

  defp projected_frequency(%{frequency_estimate: freq}, _reach) when is_number(freq), do: freq
  defp projected_frequency(_summary, _reach), do: 0.0

  defp confidence(days) when days >= @high_confidence_days, do: :high
  defp confidence(days) when days >= @low_confidence_days, do: :medium
  defp confidence(_), do: :low
end
