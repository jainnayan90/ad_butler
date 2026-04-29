defmodule AdButlerWeb.FindingDetailLive do
  @moduledoc """
  LiveView for viewing a single budget-leak finding in detail.

  Displays the finding's title, body, severity, evidence, and the ad's latest
  health score. Allows the authenticated user to acknowledge the finding.
  Access is scoped — unauthorized finding IDs raise to a 404.
  """

  use AdButlerWeb, :live_view

  import AdButlerWeb.FindingHelpers

  alias AdButler.Analytics

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:active_nav, :findings)
     |> assign(:finding, nil)
     |> assign(:health_score, nil)}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    if connected?(socket) do
      current_user = socket.assigns.current_user

      case Analytics.get_finding(current_user, id) do
        {:ok, finding} ->
          health_score = Analytics.unsafe_get_latest_health_score(finding.ad_id)

          {:noreply,
           socket
           |> assign(:finding, finding)
           |> assign(:health_score, health_score)}

        {:error, :not_found} ->
          {:noreply,
           socket
           |> put_flash(:error, "Finding not found.")
           |> push_navigate(to: ~p"/findings")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("acknowledge", _params, %{assigns: %{finding: nil}} = socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("acknowledge", _params, socket) do
    current_user = socket.assigns.current_user

    case Analytics.acknowledge_finding(current_user, socket.assigns.finding.id) do
      {:ok, finding} ->
        {:noreply, assign(socket, :finding, finding)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not acknowledge finding.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div :if={@finding} class="max-w-4xl mx-auto">
      <div class="mb-6">
        <.link navigate={~p"/findings"} class="text-sm text-blue-600 hover:text-blue-800">
          &larr; Back to Findings
        </.link>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <%!-- Left column: finding detail --%>
        <div class="bg-white shadow rounded-lg p-6">
          <div class="flex items-start justify-between mb-4">
            <h2 class="text-xl font-semibold text-gray-900">{@finding.title}</h2>
            <span class={severity_badge_class(@finding.severity)}>
              {String.capitalize(@finding.severity)}
            </span>
          </div>

          <p class="text-gray-700 mb-4">{@finding.body}</p>

          <dl class="space-y-2 text-sm">
            <div class="flex gap-2">
              <dt class="font-medium text-gray-500 w-24">Kind</dt>
              <dd class="text-gray-900">{kind_label(@finding.kind)}</dd>
            </div>
            <div class="flex gap-2">
              <dt class="font-medium text-gray-500 w-24">Detected</dt>
              <dd class="text-gray-900">
                {Calendar.strftime(@finding.inserted_at, "%b %d, %Y")}
              </dd>
            </div>
            <div :if={@finding.acknowledged_at} class="flex gap-2">
              <dt class="font-medium text-gray-500 w-24">Acknowledged</dt>
              <dd class="text-gray-900">
                {Calendar.strftime(@finding.acknowledged_at, "%b %d, %Y")}
              </dd>
            </div>
          </dl>

          <div :if={!@finding.acknowledged_at} class="mt-6">
            <button
              phx-click="acknowledge"
              class="px-4 py-2 text-sm font-medium text-white bg-blue-600 rounded-md hover:bg-blue-700 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2"
            >
              Acknowledge
            </button>
          </div>
          <div :if={@finding.acknowledged_at} class="mt-6">
            <span class="inline-flex items-center gap-1.5 text-sm text-green-700">
              <span class="inline-block size-2 rounded-full bg-green-500"></span> Acknowledged
            </span>
          </div>
        </div>

        <%!-- Right column: health score --%>
        <div class="bg-white shadow rounded-lg p-6">
          <h3 class="text-lg font-semibold text-gray-900 mb-4">Health Score</h3>

          <div :if={@health_score} class="space-y-4">
            <div>
              <p class="text-sm text-gray-500 mb-1">Leak Score</p>
              <div class="flex items-center gap-3">
                <div class="flex-1 bg-gray-200 rounded-full h-2.5">
                  <div
                    class={leak_score_bar_class(@health_score.leak_score)}
                    style={"width: #{min(Decimal.to_float(@health_score.leak_score), 100)}%"}
                  >
                  </div>
                </div>
                <span class="text-sm font-semibold text-gray-700">
                  {Decimal.round(@health_score.leak_score, 0)}/100
                </span>
              </div>
            </div>

            <div :if={map_size(@health_score.leak_factors || %{}) > 0}>
              <p class="text-sm text-gray-500 mb-2">Contributing Factors</p>
              <ul class="space-y-1">
                <li
                  :for={{factor, weight} <- @health_score.leak_factors}
                  class="flex justify-between text-sm"
                >
                  <span class="text-gray-700">{kind_label(factor)}</span>
                  <span class="font-medium text-gray-900">+{weight}</span>
                </li>
              </ul>
            </div>

            <p class="text-xs text-gray-400">
              Computed {Calendar.strftime(@health_score.computed_at, "%b %d, %Y %H:%M UTC")}
            </p>
          </div>

          <div :if={!@health_score} class="text-sm text-gray-500">
            No health score computed yet.
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp leak_score_bar_class(score) do
    score_float = Decimal.to_float(score)
    base = "h-2.5 rounded-full "

    cond do
      score_float >= 60 -> base <> "bg-red-500"
      score_float >= 30 -> base <> "bg-yellow-500"
      true -> base <> "bg-green-500"
    end
  end
end
