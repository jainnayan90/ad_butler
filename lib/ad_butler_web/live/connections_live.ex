defmodule AdButlerWeb.ConnectionsLive do
  @moduledoc """
  LiveView for managing Meta OAuth connections.

  Lists all MetaConnections for the authenticated user (regardless of status),
  shows status badges, and provides an "Add Connection" button that starts the
  Meta OAuth flow. A "Reconnect" link appears on non-active connections.
  """

  use AdButlerWeb, :live_view

  alias AdButler.Accounts

  @per_page 50

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:active_nav, :connections)
      |> assign(:page, 1)
      |> assign(:total_pages, 1)
      |> assign(:connection_count, 0)
      |> stream(:connections, [])

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    page = parse_page(params["page"])

    socket =
      if connected?(socket) do
        {items, total} =
          Accounts.paginate_meta_connections(socket.assigns.current_user,
            page: page,
            per_page: @per_page
          )

        total_pages = max(1, ceil(total / @per_page))

        socket
        |> stream(:connections, items, reset: true)
        |> assign(:page, page)
        |> assign(:total_pages, total_pages)
        |> assign(:connection_count, total)
      else
        socket
        |> stream(:connections, [], reset: true)
        |> assign(:page, page)
        |> assign(:total_pages, 1)
      end

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between mb-6">
        <h1 class="text-2xl font-semibold text-gray-900">Connections</h1>
        <a
          href={~p"/auth/meta"}
          class="inline-flex items-center gap-2 px-4 py-2 bg-blue-600 text-white text-sm font-medium rounded-md hover:bg-blue-700"
        >
          <.icon name="hero-plus" class="size-4" /> Add Connection
        </a>
      </div>

      <div :if={@connection_count == 0} class="text-center py-16">
        <.icon name="hero-link" class="size-12 text-gray-400 mx-auto mb-4" />
        <p class="text-gray-500 mb-4">No Meta connections yet.</p>
        <a
          href={~p"/auth/meta"}
          class="inline-flex items-center px-4 py-2 bg-blue-600 text-white text-sm font-medium rounded-md hover:bg-blue-700"
        >
          Connect Meta Account
        </a>
      </div>

      <div :if={@connection_count > 0} class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
        <div
          :for={{_dom_id, conn} <- @streams.connections}
          class="bg-white rounded-lg border border-gray-200 shadow-sm p-5 flex flex-col gap-3"
        >
          <div class="flex items-center justify-between">
            <span class="text-sm font-medium text-gray-900">Meta Account</span>
            <span class={connection_badge_class(conn.status)}>
              {conn.status}
            </span>
          </div>

          <p class="text-xs text-gray-500 font-mono">{conn.meta_user_id}</p>

          <div class="text-xs text-gray-500 space-y-1">
            <p>
              Connected: {Calendar.strftime(conn.inserted_at, "%b %d, %Y")}
            </p>
            <p :if={conn.token_expires_at}>
              Expires: {Calendar.strftime(conn.token_expires_at, "%b %d, %Y")}
            </p>
          </div>

          <a
            :if={conn.status != "active"}
            href={~p"/auth/meta"}
            class="mt-1 inline-flex items-center gap-1 text-sm text-blue-600 hover:text-blue-800 font-medium"
          >
            <.icon name="hero-arrow-path" class="size-4" /> Reconnect
          </a>
        </div>
      </div>

      <.pagination page={@page} total_pages={@total_pages} />
    </div>
    """
  end

  defp parse_page(nil), do: 1

  defp parse_page(p) when is_binary(p) do
    case Integer.parse(p) do
      {n, ""} when n > 0 -> n
      _ -> 1
    end
  end

  defp connection_badge_class("active"),
    do: "inline-flex px-2 py-0.5 rounded text-xs font-medium bg-green-100 text-green-800"

  defp connection_badge_class("expired"),
    do: "inline-flex px-2 py-0.5 rounded text-xs font-medium bg-yellow-100 text-yellow-800"

  defp connection_badge_class(_),
    do: "inline-flex px-2 py-0.5 rounded text-xs font-medium bg-red-100 text-red-800"
end
