defmodule AdButlerWeb.ChatLive.ShowAsyncErrorTest do
  # Async: false because `set_mox_global` shares the mock across processes —
  # `Chat.Server` runs under DynamicSupervisor, not the test pid.
  use AdButlerWeb.ConnCase, async: false

  import AdButler.Factory
  import Mox
  import Phoenix.LiveViewTest

  alias AdButler.Chat
  alias AdButler.Chat.LLMClientMock

  setup :set_mox_global
  setup :verify_on_exit!

  describe "ChatLive.Show — handle_async {:exit, _}" do
    test "Agent crashed flash and chunk cleared when LLM stream raises", %{conn: conn} do
      user = insert(:user)
      {:ok, session} = Chat.create_session(%{user_id: user.id})

      # The mock raises mid-stream → `Chat.Server` GenServer crashes →
      # `GenServer.call/3` exits → `start_async` Task exits →
      # `handle_async(:send_turn, {:exit, _}, _)` fires.
      expect(LLMClientMock, :stream, fn _, _ -> raise "boom" end)

      # `:stop` will not actually be called on this path — the GenServer
      # crashes before `cancel_handle/1` runs. The stub guards against
      # accidental future calls (e.g. if cap-hit logic is added to a
      # mock-LLM extension of this test); `verify_on_exit!` does not
      # enforce stubs, so an unfired stub is harmless.
      stub(LLMClientMock, :stop, fn _ -> :ok end)

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/chat/#{session.id}")
      _ = render(view)

      _ = view |> form("form", %{"body" => "hello"}) |> render_submit()

      html = render_async(view, 1_000)

      assert html =~ "Agent crashed"
      refute html =~ "Sending…"
    end
  end
end
