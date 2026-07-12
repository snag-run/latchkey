defmodule Latchkey.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        LatchkeyWeb.Telemetry,
        Latchkey.Repo,
        {DNSCluster, query: Application.get_env(:latchkey, :dns_cluster_query) || :ignore},
        {Oban, Application.fetch_env!(:latchkey, Oban)},
        {Phoenix.PubSub, name: Latchkey.PubSub}
      ] ++
        commanded_children() ++
        [
          # Start to serve requests, typically the last entry
          LatchkeyWeb.Endpoint
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Latchkey.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # The event-sourcing write side. Disabled in :test (see config/test.exs) so the
  # sandboxed suite doesn't boot Commanded; integration tests start it explicitly.
  defp commanded_children do
    if Application.get_env(:latchkey, :start_commanded, true) do
      [
        Latchkey.CommandedApp,
        Latchkey.PropertyManagement.ArrearsProjector,
        Latchkey.PropertyManagement.PaymentAcl
      ]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    LatchkeyWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
