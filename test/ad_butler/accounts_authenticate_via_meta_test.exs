defmodule AdButler.AccountsAuthenticateViaMetaTest do
  use AdButler.DataCase, async: false

  alias AdButler.Accounts

  setup do
    orig_req_options = Application.get_env(:ad_butler, :req_options)
    Application.put_env(:ad_butler, :req_options, plug: {Req.Test, AdButler.Meta.Client})

    on_exit(fn ->
      case orig_req_options do
        nil -> Application.delete_env(:ad_butler, :req_options)
        val -> Application.put_env(:ad_butler, :req_options, val)
      end
    end)

    :ok
  end

  describe "authenticate_via_meta/1" do
    test "happy path returns {:ok, user, meta_connection} for new user" do
      n = System.unique_integer([:positive])

      Req.Test.stub(AdButler.Meta.Client, fn conn ->
        if String.contains?(conn.request_path, "oauth/access_token") do
          Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 86_400})
        else
          Req.Test.json(conn, %{
            "id" => "#{n}",
            "name" => "Test User",
            "email" => "testuser_#{n}@example.com"
          })
        end
      end)

      assert {:ok, %Accounts.User{} = user, %Accounts.MetaConnection{}} =
               Accounts.authenticate_via_meta("auth_code")

      assert user.name == "Test User"
    end

    test "returns error when token exchange fails" do
      Req.Test.stub(AdButler.Meta.Client, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"error" => %{"message" => "Invalid code"}})
      end)

      assert {:error, {:token_exchange_failed, _}} = Accounts.authenticate_via_meta("bad_code")
    end

    test "returns error when get_me fails" do
      Req.Test.stub(AdButler.Meta.Client, fn conn ->
        if String.contains?(conn.request_path, "oauth/access_token") do
          Req.Test.json(conn, %{"access_token" => "test_token", "expires_in" => 86_400})
        else
          conn
          |> Plug.Conn.put_status(401)
          |> Req.Test.json(%{"error" => %{"message" => "Invalid token"}})
        end
      end)

      assert {:error, {:user_info_failed, _}} = Accounts.authenticate_via_meta("auth_code")
    end
  end
end
