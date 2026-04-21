defmodule AdButlerWeb.AuthControllerTest do
  use AdButlerWeb.ConnCase, async: false

  setup do
    orig_app_id = Application.get_env(:ad_butler, :meta_app_id)
    orig_app_secret = Application.get_env(:ad_butler, :meta_app_secret)
    orig_callback_url = Application.get_env(:ad_butler, :meta_oauth_callback_url)
    orig_req_options = Application.get_env(:ad_butler, :req_options)

    Application.put_env(:ad_butler, :meta_app_id, "test_app_id")
    Application.put_env(:ad_butler, :meta_app_secret, "test_app_secret")

    Application.put_env(
      :ad_butler,
      :meta_oauth_callback_url,
      "http://localhost/auth/meta/callback"
    )

    Application.put_env(:ad_butler, :req_options, plug: {Req.Test, AdButler.Meta.Client})

    on_exit(fn ->
      restore_or_delete(:meta_app_id, orig_app_id)
      restore_or_delete(:meta_app_secret, orig_app_secret)
      restore_or_delete(:meta_oauth_callback_url, orig_callback_url)
      restore_or_delete(:req_options, orig_req_options)
    end)

    :ok
  end

  defp restore_or_delete(key, nil), do: Application.delete_env(:ad_butler, key)
  defp restore_or_delete(key, val), do: Application.put_env(:ad_butler, key, val)

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

      Req.Test.stub(AdButler.Meta.Client, fn conn ->
        if String.contains?(conn.request_path, "oauth/access_token") do
          Req.Test.json(conn, %{"access_token" => "fake_access_token", "expires_in" => 86400})
        else
          Req.Test.json(conn, %{
            "id" => "123456789",
            "name" => "Test User",
            "email" => "testuser@example.com"
          })
        end
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

      Req.Test.stub(AdButler.Meta.Client, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"error" => %{"message" => "Invalid code"}})
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
      state = "test_state_upsert"

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> put_session(:oauth_state, {state, System.system_time(:second)})

      Req.Test.stub(AdButler.Meta.Client, fn req_conn ->
        if String.contains?(req_conn.request_path, "oauth/access_token") do
          Req.Test.json(req_conn, %{
            "access_token" => "fake_access_token_2",
            "expires_in" => 86400
          })
        else
          Req.Test.json(req_conn, %{
            "id" => "123456789",
            "name" => "Test User",
            "email" => "testuser@example.com"
          })
        end
      end)

      conn =
        get(conn, ~p"/auth/meta/callback", %{
          "code" => "valid_code",
          "state" => state
        })

      assert redirected_to(conn) =~ "/dashboard"
      assert get_session(conn, :user_id) != nil
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
