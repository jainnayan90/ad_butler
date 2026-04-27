defmodule AdButler.AccountsAuthenticateViaMetaTest do
  use AdButler.DataCase, async: true

  import Mox

  alias AdButler.Accounts
  alias AdButler.Meta.ClientMock

  setup :set_mox_from_context
  setup :verify_on_exit!

  describe "authenticate_via_meta/1" do
    test "happy path returns {:ok, user, meta_connection} for new user" do
      n = System.unique_integer([:positive])

      expect(ClientMock, :exchange_code, fn _code ->
        {:ok, %{access_token: "test_token", expires_in: 86_400}}
      end)

      expect(ClientMock, :get_me, fn _token ->
        {:ok, %{meta_user_id: "#{n}", name: "Test User", email: "testuser_#{n}@example.com"}}
      end)

      assert {:ok, %Accounts.User{} = user, %Accounts.MetaConnection{}} =
               Accounts.authenticate_via_meta("auth_code")

      assert user.name == "Test User"
    end

    test "returns error when token exchange fails" do
      expect(ClientMock, :exchange_code, 1, fn _code ->
        {:error, {:token_exchange_failed, "Invalid code"}}
      end)

      assert {:error, {:token_exchange_failed, _}} = Accounts.authenticate_via_meta("bad_code")
    end

    test "returns error when get_me fails" do
      expect(ClientMock, :exchange_code, 1, fn _code ->
        {:ok, %{access_token: "test_token", expires_in: 86_400}}
      end)

      expect(ClientMock, :get_me, 1, fn _token ->
        {:error, {:user_info_failed, "Invalid token"}}
      end)

      assert {:error, {:user_info_failed, _}} = Accounts.authenticate_via_meta("auth_code")
    end
  end
end
