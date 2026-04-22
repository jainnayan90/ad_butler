defmodule AdButlerWeb.Plugs.RequireAuthenticatedTest do
  use AdButlerWeb.ConnCase, async: true

  import AdButler.Factory

  alias AdButlerWeb.Plugs.RequireAuthenticated

  describe "call/2" do
    test "redirects to / when no session", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> RequireAuthenticated.call([])

      assert conn.halted
      assert redirected_to(conn) == ~p"/"
    end

    test "redirects to / when session user_id does not exist", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(%{user_id: Ecto.UUID.generate()})
        |> RequireAuthenticated.call([])

      assert conn.halted
      assert redirected_to(conn) == ~p"/"
    end

    test "assigns current_user when session is valid", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> Plug.Test.init_test_session(%{user_id: user.id})
        |> RequireAuthenticated.call([])

      refute conn.halted
      assert conn.assigns.current_user.id == user.id
    end
  end
end
