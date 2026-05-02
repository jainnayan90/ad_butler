defmodule AdButlerWeb.ChatLive.IndexTest do
  use AdButlerWeb.ConnCase, async: true

  import AdButler.Factory
  import Phoenix.LiveViewTest

  alias AdButler.Chat

  describe "ChatLive.Index" do
    test "lists the user's sessions ordered by recency", %{conn: conn} do
      user = insert(:user)
      now = DateTime.utc_now()

      {:ok, _older} =
        Chat.create_session(%{
          user_id: user.id,
          title: "Older chat",
          last_activity_at: DateTime.add(now, -60, :second)
        })

      {:ok, _newer} =
        Chat.create_session(%{user_id: user.id, title: "Newer chat", last_activity_at: now})

      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, ~p"/chat")

      assert html =~ "Newer chat"
      assert html =~ "Older chat"
      assert html =~ "2 sessions"
    end

    test "tenant isolation — user B does not see user A's sessions", %{conn: conn} do
      user_a = insert(:user)
      user_b = insert(:user)
      {:ok, _a_session} = Chat.create_session(%{user_id: user_a.id, title: "A's chat"})

      conn = log_in_user(conn, user_b)
      {:ok, _view, html} = live(conn, ~p"/chat")

      refute html =~ "A's chat"
      assert html =~ "No chat sessions yet"
    end

    test "+ New chat creates a session and navigates to /chat/:id", %{conn: conn} do
      user = insert(:user)
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/chat")

      assert {:error, {:live_redirect, %{to: "/chat/" <> _}}} =
               view |> element("button", "New chat") |> render_click()

      assert [%Chat.Session{user_id: uid}] = Chat.list_sessions(user.id)
      assert uid == user.id
    end

    test "paginate event push_patches the URL with ?page=2", %{conn: conn} do
      user = insert(:user)
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/chat")

      _ = render_hook(view, "paginate", %{"page" => "2"})
      assert_patch(view, ~p"/chat?page=2")
    end

    test "disconnected render shows non-empty placeholder with back link", %{conn: conn} do
      user = insert(:user)
      conn = log_in_user(conn, user)

      body = conn |> get(~p"/chat") |> html_response(200)

      assert body =~ "Loading"
      assert body =~ "Back"
    end
  end
end
