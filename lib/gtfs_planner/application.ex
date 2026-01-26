defmodule GtfsPlanner.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      GtfsPlannerWeb.Telemetry,
      GtfsPlanner.Repo,
      {DNSCluster, query: Application.get_env(:gtfs_planner, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: GtfsPlanner.PubSub},
      {Task.Supervisor, name: GtfsPlanner.TaskSupervisor},
      # Start a worker by calling: GtfsPlanner.Worker.start_link(arg)
      # {GtfsPlanner.Worker, arg},
      # Start to serve requests, typically the last entry
      GtfsPlannerWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: GtfsPlanner.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    GtfsPlannerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
