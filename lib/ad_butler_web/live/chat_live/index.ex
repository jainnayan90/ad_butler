defmodule AdButlerWeb.ChatLive.Index do
  @moduledoc """
  Sessions list for `/chat`. Renders the authenticated user's chat
  sessions ordered by most recent activity, with pagination and a
  "+ New chat" button that creates a session and navigates to the
  per-session view.

  Disconnected first paint shows a non-empty placeholder per
  CLAUDE.md (back link + "Loading…"). The expensive paginated query
  runs only after `connected?/1` so the websocket upgrade — not the
  HTTP request — owns the connection-pool cost.
  """

  use AdButlerWeb, :live_view

  alias AdButler.Chat

  @per_page 50

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:active_nav, :chat)
      |> assign(:page, 1)
      |> assign(:total_pages, 1)
      |> assign(:session_count, 0)
      |> assign(:loaded, false)
      |> stream(:sessions, [])

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    page = parse_page(params["page"])
    socket = assign(socket, :page, page)

    if connected?(socket) do
      {:noreply, load_sessions(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("new_chat", _params, socket) do
    user = socket.assigns.current_user

    case Chat.create_session(%{user_id: user.id, title: "New chat"}) do
      {:ok, session} ->
        {:noreply, push_navigate(socket, to: ~p"/chat/#{session.id}")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not start a new chat.")}
    end
  end

  @impl true
  def handle_event("paginate", %{"page" => page}, socket) do
    {:noreply, push_patch(socket, to: ~p"/chat?page=#{page}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div :if={!@loaded} class="space-y-4">
        <.link navigate={~p"/findings"} class="text-sm text-blue-600 hover:text-blue-800">
          ← Back
        </.link>
        <p class="text-gray-500 text-sm">Loading…</p>
      </div>

      <div :if={@loaded}>
        <div class="mb-6 flex items-center justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold text-gray-900">Chat</h1>
            <p class="text-sm text-gray-600 mt-1">
              {@session_count} {if @session_count == 1, do: "session", else: "sessions"}
            </p>
          </div>
          <button
            type="button"
            phx-click="new_chat"
            class="inline-flex items-center gap-2 rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white shadow-sm hover:bg-blue-700 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2"
          >
            <.icon name="hero-plus" class="size-4" /> New chat
          </button>
        </div>

        <div class="bg-white shadow rounded-lg">
          <div :if={@session_count == 0} class="px-4 py-12 text-center">
            <p class="text-gray-500">
              No chat sessions yet. Click "New chat" to start a conversation.
            </p>
          </div>

          <ul
            :if={@session_count > 0}
            id="sessions"
            phx-update="stream"
            class="divide-y divide-gray-200"
          >
            <li :for={{dom_id, session} <- @streams.sessions} id={dom_id} class="px-4 py-3">
              <.link
                navigate={~p"/chat/#{session.id}"}
                class="flex items-center justify-between gap-4 hover:bg-gray-50 -mx-4 px-4 py-1 rounded"
              >
                <span class="text-sm font-medium text-gray-900 truncate">
                  {session_title(session)}
                </span>
                <span class="text-xs text-gray-500 shrink-0">
                  {Calendar.strftime(session.last_activity_at, "%b %d, %H:%M")}
                </span>
              </.link>
            </li>
          </ul>

          <.pagination :if={@session_count > 0} page={@page} total_pages={@total_pages} />
        </div>
      </div>
    </div>
    """
  end

  defp load_sessions(socket) do
    user = socket.assigns.current_user

    {sessions, total} =
      Chat.paginate_sessions(user.id, page: socket.assigns.page, per_page: @per_page)

    total_pages = max(1, ceil(total / @per_page))

    socket
    |> stream(:sessions, sessions, reset: true)
    |> assign(:session_count, total)
    |> assign(:total_pages, total_pages)
    |> assign(:loaded, true)
  end

  defp parse_page(nil), do: 1

  defp parse_page(str) do
    case Integer.parse(str) do
      {n, ""} when n > 0 -> n
      _ -> 1
    end
  end

  defp session_title(%{title: t}) when is_binary(t) and t != "", do: t
  defp session_title(_), do: "Untitled"
end
