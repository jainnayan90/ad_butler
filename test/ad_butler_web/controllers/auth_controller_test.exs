defmodule AdButlerWeb.AuthControllerTest do
  use AdButlerWeb.ConnCase, async: false

  import Mox
  import AdButler.Factory

  alias AdButler.Accounts
  alias AdButler.Meta.ClientMock
  alias AdButler.Repo

  setup :verify_on_exit!

  describe "GET /auth/meta" do
    test "redirects to Facebook OAuth and sets session state", %{conn: conn} do
      conn = get(conn, ~p"/auth/meta")

      assert redirected_to(conn) =~ "facebook.com"
      assert get_session(conn, :oauth_state) != nil
    end
  end

  describe "GET /auth/meta/callback (valid)" do
    test "creates user, sets session, redirects to /dashboard", %{conn: conn} do
      state = "test_state_value"

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> put_session(:oauth_state, {state, System.system_time(:second)})

      expect(ClientMock, :exchange_code, fn _code ->
        {:ok, %{access_token: "fake_access_token", expires_in: 86_400}}
      end)

      expect(ClientMock, :get_me, fn _token ->
        {:ok, %{meta_user_id: "123456789", name: "Test User", email: "testuser@example.com"}}
      end)

      conn =
        get(conn, ~p"/auth/meta/callback", %{
          "code" => "valid_code",
          "state" => state
        })

      assert redirected_to(conn) =~ "/dashboard"
      assert get_session(conn, :user_id) != nil
    end

    test "returns 4xx from Meta token exchange → redirects with error", %{conn: conn} do
      state = "test_state_value"

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> put_session(:oauth_state, {state, System.system_time(:second)})

      stub(ClientMock, :exchange_code, fn _code ->
        {:error, {:token_exchange_failed, "Invalid code"}}
      end)

      conn =
        get(conn, ~p"/auth/meta/callback", %{
          "code" => "bad_code",
          "state" => state
        })

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Authentication failed"
    end
  end

  describe "GET /auth/meta/callback (second auth / upsert)" do
    test "second OAuth callback with same Meta user upserts connection and redirects to /dashboard",
         %{conn: conn} do
      meta_user_id = "987654321"

      existing_user =
        insert(:user, meta_user_id: meta_user_id, email: "existing@example.com", name: "Old Name")

      insert(:meta_connection,
        user: existing_user,
        meta_user_id: meta_user_id,
        access_token: "old_token"
      )

      state = "test_state_upsert"

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> put_session(:oauth_state, {state, System.system_time(:second)})

      expect(ClientMock, :exchange_code, fn _code ->
        {:ok, %{access_token: "new_token_after_upsert", expires_in: 86_400}}
      end)

      expect(ClientMock, :get_me, fn _token ->
        {:ok, %{meta_user_id: meta_user_id, name: "New Name", email: "existing@example.com"}}
      end)

      conn =
        get(conn, ~p"/auth/meta/callback", %{
          "code" => "valid_code",
          "state" => state
        })

      assert redirected_to(conn) =~ "/dashboard"
      assert get_session(conn, :user_id) == existing_user.id

      user_count =
        Repo.aggregate(AdButler.Accounts.User, :count, :id)

      assert user_count == 1

      connection =
        Accounts.get_meta_connection!(
          List.first(Accounts.list_meta_connections(existing_user)).id
        )

      assert connection.access_token != "old_token"
    end
  end

  describe "GET /auth/meta/callback (expired state)" do
    test "rejects expired state (> 600 seconds old)", %{conn: conn} do
      state = "test_state_expired"
      expired_at = System.system_time(:second) - 700

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> put_session(:oauth_state, {state, expired_at})

      conn = get(conn, ~p"/auth/meta/callback", %{"code" => "c", "state" => state})

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Invalid OAuth state"
    end
  end

  describe "GET /auth/meta/callback (state mismatch)" do
    test "redirects to / with error flash when state does not match", %{conn: conn} do
      conn =
        get(conn, ~p"/auth/meta/callback", %{"code" => "some_code", "state" => "wrong_state"})

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Invalid OAuth state"
    end
  end

  describe "GET /auth/meta/callback (no session)" do
    test "redirects to / with error flash when no session state is present", %{conn: conn} do
      conn = get(conn, ~p"/auth/meta/callback", %{"code" => "c", "state" => "any"})

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Invalid OAuth state"
    end
  end

  describe "GET /auth/meta/callback (OAuth error params)" do
    test "redirects to / with OAuth error message", %{conn: conn} do
      conn =
        get(conn, ~p"/auth/meta/callback", %{
          "error" => "access_denied",
          "error_description" => "User denied access"
        })

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "User denied access"
    end
  end

  describe "DELETE /auth/logout" do
    test "authenticated: clears session, broadcasts disconnect, redirects to /", %{conn: conn} do
      user_id = "00000000-0000-0000-0000-000000000001"

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> put_session(:user_id, user_id)

      AdButlerWeb.Endpoint.subscribe("users_sessions:#{user_id}")

      conn = delete(conn, ~p"/auth/logout")

      assert redirected_to(conn) == ~p"/"
      assert conn.private[:plug_session_info] == :drop

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: "users_sessions:" <> ^user_id,
                       event: "disconnect"
                     },
                     1000
    end

    test "unauthenticated: redirects to / without error", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(%{})

      conn = delete(conn, ~p"/auth/logout")

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == nil
    end
  end
end
