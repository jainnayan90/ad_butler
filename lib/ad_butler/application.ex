defmodule AdButler.Application do
  @moduledoc """
  OTP Application entry point for AdButler.

  Starts the supervision tree: database, vault, PubSub, rate-limit store, Oban,
  and — outside of test — the RabbitMQ publisher and Broadway metadata pipeline.
  Also attaches a telemetry handler that logs discarded and cancelled Oban jobs
  and any job exceptions.
  """

  use Application

  require Logger

  alias AdButler.Chat
  alias AdButler.ErrorHelpers
  alias AdButler.Messaging.RabbitMQTopology

  @impl true
  @spec start(any(), any()) :: {:error, any()} | {:ok, pid()}
  def start(_type, _args) do
    assert_req_llm_http1_pool!()

    :telemetry.detach("oban-job-lifecycle-logger")

    :ok =
      :telemetry.attach_many(
        "oban-job-lifecycle-logger",
        [[:oban, :job, :stop], [:oban, :job, :exception]],
        &__MODULE__.handle_oban_event/4,
        nil
      )

    env = Application.get_env(:ad_butler, :env, :prod)

    children =
      [
        AdButlerWeb.Telemetry,
        AdButler.Vault,
        AdButler.Repo,
        {DNSCluster, query: Application.get_env(:ad_butler, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: AdButler.PubSub},
        AdButler.Meta.RateLimitStore,
        {PlugAttack.Storage.Ets, name: :plug_attack_storage, clean_period: 60_000},
        {Oban, Application.fetch_env!(:ad_butler, Oban)},
        {Task.Supervisor, name: AdButler.TaskSupervisor},
        # Jido 2.2 instance — owns Jido.Registry, Jido.RuntimeStore, agent
        # supervisor. Required before any Jido.AgentServer.start_link/1.
        # See .claude/plans/week9-chat-foundation/scratchpad.md D-W9-01.
        {Jido, name: Jido},
        # Per-session chat agent registry + supervisor (Week 9 D2).
        # Naming: `{:via, Registry, {AdButler.Chat.SessionRegistry, session_id}}`.
        {Registry, keys: :unique, name: AdButler.Chat.SessionRegistry},
        {DynamicSupervisor,
         name: AdButler.Chat.SessionSupervisor, strategy: :one_for_one, max_restarts: 50}
      ] ++
        if env != :test do
          [
            AdButler.Messaging.PublisherPool,
            AdButler.Sync.MetadataPipeline,
            Supervisor.child_spec(
              {AdButler.Sync.InsightsPipeline, queue: "ad_butler.insights.delivery"},
              id: :insights_pipeline_delivery
            ),
            Supervisor.child_spec(
              {AdButler.Sync.InsightsPipeline, queue: "ad_butler.insights.conversions"},
              id: :insights_pipeline_conversions
            )
          ]
        else
          []
        end ++
        [
          # Start to serve requests, typically the last entry
          AdButlerWeb.Endpoint
        ]

    # Queues must exist before Broadway pipelines subscribe — run synchronously first.
    if env != :test, do: setup_rabbitmq_topology()

    opts = [strategy: :one_for_one, name: AdButler.Supervisor]
    result = Supervisor.start_link(children, opts)

    :ok = Chat.Telemetry.attach()

    result
  end

  defp setup_rabbitmq_topology do
    do_setup_rabbitmq_topology(3)
  end

  defp do_setup_rabbitmq_topology(0) do
    Logger.error(
      "RabbitMQ topology setup failed after all retries — halting to prevent silent message loss"
    )

    System.stop(1)
  end

  defp do_setup_rabbitmq_topology(attempts_left) do
    case RabbitMQTopology.setup() do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("RabbitMQ topology setup failed, retrying",
          reason: ErrorHelpers.safe_reason(reason),
          attempts_left: attempts_left - 1
        )

        Process.sleep(2_000)
        do_setup_rabbitmq_topology(attempts_left - 1)
    end
  end

  @doc "Telemetry handler for Oban job lifecycle events. Logs discarded, cancelled, and exception events."
  def handle_oban_event(
        [:oban, :job, :stop],
        _measurements,
        %{state: :discarded, job: job},
        _config
      ) do
    Logger.error("Oban job exhausted all attempts and was discarded",
      worker: job.worker,
      id: job.id,
      queue: job.queue
    )
  end

  def handle_oban_event(
        [:oban, :job, :stop],
        _measurements,
        %{state: :cancelled, job: job},
        _config
      ) do
    Logger.warning("Oban job was cancelled",
      worker: job.worker,
      id: job.id,
      queue: job.queue
    )
  end

  def handle_oban_event(
        [:oban, :job, :exception],
        _measurements,
        %{job: job, kind: kind, reason: reason},
        _config
      ) do
    Logger.error("Oban job raised exception",
      kind: kind,
      reason: reason,
      worker: job.worker,
      id: job.id
    )
  end

  def handle_oban_event(_, _, _, _), do: :ok

  # Finch HTTP/2 silently drops streamed bodies > 64 KB
  # (https://github.com/sneako/finch/issues/265). ReqLLM streams responses,
  # so a misconfigured pool would produce truncated tool-call JSON in
  # production with no error visible to the agent. Boot-time assertion fails
  # loudly so the next deploy catches a config drift instead of leaking
  # corrupt assistant turns into chat history.
  defp assert_req_llm_http1_pool! do
    pools =
      :req_llm
      |> Application.get_env(:finch, [])
      |> Keyword.get(:pools, %{})

    case Map.get(pools, :default) do
      opts when is_list(opts) ->
        case Keyword.get(opts, :protocols) do
          [:http1] ->
            :ok

          other ->
            raise "ReqLLM Finch pool must be configured with protocols: [:http1] (got #{inspect(other)}). HTTP/2 silently truncates streamed bodies > 64KB — see config/config.exs."
        end

      nil ->
        raise "ReqLLM Finch :default pool is not configured. Expected protocols: [:http1] — see config/config.exs."
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AdButlerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
