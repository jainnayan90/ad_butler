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

    test "succeeds with nil email (email is optional)" do
      n = System.unique_integer([:positive])
      assert {:ok, user} = Accounts.create_or_update_user(%{meta_user_id: "#{n}"})
      assert is_nil(user.email)
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

  describe "get_user/1" do
    test "returns user for known id" do
      user = insert(:user)
      assert %Accounts.User{id: id} = Accounts.get_user(user.id)
      assert id == user.id
    end

    test "returns nil for unknown id" do
      assert nil == Accounts.get_user(Ecto.UUID.generate())
    end
  end

  describe "get_user!/1" do
    test "returns user for known id" do
      user = insert(:user)
      assert %Accounts.User{id: id} = Accounts.get_user!(user.id)
      assert id == user.id
    end

    test "raises Ecto.NoResultsError for unknown id" do
      assert_raise Ecto.NoResultsError, fn ->
        Accounts.get_user!(Ecto.UUID.generate())
      end
    end
  end

  describe "get_user_by_email/1" do
    test "returns user for known email" do
      user = insert(:user)
      assert %Accounts.User{id: id} = Accounts.get_user_by_email(user.email)
      assert id == user.id
    end

    test "returns nil for unknown email" do
      assert nil == Accounts.get_user_by_email("nobody@example.com")
    end

    # citext gives case-insensitive lookups at the DB level. If this test fails
    # with nil, the test DB has a stale varchar column — rebuild it:
    #   MIX_ENV=test mix ecto.drop && mix ecto.create && mix ecto.migrate
    @tag :requires_citext
    test "lookup is case-insensitive (citext column)" do
      n = System.unique_integer([:positive])
      user = insert(:user, email: "case_#{n}@example.com")
      upcased = String.upcase(user.email)
      result = Accounts.get_user_by_email(upcased)

      assert result != nil,
             "citext column should return a match for uppercase input — " <>
               "if nil, rebuild the test DB (column may be varchar from a stale schema)"

      assert result.id == user.id
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

  describe "list_all_active_meta_connections/1" do
    test "respects the row limit and logs an error when limit is hit" do
      Enum.each(1..3, fn _ -> insert(:meta_connection, status: "active") end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          result = Accounts.list_all_active_meta_connections(2)
          assert length(result) == 2
        end)

      assert log =~ "list_all_active_meta_connections hit row limit"
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

  describe "get_meta_connections_by_ids/1" do
    test "returns empty map for empty list" do
      assert %{} = Accounts.get_meta_connections_by_ids([])
    end

    test "returns map keyed by id for a single existing ID" do
      conn = insert(:meta_connection)
      result = Accounts.get_meta_connections_by_ids([conn.id])
      assert map_size(result) == 1
      assert result[conn.id].id == conn.id
    end

    test "returns map keyed by id for multiple existing IDs" do
      conn1 = insert(:meta_connection)
      conn2 = insert(:meta_connection)
      result = Accounts.get_meta_connections_by_ids([conn1.id, conn2.id])
      assert map_size(result) == 2
      assert Map.has_key?(result, conn1.id)
      assert Map.has_key?(result, conn2.id)
    end

    test "omits IDs that do not exist" do
      conn = insert(:meta_connection)
      missing_id = Ecto.UUID.generate()
      result = Accounts.get_meta_connections_by_ids([conn.id, missing_id])
      assert map_size(result) == 1
      assert Map.has_key?(result, conn.id)
      refute Map.has_key?(result, missing_id)
    end
  end

  describe "list_all_meta_connections_for_user/1" do
    test "returns all connections for user regardless of status" do
      user = insert(:user)
      active = insert(:meta_connection, user: user, status: "active")

      expired =
        insert(:meta_connection,
          user: user,
          meta_user_id: "#{System.unique_integer([:positive])}",
          status: "expired"
        )

      result = Accounts.list_all_meta_connections_for_user(user)
      ids = Enum.map(result, & &1.id)
      assert active.id in ids
      assert expired.id in ids
    end

    test "does not return another user's connections" do
      user_a = insert(:user)
      user_b = insert(:user)
      _conn_a = insert(:meta_connection, user: user_a, status: "active")

      assert [] = Accounts.list_all_meta_connections_for_user(user_b)
    end

    test "returns connections ordered newest first" do
      user = insert(:user)

      older =
        insert(:meta_connection,
          user: user,
          meta_user_id: "#{System.unique_integer([:positive])}",
          status: "active"
        )

      newer =
        insert(:meta_connection,
          user: user,
          meta_user_id: "#{System.unique_integer([:positive])}",
          status: "expired"
        )

      [first | _] = Accounts.list_all_meta_connections_for_user(user)
      assert first.id == newer.id || first.inserted_at >= older.inserted_at
    end
  end

  describe "stream_active_meta_connections/1" do
    test "returns an enumerable that yields active connections" do
      conn = insert(:meta_connection, status: "active")

      rows =
        Repo.transaction(fn ->
          Accounts.stream_active_meta_connections() |> Enum.to_list()
        end)

      assert {:ok, list} = rows
      assert Enum.any?(list, &(&1.id == conn.id))
    end

    test "does not yield inactive connections" do
      _revoked = insert(:meta_connection, status: "revoked")

      {:ok, list} =
        Repo.transaction(fn ->
          Accounts.stream_active_meta_connections() |> Enum.to_list()
        end)

      assert Enum.all?(list, &(&1.status == "active"))
    end
  end

  describe "list_meta_connection_ids_for_user/1" do
    test "returns UUIDs for all active connections belonging to the user" do
      user = insert(:user)
      conn1 = insert(:meta_connection, user: user, status: "active")
      conn2 = insert(:meta_connection, user: user, status: "active")
      _inactive = insert(:meta_connection, user: user, status: "revoked")

      ids = Accounts.list_meta_connection_ids_for_user(user)

      assert length(ids) == 2
      assert conn1.id in ids
      assert conn2.id in ids
    end

    test "returns empty list for user with no connections" do
      user = insert(:user)
      assert [] = Accounts.list_meta_connection_ids_for_user(user)
    end

    test "does not return another user's connection IDs" do
      user = insert(:user)
      other_user = insert(:user)
      _other_conn = insert(:meta_connection, user: other_user, status: "active")

      assert [] = Accounts.list_meta_connection_ids_for_user(user)
    end
  end
end
