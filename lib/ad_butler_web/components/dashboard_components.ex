defmodule AdButlerWeb.DashboardComponents do
  @moduledoc """
  Reusable function components shared across Dashboard and Campaigns LiveViews.

  Components here are purposely generic — they accept plain assigns and carry
  no business logic. Use `DashboardLive` or `CampaignsLive` for data loading.
  """

  use Phoenix.Component

  @doc """
  Renders a stat card with a label and integer count value.

  ## Attributes

  - `label` — display label shown below the value
  - `value` — integer count displayed prominently
  """
  attr :label, :string, required: true
  attr :value, :integer, required: true

  def stat_card(assigns) do
    ~H"""
    <div class="bg-white overflow-hidden shadow rounded-lg">
      <div class="px-4 py-5 sm:p-6">
        <dt class="text-sm font-medium text-gray-500 truncate">{@label}</dt>
        <dd class="mt-1 text-3xl font-semibold text-gray-900">{@value}</dd>
      </div>
    </div>
    """
  end
end
