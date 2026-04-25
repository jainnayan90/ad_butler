defmodule AdButlerWeb.DashboardLive do
  @moduledoc """
  LiveView for the authenticated user dashboard.

  Streams all `AdAccount` records accessible to the current user. Displays
  a stat card with the total account count, an ad account table, and an empty
  state with a "Connect Meta Account" link when no accounts exist.

  Authentication is enforced via the `AdButlerWeb.AuthLive` on_mount hook
  wired in the `live_session :authenticated` router block — `current_user`
  is always present on the socket when this LiveView runs.
  """

  use AdButlerWeb, :live_view

  alias AdButler.Ads
  alias AdButlerWeb.DashboardComponents

  @impl true
  def handle_info(:reload_on_reconnect, socket) do
    current_user = socket.assigns.current_user
    ad_accounts = Ads.list_ad_accounts(current_user)

    socket =
      socket
      |> stream(:ad_accounts, ad_accounts, reset: true)
      |> assign(:ad_account_count, length(ad_accounts))

    {:noreply, socket}
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      send(self(), :reload_on_reconnect)
    end

    {:ok, socket |> stream(:ad_accounts, []) |> assign(:ad_account_count, 0)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="reconnect-banner"
      class="hidden fixed top-0 inset-x-0 z-50 flex justify-center"
      phx-disconnected={JS.show(to: "#reconnect-banner")}
      phx-connected={JS.hide(to: "#reconnect-banner")}
    >
      <div class="bg-yellow-400 text-yellow-900 text-sm font-medium px-4 py-2 rounded-b-md shadow">
        Reconnecting…
      </div>
    </div>
    <div class="min-h-screen bg-gray-50">
      <header class="bg-white shadow-sm">
        <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-4 flex items-center justify-between">
          <h1 class="text-xl font-semibold text-gray-900">AdButler</h1>
          <div class="flex items-center gap-4">
            <span class="text-sm text-gray-600">{@current_user.email}</span>
            <.link
              method="delete"
              href={~p"/auth/logout"}
              class="text-sm text-red-600 hover:text-red-800"
            >
              Logout
            </.link>
          </div>
        </div>
      </header>

      <main class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="mb-8">
          <DashboardComponents.stat_card label="Ad Accounts" value={@ad_account_count} />
        </div>

        <div class="bg-white shadow rounded-lg">
          <div class="px-4 py-5 sm:px-6 border-b border-gray-200">
            <h2 class="text-lg font-medium text-gray-900">Ad Accounts</h2>
          </div>

          <div :if={@ad_account_count == 0} class="px-4 py-12 text-center">
            <p class="text-gray-500 mb-4">No ad accounts connected yet.</p>
            <.link
              href={~p"/auth/meta"}
              class="inline-flex items-center px-4 py-2 bg-blue-600 text-white text-sm font-medium rounded-md hover:bg-blue-700"
            >
              Connect Meta Account
            </.link>
          </div>

          <div :if={@ad_account_count > 0}>
            <.table id="ad-accounts" rows={@streams.ad_accounts}>
              <:col :let={{_id, aa}} label="Name">{aa.name}</:col>
              <:col :let={{_id, aa}} label="Currency">{aa.currency}</:col>
              <:col :let={{_id, aa}} label="Timezone">{aa.timezone_name}</:col>
              <:col :let={{_id, aa}} label="Status">
                <span class={status_class(aa.status)}>
                  {aa.status}
                </span>
              </:col>
            </.table>
          </div>
        </div>

        <div class="mt-6">
          <.link href={~p"/campaigns"} class="text-blue-600 hover:text-blue-800 text-sm font-medium">
            View Campaigns →
          </.link>
        </div>
      </main>
    </div>
    """
  end

  defp status_class("ACTIVE"),
    do: "inline-flex px-2 py-0.5 rounded text-xs font-medium bg-green-100 text-green-800"

  defp status_class(_),
    do: "inline-flex px-2 py-0.5 rounded text-xs font-medium bg-gray-100 text-gray-800"
end
