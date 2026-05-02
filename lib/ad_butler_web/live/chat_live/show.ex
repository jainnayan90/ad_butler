defmodule AdButlerWeb.ChatLive.Show do
  @moduledoc """
  Per-session chat view for `/chat/:id`. Renders the message thread
  with streaming assistant turns, a compose form, and inline charts
  rendered from `get_insights_series` tool results.

  Disconnected first paint shows a non-empty placeholder per
  CLAUDE.md. Session lookup, PubSub subscription, and history
  pagination run only after `connected?/1`.

  Streaming flow: `start_async/3` invokes `Chat.send_message/3`
  (blocking) on a tracked task; PubSub events drive interim UI
  state (`:streaming_chunk` accumulates chunks, `:turn_complete`
  swaps the in-flight bubble for a stream item).
  """

  use AdButlerWeb, :live_view

  require Logger

  alias AdButler.Chat
  alias AdButlerWeb.ChatLive.Components

  @per_page 50

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    socket =
      socket
      |> assign(:active_nav, :chat)
      |> assign(:session_id, id)
      |> assign(:session, nil)
      |> assign(:streaming_chunk, nil)
      |> assign(:sending, false)
      |> assign(:current_tool, nil)
      |> assign(:page, 1)
      |> assign(:total_pages, 1)
      |> assign(:message_count, 0)
      |> stream(:messages, [])

    if connected?(socket), do: send(self(), {:load, id})

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    page = parse_page(params["page"])

    socket =
      if page != socket.assigns.page and socket.assigns.session != nil do
        load_messages_page(socket, page)
      else
        assign(socket, :page, page)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:load, id}, socket) do
    user = socket.assigns.current_user

    case Chat.get_session(user.id, id) do
      {:ok, session} ->
        :ok = Chat.subscribe(session.id)
        {messages, total} = Chat.paginate_messages(session.id, page: 1, per_page: @per_page)
        total_pages = max(1, ceil(total / @per_page))

        socket =
          socket
          |> assign(:session, session)
          |> assign(:total_pages, total_pages)
          |> assign(:message_count, total)
          |> stream(:messages, messages, reset: true)

        {:noreply, socket}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Session not found.")
         |> push_navigate(to: ~p"/chat")}
    end
  end

  @impl true
  def handle_info({:chat_chunk, _sid, text}, socket) do
    current = socket.assigns.streaming_chunk || ""
    {:noreply, assign(socket, :streaming_chunk, current <> text)}
  end

  def handle_info({:tool_result, _sid, name, _status}, socket) do
    Process.send_after(self(), {:clear_tool_indicator, name}, 2_000)
    {:noreply, assign(socket, :current_tool, name)}
  end

  def handle_info({:clear_tool_indicator, name}, socket) do
    if socket.assigns.current_tool == name do
      {:noreply, assign(socket, :current_tool, nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:turn_complete, _sid, :error}, socket) do
    {:noreply, assign(socket, :streaming_chunk, nil)}
  end

  def handle_info({:turn_complete, _sid, msg_id}, socket) do
    case Chat.get_message(msg_id) do
      {:ok, msg} ->
        socket =
          socket
          |> stream_insert(:messages, msg)
          |> assign(:streaming_chunk, nil)
          |> assign(:current_tool, nil)
          |> assign(:message_count, socket.assigns.message_count + 1)

        {:noreply, socket}

      {:error, :not_found} ->
        Logger.warning("chat: turn_complete for missing message",
          session_id: socket.assigns.session_id,
          message_id: msg_id
        )

        {:noreply,
         socket
         |> assign(:streaming_chunk, nil)
         |> put_flash(:error, "Lost a message — refresh to recover.")}
    end
  end

  def handle_info({:turn_error, _sid, reason}, socket) do
    Logger.warning("chat: turn error",
      session_id: socket.assigns.session_id,
      reason: redact_reason(reason)
    )

    {:noreply,
     socket
     |> assign(:streaming_chunk, nil)
     |> assign(:current_tool, nil)
     |> assign(:sending, false)
     |> put_flash(:error, "Agent error — please retry.")}
  end

  @impl true
  def handle_event("send_message", %{"body" => body}, socket) do
    case String.trim(body) do
      "" ->
        {:noreply, socket}

      trimmed ->
        user_id = socket.assigns.current_user.id
        session_id = socket.assigns.session_id

        socket =
          socket
          |> assign(:sending, true)
          |> assign(:streaming_chunk, "")
          |> start_async(:send_turn, fn ->
            send_turn_safely(user_id, session_id, trimmed)
          end)

        {:noreply, socket}
    end
  end

  def handle_event("paginate", %{"page" => page}, socket) do
    {:noreply, push_patch(socket, to: ~p"/chat/#{socket.assigns.session_id}?page=#{page}")}
  end

  def handle_event("load_older", _params, socket) do
    next_page = socket.assigns.page + 1

    if next_page <= socket.assigns.total_pages do
      {:noreply, push_patch(socket, to: ~p"/chat/#{socket.assigns.session_id}?page=#{next_page}")}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_async(:send_turn, {:ok, :ok}, socket) do
    {:noreply, assign(socket, :sending, false)}
  end

  def handle_async(:send_turn, {:ok, {:error, reason}}, socket) do
    Logger.warning("chat: send failed",
      session_id: socket.assigns.session_id,
      reason: redact_reason(reason)
    )

    {:noreply,
     socket
     |> assign(:sending, false)
     |> assign(:streaming_chunk, nil)
     |> put_flash(:error, "Send failed — please retry.")}
  end

  def handle_async(:send_turn, {:exit, reason}, socket) do
    Logger.error("chat: send_turn exited",
      session_id: socket.assigns.session_id,
      reason: redact_reason(reason)
    )

    {:noreply,
     socket
     |> assign(:sending, false)
     |> assign(:streaming_chunk, nil)
     |> put_flash(:error, "Agent crashed — please retry.")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <div :if={is_nil(@session)} class="space-y-4">
        <.link navigate={~p"/chat"} class="text-sm text-blue-600 hover:text-blue-800">
          ← Back
        </.link>
        <p class="text-gray-500 text-sm">Loading…</p>
      </div>

      <div :if={@session} class="flex flex-col h-full">
        <div class="flex items-center justify-between border-b border-gray-200 pb-3 mb-3">
          <div class="flex items-center gap-3">
            <.link navigate={~p"/chat"} class="text-sm text-blue-600 hover:text-blue-800">
              ← All chats
            </.link>
            <h1 class="text-lg font-semibold text-gray-900">
              {session_title(@session)}
            </h1>
          </div>
          <span class={status_pill_class(agent_status(@sending, @streaming_chunk))}>
            {agent_status_label(agent_status(@sending, @streaming_chunk))}
          </span>
        </div>

        <div
          id="chat-scroll"
          phx-hook="ChatScroll"
          class="flex-1 overflow-y-auto space-y-3 px-1 py-2"
        >
          <div :if={@page < @total_pages} class="text-center">
            <button
              type="button"
              phx-click="load_older"
              class="text-xs text-blue-600 hover:text-blue-800 underline"
            >
              Load older messages
            </button>
          </div>

          <div :if={@message_count == 0 and is_nil(@streaming_chunk)} class="text-center py-12">
            <p class="text-gray-500 text-sm">
              Start the conversation. Try asking "What findings do I have today?"
            </p>
          </div>

          <div id="messages" phx-update="stream" class="space-y-3">
            <div :for={{dom_id, message} <- @streams.messages} id={dom_id}>
              <Components.message_bubble message={message} />
            </div>
          </div>

          <div :if={@streaming_chunk} id="streaming-bubble">
            <Components.streaming_bubble chunk={@streaming_chunk} tool={@current_tool} />
          </div>
        </div>

        <form
          phx-submit="send_message"
          class="border-t border-gray-200 pt-3 mt-3 flex flex-col gap-2"
        >
          <textarea
            name="body"
            rows="3"
            placeholder="Ask anything about your campaigns…"
            disabled={@sending}
            class="block w-full rounded-md border border-gray-300 px-3 py-2 text-sm text-gray-900 shadow-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500 disabled:bg-gray-100"
          ></textarea>
          <div class="flex justify-end">
            <button
              type="submit"
              disabled={@sending}
              class="inline-flex items-center gap-2 rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white shadow-sm hover:bg-blue-700 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2 disabled:opacity-40 disabled:cursor-not-allowed"
            >
              {if @sending, do: "Sending…", else: "Send"}
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  # --------------------------------------------------------------------------
  # Internal
  # --------------------------------------------------------------------------

  defp send_turn_safely(user_id, session_id, body) do
    Chat.send_message(user_id, session_id, body)
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Reduce a free-form reason term to a safe atom/binary tag.
  # `start_async` exit reasons and LLM provider error bodies can echo
  # the user's chat content; never log them verbatim.
  defp redact_reason(reason) when is_atom(reason), do: reason
  defp redact_reason({tag, _}) when is_atom(tag), do: tag
  defp redact_reason({tag, _, _}) when is_atom(tag), do: tag
  defp redact_reason(_), do: :unknown

  defp load_messages_page(socket, page) do
    session = socket.assigns.session
    {messages, _total} = Chat.paginate_messages(session.id, page: page, per_page: @per_page)

    socket = assign(socket, :page, page)

    if page == 1 do
      stream(socket, :messages, messages, reset: true)
    else
      Enum.reduce(messages, socket, fn msg, acc ->
        stream_insert(acc, :messages, msg, at: 0)
      end)
    end
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

  defp agent_status(false, nil), do: :idle
  defp agent_status(true, nil), do: :thinking
  defp agent_status(true, ""), do: :thinking
  defp agent_status(_, _), do: :streaming

  defp agent_status_label(:idle), do: "Idle"
  defp agent_status_label(:thinking), do: "Thinking…"
  defp agent_status_label(:streaming), do: "Streaming…"

  defp status_pill_class(:idle),
    do: "px-2 py-1 rounded-full text-xs font-medium bg-gray-100 text-gray-700"

  defp status_pill_class(:thinking),
    do: "px-2 py-1 rounded-full text-xs font-medium bg-amber-100 text-amber-800"

  defp status_pill_class(:streaming),
    do: "px-2 py-1 rounded-full text-xs font-medium bg-blue-100 text-blue-800"
end
