defmodule AdButler.Workers.FetchAdAccountsWorkerTest do
  use AdButler.DataCase, async: false

  import AdButler.Factory
  import Mox

  use Oban.Testing, repo: AdButler.Repo

  alias AdButler.{Accounts, Ads}
  alias AdButler.Workers.FetchAdAccountsWorker

  setup :verify_on_exit!
  setup :set_mox_global

  defp meta_accounts do
    [
      %{
        "id" => "act_111",
        "name" => "Account One",
        "currency" => "USD",
        "timezone_name" => "UTC",
        "account_status" => "ACTIVE"
      },
      %{
        "id" => "act_222",
        "name" => "Account Two",
        "currency" => "EUR",
        "timezone_name" => "Europe/Berlin",
        "account_status" => "ACTIVE"
      }
    ]
  end

  describe "perform/1 success" do
    test "upserts ad accounts and publishes messages" do
      user = insert(:user)
      conn = insert(:meta_connection, user: user)

      expect(AdButler.Meta.ClientMock, :list_ad_accounts, fn _token ->
        {:ok, meta_accounts()}
      end)

      expect(AdButler.Messaging.PublisherMock, :publish, 2, fn payload ->
        assert {:ok, %{"ad_account_id" => id}} = Jason.decode(payload)
        assert {:ok, _} = Ecto.UUID.cast(id), "expected DB UUID, got: #{inspect(id)}"
        :ok
      end)

      assert :ok =
               perform_job(FetchAdAccountsWorker, %{"meta_connection_id" => conn.id})

      accounts = Ads.list_ad_accounts(user)
      assert length(accounts) == 2
    end
  end

  describe "perform/1 rate limit" do
    test "returns {:snooze, 15 min} and leaves DB unchanged" do
      conn = insert(:meta_connection)

      expect(AdButler.Meta.ClientMock, :list_ad_accounts, fn _token ->
        {:error, :rate_limit_exceeded}
      end)

      assert {:snooze, {15, :minutes}} =
               perform_job(FetchAdAccountsWorker, %{"meta_connection_id" => conn.id})
    end
  end

  describe "perform/1 unauthorized" do
    test "cancels job and marks connection as revoked" do
      conn = insert(:meta_connection, status: "active")

      expect(AdButler.Meta.ClientMock, :list_ad_accounts, fn _token ->
        {:error, :unauthorized}
      end)

      assert {:cancel, "unauthorized"} =
               perform_job(FetchAdAccountsWorker, %{"meta_connection_id" => conn.id})

      updated = Accounts.get_meta_connection!(conn.id)
      assert updated.status == "revoked"
    end
  end

  describe "perform/1 generic error" do
    test "returns {:error, reason} for retry" do
      conn = insert(:meta_connection)

      expect(AdButler.Meta.ClientMock, :list_ad_accounts, fn _token ->
        {:error, :meta_server_error}
      end)

      assert {:error, :meta_server_error} =
               perform_job(FetchAdAccountsWorker, %{"meta_connection_id" => conn.id})
    end
  end

  describe "perform/1 missing connection" do
    test "cancels job when meta_connection no longer exists" do
      assert {:cancel, "meta_connection_not_found"} =
               perform_job(FetchAdAccountsWorker, %{"meta_connection_id" => Ecto.UUID.generate()})
    end
  end

  describe "perform/1 invalid UUID" do
    test "cancels job immediately when meta_connection_id is not a valid UUID" do
      assert {:cancel, "invalid_meta_connection_id"} =
               perform_job(FetchAdAccountsWorker, %{"meta_connection_id" => "not-a-uuid"})
    end
  end

  describe "perform/1 idempotency" do
    test "two performs with same connection + same account IDs yield one row" do
      user = insert(:user)
      conn = insert(:meta_connection, user: user)

      expect(AdButler.Meta.ClientMock, :list_ad_accounts, 2, fn _token ->
        {:ok, [hd(meta_accounts())]}
      end)

      expect(AdButler.Messaging.PublisherMock, :publish, 2, fn payload ->
        assert {:ok, %{"ad_account_id" => id}} = Jason.decode(payload)
        assert {:ok, _} = Ecto.UUID.cast(id)
        :ok
      end)

      perform_job(FetchAdAccountsWorker, %{"meta_connection_id" => conn.id})
      perform_job(FetchAdAccountsWorker, %{"meta_connection_id" => conn.id})

      assert length(Ads.list_ad_accounts(user)) == 1
    end
  end
end
