defmodule AdButler.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

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

    children = [
      AdButlerWeb.Telemetry,
      AdButler.Vault,
      AdButler.Repo,
      {DNSCluster, query: Application.get_env(:ad_butler, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: AdButler.PubSub},
      AdButler.Meta.RateLimitStore,
      {PlugAttack.Storage.Ets, name: :plug_attack_storage, clean_period: 60_000},
      {Oban, Application.fetch_env!(:ad_butler, Oban)},
      # Start to serve requests, typically the last entry
      AdButlerWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: AdButler.Supervisor]
    Supervisor.start_link(children, opts)
  end

  def handle_oban_event(
        [:oban, :job, :stop],
        _measurements,
        %{state: :discarded, job: job},
        _config
      ) do
    require Logger

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
    require Logger

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
    require Logger

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
