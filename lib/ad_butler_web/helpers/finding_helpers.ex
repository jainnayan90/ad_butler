defmodule AdButlerWeb.FindingHelpers do
  @moduledoc "Shared rendering helpers for finding severity and kind labels."

  @doc "Returns Tailwind CSS classes for a severity badge."
  @spec severity_badge_class(String.t()) :: String.t()
  def severity_badge_class("high"),
    do: "inline-flex px-2 py-0.5 rounded text-xs font-medium bg-red-100 text-red-700"

  def severity_badge_class("medium"),
    do: "inline-flex px-2 py-0.5 rounded text-xs font-medium bg-yellow-100 text-yellow-700"

  def severity_badge_class("low"),
    do: "inline-flex px-2 py-0.5 rounded text-xs font-medium bg-blue-100 text-blue-700"

  def severity_badge_class(_),
    do: "inline-flex px-2 py-0.5 rounded text-xs font-medium bg-gray-100 text-gray-700"

  @doc "Returns a human-readable label for a finding kind."
  @spec kind_label(String.t()) :: String.t()
  def kind_label("dead_spend"), do: "Dead Spend"
  def kind_label("cpa_explosion"), do: "CPA Explosion"
  def kind_label("bot_traffic"), do: "Bot Traffic"
  def kind_label("placement_drag"), do: "Placement Drag"
  def kind_label("stalled_learning"), do: "Stalled Learning"
  def kind_label("creative_fatigue"), do: "Creative Fatigue"
  def kind_label("frequency_ctr_decay"), do: "Frequency + CTR decay"
  def kind_label("quality_drop"), do: "Quality ranking drop"
  def kind_label("cpm_saturation"), do: "CPM saturation"
  def kind_label(other), do: other
end
