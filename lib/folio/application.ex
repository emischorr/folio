defmodule Folio.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      FolioWeb.Telemetry,
      Folio.Repo,
      {Oban, Application.fetch_env!(:folio, Oban)},
      {Task, &Folio.Bootstrap.run/0},
      {DNSCluster, query: Application.get_env(:folio, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Folio.PubSub},
      Folio.MarketData.Cache,
      Folio.MarketData.RateLimiter,
      Folio.MarketData.SourceStats,
      # Start a worker by calling: Folio.Worker.start_link(arg)
      # {Folio.Worker, arg},
      # Start to serve requests, typically the last entry
      FolioWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Folio.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    FolioWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
