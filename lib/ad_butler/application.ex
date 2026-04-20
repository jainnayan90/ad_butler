defmodule AdButler.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AdButlerWeb.Telemetry,
      AdButler.Repo,
      {DNSCluster, query: Application.get_env(:ad_butler, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: AdButler.PubSub},
      # Start a worker by calling: AdButler.Worker.start_link(arg)
      # {AdButler.Worker, arg},
      # Start to serve requests, typically the last entry
      AdButlerWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: AdButler.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AdButlerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
