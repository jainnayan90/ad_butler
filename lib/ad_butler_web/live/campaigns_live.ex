defmodule AdButlerWeb.CampaignsLive do
  @moduledoc """
  LiveView for browsing and filtering campaigns.

  Streams campaigns for the authenticated user. Campaigns are loaded in
  `handle_params/3` (not `mount/3`) so URL filter params are honoured on
  both initial load and navigation. Filters push a `patch` so the URL stays
  in sync with the current view state.

  Authentication is enforced via `AdButlerWeb.AuthLive` on_mount hook.
  `current_user` is always present when this LiveView runs.
  """

  use AdButlerWeb, :live_view

  alias AdButler.Ads
  alias AdButlerWeb.DashboardComponents

  @valid_statuses ~w(ACTIVE PAUSED DELETED)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      send(self(), :reload_on_reconnect)
    end

    socket =
      socket
      |> stream(:campaigns, [])
      |> stream(:ad_accounts, [])
      |> assign(:selected_ad_account, nil)
      |> assign(:selected_status, nil)
      |> assign(:ad_accounts_list, [])
      |> assign(:campaign_count, 0)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    current_user = socket.assigns.current_user

    ad_account_id = params["ad_account_id"]
    status = params["status"]

    opts =
      []
      |> maybe_put(:ad_account_id, ad_account_id)
      |> maybe_put(:status, status)

    campaigns = Ads.list_campaigns(current_user, opts)

    # Load ad accounts on the first handle_params call (list empty from mount).
    # Subsequent filter navigations reuse the cached list — no re-fetch needed.
    ad_accounts =
      case socket.assigns.ad_accounts_list do
        [] -> Ads.list_ad_accounts(current_user)
        existing -> existing
      end

    socket =
      socket
      |> stream(:campaigns, campaigns, reset: true)
      |> assign(:selected_ad_account, ad_account_id)
      |> assign(:selected_status, status)
      |> assign(:campaign_count, length(campaigns))
      |> assign(:ad_accounts_list, ad_accounts)

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter", params, socket) do
    status = if params["status"] in @valid_statuses, do: params["status"]

    query =
      %{}
      |> maybe_put("ad_account_id", params["ad_account_id"])
      |> maybe_put("status", status)

    {:noreply, push_patch(socket, to: ~p"/campaigns?#{query}")}
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
          <div class="flex items-center gap-4">
            <.link href={~p"/dashboard"} class="text-sm text-gray-600 hover:text-gray-900">
              ← Dashboard
            </.link>
            <h1 class="text-xl font-semibold text-gray-900">Campaigns</h1>
          </div>
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
        <div class="mb-6">
          <DashboardComponents.stat_card label="Campaigns" value={@campaign_count} />
        </div>

        <form phx-change="filter" class="mb-6 flex flex-wrap gap-4">
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-1">Ad Account</label>
            <select
              name="ad_account_id"
              class="block w-48 rounded-md border-gray-300 shadow-sm text-sm"
            >
              <option value="">All accounts</option>
              <option
                :for={aa <- @ad_accounts_list}
                value={aa.id}
                selected={@selected_ad_account == aa.id}
              >
                {aa.name}
              </option>
            </select>
          </div>

          <div>
            <label class="block text-sm font-medium text-gray-700 mb-1">Status</label>
            <select name="status" class="block w-36 rounded-md border-gray-300 shadow-sm text-sm">
              <option value="">All statuses</option>
              <option value="ACTIVE" selected={@selected_status == "ACTIVE"}>Active</option>
              <option value="PAUSED" selected={@selected_status == "PAUSED"}>Paused</option>
              <option value="DELETED" selected={@selected_status == "DELETED"}>Deleted</option>
            </select>
          </div>
        </form>

        <div class="bg-white shadow rounded-lg">
          <div :if={@campaign_count == 0} class="px-4 py-12 text-center">
            <p class="text-gray-500">No campaigns match your filters.</p>
          </div>

          <div :if={@campaign_count > 0}>
            <.table id="campaigns" rows={@streams.campaigns}>
              <:col :let={{_id, c}} label="Name">{c.name}</:col>
              <:col :let={{_id, c}} label="Objective">{c.objective}</:col>
              <:col :let={{_id, c}} label="Status">
                <span class={campaign_status_class(c.status)}>
                  {c.status}
                </span>
              </:col>
            </.table>
          </div>
        </div>
      </main>
    </div>
    """
  end

  defp campaign_status_class("ACTIVE"),
    do: "inline-flex px-2 py-0.5 rounded text-xs font-medium bg-green-100 text-green-800"

  defp campaign_status_class("PAUSED"),
    do: "inline-flex px-2 py-0.5 rounded text-xs font-medium bg-yellow-100 text-yellow-800"

  defp campaign_status_class("DELETED"),
    do: "inline-flex px-2 py-0.5 rounded text-xs font-medium bg-red-100 text-red-800"

  defp campaign_status_class(_),
    do: "inline-flex px-2 py-0.5 rounded text-xs font-medium bg-gray-100 text-gray-800"

  @impl true
  def handle_info(:reload_on_reconnect, socket) do
    current_user = socket.assigns.current_user

    opts =
      []
      |> maybe_put(:ad_account_id, socket.assigns.selected_ad_account)
      |> maybe_put(:status, socket.assigns.selected_status)

    campaigns = Ads.list_campaigns(current_user, opts)
    ad_accounts = Ads.list_ad_accounts(current_user)

    socket =
      socket
      |> stream(:campaigns, campaigns, reset: true)
      |> stream(:ad_accounts, ad_accounts, reset: true)
      |> assign(:ad_accounts_list, ad_accounts)
      |> assign(:campaign_count, length(campaigns))

    {:noreply, socket}
  end

  defp maybe_put(acc, _key, nil), do: acc
  defp maybe_put(acc, _key, ""), do: acc
  defp maybe_put(acc, key, value) when is_map(acc), do: Map.put(acc, key, value)
  defp maybe_put(acc, key, value) when is_list(acc), do: Keyword.put(acc, key, value)
end
