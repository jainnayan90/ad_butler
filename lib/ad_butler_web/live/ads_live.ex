defmodule AdButlerWeb.AdsLive do
  @moduledoc """
  LiveView for browsing and filtering ads.

  Streams a paginated page of ads for the authenticated user. Loaded in
  `handle_params/3` so URL filter and page params are honoured on both initial
  load and navigation. Filters and pagination push a `patch` to keep the URL
  in sync.

  Authentication is enforced via `AdButlerWeb.AuthLive` on_mount hook.
  """

  use AdButlerWeb, :live_view

  alias AdButler.Accounts
  alias AdButler.Ads
  alias AdButlerWeb.DashboardComponents

  @per_page 50
  @valid_statuses ~w(ACTIVE PAUSED DELETED)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      send(self(), :reload_on_reconnect)
    end

    socket =
      socket
      |> stream(:ads, [])
      |> assign(:active_nav, :ads)
      |> assign(:selected_ad_account, nil)
      |> assign(:selected_status, nil)
      |> assign(:ad_accounts_list, [])
      |> assign(:ad_count, 0)
      |> assign(:page, 1)
      |> assign(:total_pages, 1)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    current_user = socket.assigns.current_user

    ad_account_id = params["ad_account_id"]
    status = params["status"]
    page = parse_page(params["page"])

    opts =
      []
      |> maybe_put(:ad_account_id, ad_account_id)
      |> maybe_put(:status, status)
      |> Keyword.put(:page, page)
      |> Keyword.put(:per_page, @per_page)

    {ads, total} = Ads.paginate_ads(current_user, opts)
    total_pages = max(1, ceil(total / @per_page))

    ad_accounts =
      case socket.assigns.ad_accounts_list do
        [] -> Ads.list_ad_accounts(current_user)
        existing -> existing
      end

    socket =
      socket
      |> stream(:ads, ads, reset: true)
      |> assign(:selected_ad_account, ad_account_id)
      |> assign(:selected_status, status)
      |> assign(:ad_count, total)
      |> assign(:page, page)
      |> assign(:total_pages, total_pages)
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

    {:noreply, push_patch(socket, to: ~p"/ads?#{query}")}
  end

  @impl true
  def handle_event("paginate", %{"page" => page}, socket) do
    query =
      %{}
      |> maybe_put("ad_account_id", socket.assigns.selected_ad_account)
      |> maybe_put("status", socket.assigns.selected_status)
      |> Map.put("page", page)

    {:noreply, push_patch(socket, to: ~p"/ads?#{query}")}
  end

  @impl true
  def handle_info(:reload_on_reconnect, socket) do
    mc_ids = Accounts.list_meta_connection_ids_for_user(socket.assigns.current_user)

    opts =
      []
      |> maybe_put(:ad_account_id, socket.assigns.selected_ad_account)
      |> maybe_put(:status, socket.assigns.selected_status)
      |> Keyword.put(:page, socket.assigns.page)
      |> Keyword.put(:per_page, @per_page)

    {ads, total} = Ads.paginate_ads(mc_ids, opts)
    total_pages = max(1, ceil(total / @per_page))
    ad_accounts = Ads.list_ad_accounts(mc_ids)

    socket =
      socket
      |> stream(:ads, ads, reset: true)
      |> assign(:ad_accounts_list, ad_accounts)
      |> assign(:ad_count, total)
      |> assign(:total_pages, total_pages)

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="mb-6">
        <h1 class="text-2xl font-semibold text-gray-900 mb-4">Ads</h1>
        <DashboardComponents.stat_card label="Ads" value={@ad_count} />
      </div>

      <form phx-change="filter" class="mb-6 flex flex-wrap gap-4">
        <div>
          <label class="block text-sm font-medium text-gray-700 mb-1">Ad Account</label>
          <select
            name="ad_account_id"
            class="block w-48 rounded-md border border-gray-300 bg-white py-2 pl-3 pr-3 text-sm text-gray-900 shadow-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
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
          <select
            name="status"
            class="block w-36 rounded-md border border-gray-300 bg-white py-2 pl-3 pr-3 text-sm text-gray-900 shadow-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
          >
            <option value="">All statuses</option>
            <option value="ACTIVE" selected={@selected_status == "ACTIVE"}>Active</option>
            <option value="PAUSED" selected={@selected_status == "PAUSED"}>Paused</option>
            <option value="DELETED" selected={@selected_status == "DELETED"}>Deleted</option>
          </select>
        </div>
      </form>

      <div class="bg-white shadow rounded-lg">
        <div :if={@ad_count == 0} class="px-4 py-12 text-center">
          <p class="text-gray-500">No ads match your filters.</p>
        </div>

        <div :if={@ad_count > 0}>
          <.table id="ads" rows={@streams.ads}>
            <:col :let={{_id, a}} label="Name">{a.name}</:col>
            <:col :let={{_id, a}} label="Status">
              <span class={status_badge_class(a.status)}>{a.status}</span>
            </:col>
          </.table>
          <.pagination page={@page} total_pages={@total_pages} />
        </div>
      </div>
    </div>
    """
  end

  defp status_badge_class("ACTIVE"),
    do: "inline-flex px-2 py-0.5 rounded text-xs font-medium bg-green-100 text-green-800"

  defp status_badge_class("PAUSED"),
    do: "inline-flex px-2 py-0.5 rounded text-xs font-medium bg-yellow-100 text-yellow-800"

  defp status_badge_class("DELETED"),
    do: "inline-flex px-2 py-0.5 rounded text-xs font-medium bg-red-100 text-red-800"

  defp status_badge_class(_),
    do: "inline-flex px-2 py-0.5 rounded text-xs font-medium bg-gray-100 text-gray-800"

  defp parse_page(nil), do: 1

  defp parse_page(p) when is_binary(p) do
    case Integer.parse(p) do
      {n, ""} when n > 0 -> n
      _ -> 1
    end
  end

  defp maybe_put(acc, _key, nil), do: acc
  defp maybe_put(acc, _key, ""), do: acc
  defp maybe_put(acc, key, value) when is_map(acc), do: Map.put(acc, key, value)
  defp maybe_put(acc, key, value) when is_list(acc), do: Keyword.put(acc, key, value)
end
