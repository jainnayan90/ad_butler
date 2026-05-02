defmodule AdButlerWeb.ChatLive.ShowTest do
  use AdButlerWeb.ConnCase, async: true

  import AdButler.Factory
  import Phoenix.LiveViewTest

  alias AdButler.Chat
  alias AdButler.Repo

  describe "ChatLive.Show — auth and disconnected render" do
    test "tenant isolation — user B is redirected away from user A's session", %{conn: conn} do
      user_a = insert(:user)
      user_b = insert(:user)
      {:ok, session_a} = Chat.create_session(%{user_id: user_a.id})

      conn = log_in_user(conn, user_b)

      {:ok, view, _html} = live(conn, ~p"/chat/#{session_a.id}")
      assert_redirect(view, "/chat")
    end

    test "disconnected render is non-empty (Plug.Conn level)", %{conn: conn} do
      user = insert(:user)
      {:ok, session} = Chat.create_session(%{user_id: user.id})

      conn = log_in_user(conn, user)
      body = conn |> get(~p"/chat/#{session.id}") |> html_response(200)

      assert body =~ "Loading"
      assert body =~ "Back"
    end

    test "connected mount populates the message stream from existing rows", %{conn: conn} do
      user = insert(:user)
      {:ok, session} = Chat.create_session(%{user_id: user.id, title: "Demo"})

      _m1 = insert_chat_message_at(session.id, "user", "first message", 1)
      _m2 = insert_chat_message_at(session.id, "assistant", "second message", 2)

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/chat/#{session.id}")

      html = render(view)

      assert html =~ "first message"
      assert html =~ "second message"
      assert html =~ "Demo"
    end

    test "empty session renders the 'Start the conversation' placeholder", %{conn: conn} do
      user = insert(:user)
      {:ok, session} = Chat.create_session(%{user_id: user.id})

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/chat/#{session.id}")

      assert render(view) =~ "Start the conversation"
    end
  end

  describe "ChatLive.Show — compose form" do
    test "submitting an empty body is a no-op", %{conn: conn} do
      user = insert(:user)
      {:ok, session} = Chat.create_session(%{user_id: user.id})

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/chat/#{session.id}")

      html = view |> form("form", %{"body" => "   "}) |> render_submit()

      refute html =~ "Sending"
      refute html =~ "Streaming"
    end
  end

  describe "ChatLive.Show — PubSub handlers" do
    test "{:chat_chunk, _, text} accumulates into the streaming bubble", %{conn: conn} do
      user = insert(:user)
      {:ok, session} = Chat.create_session(%{user_id: user.id})

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/chat/#{session.id}")
      _ = render(view)

      Phoenix.PubSub.broadcast(
        AdButler.PubSub,
        "chat:" <> session.id,
        {:chat_chunk, session.id, "Hello, "}
      )

      Phoenix.PubSub.broadcast(
        AdButler.PubSub,
        "chat:" <> session.id,
        {:chat_chunk, session.id, "world!"}
      )

      html = render(view)
      assert html =~ "Hello, world!"
    end

    test "{:turn_complete, _, msg_id} swaps the bubble for a stream item", %{conn: conn} do
      user = insert(:user)
      {:ok, session} = Chat.create_session(%{user_id: user.id})

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/chat/#{session.id}")
      _ = render(view)

      Phoenix.PubSub.broadcast(
        AdButler.PubSub,
        "chat:" <> session.id,
        {:chat_chunk, session.id, "partial"}
      )

      assert render(view) =~ "partial"

      {:ok, msg} =
        Chat.append_message(%{
          chat_session_id: session.id,
          role: "assistant",
          content: "completed answer",
          status: "complete"
        })

      Phoenix.PubSub.broadcast(
        AdButler.PubSub,
        "chat:" <> session.id,
        {:turn_complete, session.id, msg.id}
      )

      html = render(view)
      assert html =~ "completed answer"
    end

    test "{:turn_complete, _, missing_id} flashes error without crashing", %{conn: conn} do
      user = insert(:user)
      {:ok, session} = Chat.create_session(%{user_id: user.id})

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/chat/#{session.id}")
      _ = render(view)

      Phoenix.PubSub.broadcast(
        AdButler.PubSub,
        "chat:" <> session.id,
        {:turn_complete, session.id, "00000000-0000-0000-0000-000000000000"}
      )

      assert render(view) =~ "Lost a message"
    end

    test "{:tool_result, _, name, _status} surfaces 'Calling …' indicator", %{conn: conn} do
      user = insert(:user)
      {:ok, session} = Chat.create_session(%{user_id: user.id})

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/chat/#{session.id}")
      _ = render(view)

      # The `Calling …` label lives inside the streaming bubble, which only
      # renders while `@streaming_chunk` is set — prime it first.
      Phoenix.PubSub.broadcast(
        AdButler.PubSub,
        "chat:" <> session.id,
        {:chat_chunk, session.id, "thinking…"}
      )

      Phoenix.PubSub.broadcast(
        AdButler.PubSub,
        "chat:" <> session.id,
        {:tool_result, session.id, "get_findings", :ok}
      )

      # Re-render before the 2-second `clear_tool_indicator` fires.
      assert render(view) =~ "Calling get_findings"
    end

    test "{:turn_complete, _, :error} clears streaming chunk without flashing", %{conn: conn} do
      user = insert(:user)
      {:ok, session} = Chat.create_session(%{user_id: user.id})

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/chat/#{session.id}")
      _ = render(view)

      # Prime a streaming chunk.
      Phoenix.PubSub.broadcast(
        AdButler.PubSub,
        "chat:" <> session.id,
        {:chat_chunk, session.id, "partial reply"}
      )

      assert render(view) =~ "partial reply"

      # Cap-hit terminal — clears the chunk, no flash, view stays alive.
      Phoenix.PubSub.broadcast(
        AdButler.PubSub,
        "chat:" <> session.id,
        {:turn_complete, session.id, :error}
      )

      html = render(view)
      refute html =~ "partial reply"
      refute html =~ "Agent error"
      refute html =~ "Lost a message"
      assert Process.alive?(view.pid)
    end

    test "{:turn_error, _, reason} flashes and clears streaming state", %{conn: conn} do
      user = insert(:user)
      {:ok, session} = Chat.create_session(%{user_id: user.id})

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/chat/#{session.id}")
      _ = render(view)

      Phoenix.PubSub.broadcast(
        AdButler.PubSub,
        "chat:" <> session.id,
        {:turn_error, session.id, :timeout}
      )

      assert render(view) =~ "Agent error"
    end
  end

  describe "ChatLive.Show — handle_async error branches" do
    test "handle_async {:ok, {:error, _}} flashes 'Send failed' and resets :sending",
         %{conn: conn} do
      user = insert(:user)
      {:ok, session} = Chat.create_session(%{user_id: user.id})

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/chat/#{session.id}")
      _ = render(view)

      # Drive `Chat.send_message` into the `{:error, :not_found}` branch by
      # deleting the session row after mount. `ensure_server/2` re-checks
      # ownership via `get_session/2` on every send, so the next submit
      # returns `{:error, :not_found}` — which `start_async` surfaces as
      # `{:ok, {:error, :not_found}}` to `handle_async/3`.
      Repo.delete!(session)

      _ = view |> form("form", %{"body" => "hello"}) |> render_submit()

      # render_async waits for the start_async to resolve before re-rendering.
      html = render_async(view, 500)

      assert html =~ "Send failed"
      refute html =~ "Sending…"
    end
  end

  describe "ChatLive.Show — pagination" do
    test "load_older push_patches to ?page=2 when there are older messages", %{conn: conn} do
      user = insert(:user)
      {:ok, session} = Chat.create_session(%{user_id: user.id})

      # Need >50 messages to make page 2 exist (default per_page is 50).
      for i <- 1..55 do
        insert_chat_message_at(session.id, "user", "msg #{i}", i)
      end

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/chat/#{session.id}")
      _ = render(view)

      _ = render_hook(view, "load_older", %{})
      assert_patch(view, ~p"/chat/#{session.id}?page=2")
    end
  end

  describe "ChatLive.Show — tool_call rendering" do
    test "non-chart tool result renders as a <details> collapsible block", %{conn: conn} do
      user = insert(:user)
      {:ok, session} = Chat.create_session(%{user_id: user.id})

      tool_results = [
        %{
          "name" => "get_findings",
          "ok" => true,
          "args" => %{"severity" => "high"},
          "result" => %{"findings" => [%{"id" => "f1", "title" => "t1"}]}
        }
      ]

      {:ok, _msg} =
        Chat.append_message(%{
          chat_session_id: session.id,
          role: "assistant",
          content: "Here are your findings.",
          tool_results: tool_results,
          status: "complete"
        })

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/chat/#{session.id}")
      html = render(view)

      assert html =~ "<details"
      assert html =~ "Tool: get_findings"
      assert html =~ "severity"
    end
  end

  describe "ChatLive.Show — chart rendering" do
    test "assistant message with a get_insights_series tool result renders an inline SVG", %{
      conn: conn
    } do
      user = insert(:user)
      {:ok, session} = Chat.create_session(%{user_id: user.id})

      points =
        for i <- 1..5 do
          %{"date" => Date.to_iso8601(Date.add(~D[2026-01-01], i)), "value" => i * 2.0}
        end

      tool_results = [
        %{
          "name" => "get_insights_series",
          "ok" => true,
          "result" => %{
            "metric" => "spend",
            "window" => "last_7d",
            "points" => points
          }
        }
      ]

      {:ok, _msg} =
        Chat.append_message(%{
          chat_session_id: session.id,
          role: "assistant",
          content: "Here's your spend trend.",
          tool_results: tool_results,
          status: "complete"
        })

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/chat/#{session.id}")
      html = render(view)

      assert html =~ "spend trend"
      assert html =~ "<svg"
      assert html =~ "spend"
    end
  end
end
