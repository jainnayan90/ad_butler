defmodule AdButler.AccountsTest do
  use AdButler.DataCase, async: true

  import AdButler.Factory

  alias AdButler.Accounts

  describe "create_or_update_user/1" do
    test "creates a user with valid attrs" do
      n = System.unique_integer([:positive])
      email = "test_#{n}@example.com"

      assert {:ok, user} =
               Accounts.create_or_update_user(%{email: email, name: "Test", meta_user_id: "#{n}"})

      assert user.email == email
      assert user.name == "Test"
    end

    test "two calls with same meta_user_id produce one row; second call updates name and email" do
      n = System.unique_integer([:positive])
      first_email = "first_#{n}@example.com"
      second_email = "second_#{n}@example.com"
      meta_user_id = "#{n}"

      assert {:ok, _} =
               Accounts.create_or_update_user(%{
                 email: first_email,
                 name: "First",
                 meta_user_id: meta_user_id
               })

      assert {:ok, updated} =
               Accounts.create_or_update_user(%{
                 email: second_email,
                 name: "Second",
                 meta_user_id: meta_user_id
               })

      assert updated.name == "Second"
      assert updated.email == second_email

      assert Repo.aggregate(
               from(u in AdButler.Accounts.User, where: u.meta_user_id == ^meta_user_id),
               :count
             ) == 1
    end

    test "returns error changeset for invalid email" do
      assert {:error, changeset} = Accounts.create_or_update_user(%{email: "not-an-email"})
      assert %{email: [_]} = errors_on(changeset)
    end

    test "returns error changeset when email is nil" do
      n = System.unique_integer([:positive])
      assert {:error, changeset} = Accounts.create_or_update_user(%{meta_user_id: "#{n}"})
      assert %{email: [_]} = errors_on(changeset)
    end
  end

  describe "create_meta_connection/2" do
    test "stores access_token encrypted in DB" do
      user = insert(:user)
      plaintext = "my_secret_token"

      assert {:ok, conn} =
               Accounts.create_meta_connection(user, %{
                 meta_user_id: "#{System.unique_integer([:positive])}",
                 access_token: plaintext,
                 token_expires_at: DateTime.add(DateTime.utc_now(), 86_400, :second),
                 scopes: ["ads_read"]
               })

      %{rows: [[raw]]} =
        Repo.query!(
          "SELECT encode(access_token, 'escape') FROM meta_connections WHERE id = $1",
          [Ecto.UUID.dump!(conn.id)]
        )

      refute raw == plaintext
    end

    test "upserts on duplicate (user_id, meta_user_id): updates token, scopes, status" do
      user = insert(:user)
      expires = DateTime.add(DateTime.utc_now(), 86_400, :second)

      attrs = %{
        meta_user_id: "#{System.unique_integer([:positive])}",
        access_token: "token_a",
        token_expires_at: expires,
        scopes: ["ads_read"]
      }

      assert {:ok, _} = Accounts.create_meta_connection(user, attrs)

      assert {:ok, updated} =
               Accounts.create_meta_connection(user, %{
                 attrs
                 | access_token: "token_b",
                   scopes: ["ads_read", "ads_management"]
               })

      assert updated.access_token == "token_b"
      assert updated.scopes == ["ads_read", "ads_management"]

      assert Repo.aggregate(
               from(mc in AdButler.Accounts.MetaConnection, where: mc.user_id == ^user.id),
               :count
             ) == 1
    end
  end

  describe "get_meta_connection/1" do
    test "returns nil for unknown id" do
      assert nil == Accounts.get_meta_connection("00000000-0000-0000-0000-000000000000")
    end

    test "returns connection for known id" do
      conn = insert(:meta_connection)
      id = conn.id
      assert %{id: ^id} = Accounts.get_meta_connection(conn.id)
    end
  end

  describe "update_meta_connection/2" do
    test "updates token and expiry in DB" do
      conn = insert(:meta_connection)
      new_expiry = DateTime.add(DateTime.utc_now(), 30 * 86_400, :second)

      assert {:ok, updated} =
               Accounts.update_meta_connection(conn, %{
                 access_token: "new_token",
                 token_expires_at: new_expiry
               })

      assert updated.access_token == "new_token"
      reloaded = Accounts.get_meta_connection!(conn.id)
      assert reloaded.access_token == "new_token"
    end

    test "returns error changeset for invalid status" do
      conn = insert(:meta_connection)

      assert {:error, changeset} =
               Accounts.update_meta_connection(conn, %{status: "invalid_status"})

      assert %{status: [_]} = errors_on(changeset)
    end
  end

  describe "list_meta_connections/1" do
    test "returns only active connections for the given user" do
      user = insert(:user)
      other_user = insert(:user)

      active = insert(:meta_connection, user: user, status: "active")

      _expired =
        insert(:meta_connection,
          user: user,
          meta_user_id: "#{System.unique_integer([:positive])}",
          status: "expired"
        )

      _other = insert(:meta_connection, user: other_user, status: "active")

      result = Accounts.list_meta_connections(user)
      assert length(result) == 1
      assert hd(result).id == active.id
    end
  end
end
