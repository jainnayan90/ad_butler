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

  alias AdButler.ErrorHelpers
  alias AdButler.LLM.UsageHandler
  alias AdButler.Messaging.RabbitMQTopology

  @impl true
  def start(_type, _args) do
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
        {Task.Supervisor, name: AdButler.TaskSupervisor}
      ] ++
        if env != :test do
          [
            AdButler.Messaging.PublisherPool,
            AdButler.Sync.MetadataPipeline
          ]
        else
          []
        end ++
        [
          # Start to serve requests, typically the last entry
          AdButlerWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: AdButler.Supervisor]
    result = Supervisor.start_link(children, opts)

    :ok = UsageHandler.attach()

    if env != :test do
      Task.Supervisor.start_child(AdButler.TaskSupervisor, &setup_rabbitmq_topology/0)
    end

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
      worker: job.worker,
      id: job.id,
      kind: kind,
      reason: log_safe_reason(reason)
    )
  end

  def handle_oban_event(_, _, _, _), do: :ok

  defp log_safe_reason(%{__struct__: struct}), do: struct
  defp log_safe_reason(reason) when is_atom(reason), do: reason
  defp log_safe_reason(_), do: :unknown

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AdButlerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
