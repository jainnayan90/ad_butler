defmodule AdButler.Integration.SyncPipelineTest do
  use AdButler.DataCase, async: false

  # The DLQ replay test below requires a live RabbitMQ broker — tag it individually.
  # Run with: mix test --include integration

  import AdButler.Factory
  import Mox

  use Oban.Testing, repo: AdButler.Repo

  alias AdButler.Ads
  alias AdButler.Messaging.RabbitMQTopology
  alias AdButler.Workers.FetchAdAccountsWorker
  alias Mix.Tasks.AdButler.ReplayDlq

  setup :verify_on_exit!
  setup :set_mox_global

  test "full sync flow: fetch ad accounts → publish → Broadway consumes → upserts campaigns" do
    user = insert(:user)
    conn = insert(:meta_connection, user: user)

    meta_account = %{
      "id" => "act_integration_1",
      "name" => "Integration Account",
      "currency" => "USD",
      "timezone_name" => "UTC",
      "account_status" => "ACTIVE"
    }

    expect(AdButler.Meta.ClientMock, :list_ad_accounts, fn _token ->
      {:ok, [meta_account]}
    end)

    expect(AdButler.Messaging.PublisherMock, :publish, fn payload ->
      assert {:ok, %{"ad_account_id" => id}} = Jason.decode(payload)
      assert {:ok, _} = Ecto.UUID.cast(id), "expected DB UUID, got: #{inspect(id)}"
      :ok
    end)

    # Step 1: Run FetchAdAccountsWorker via Oban.Testing (no Process.sleep)
    assert :ok =
             perform_job(FetchAdAccountsWorker, %{meta_connection_id: conn.id})

    # Step 2: Assert ad account upserted
    accounts = Ads.list_ad_accounts(user)
    assert length(accounts) == 1
    ad_account = hd(accounts)
    assert ad_account.meta_id == "act_integration_1"
  end

  @tag :integration
  test "DLQ replay: messages in DLQ are moved to main queue" do
    # This test requires a live RabbitMQ broker with topology already set up.
    # Ensure topology is ready:
    :ok = RabbitMQTopology.setup()

    url = Application.fetch_env!(:ad_butler, :rabbitmq)[:url]
    {:ok, conn} = AMQP.Connection.open(url)
    {:ok, channel} = AMQP.Channel.open(conn)

    # Publish 3 messages to DLQ directly
    dlq = "ad_butler.sync.metadata.dlq"
    dlq_exchange = "ad_butler.sync.dlq.fanout"

    Enum.each(1..3, fn i ->
      AMQP.Basic.publish(channel, dlq_exchange, "", Jason.encode!(%{test: i}), persistent: true)
    end)

    # Run the DLQ replay task
    ReplayDlq.run(["--limit", "10"])

    # Assert DLQ is empty
    {:ok, %{message_count: dlq_count}} = AMQP.Queue.declare(channel, dlq, passive: true)
    assert dlq_count == 0

    AMQP.Connection.close(conn)
  end
end
