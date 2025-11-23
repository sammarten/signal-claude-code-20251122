defmodule Signal.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        SignalWeb.Telemetry,
        Signal.Repo,
        {DNSCluster, query: Application.get_env(:signal, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Signal.PubSub}
      ] ++
        maybe_start_bar_cache() ++
        maybe_start_monitor() ++
        maybe_start_alpaca_stream() ++
        [
          # HTTP client for API requests
          {Finch, name: Signal.Finch},
          # Start to serve requests, typically the last entry
          SignalWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Signal.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Conditionally start BarCache (disabled in tests)
  defp maybe_start_bar_cache do
    if Application.get_env(:signal, :start_bar_cache, true) do
      [Signal.BarCache]
    else
      []
    end
  end

  # Conditionally start Monitor (disabled in tests)
  defp maybe_start_monitor do
    if Application.get_env(:signal, :start_monitor, true) do
      [Signal.Monitor]
    else
      []
    end
  end

  # Conditionally start Alpaca stream (disabled in tests)
  defp maybe_start_alpaca_stream do
    if Application.get_env(:signal, :start_alpaca_stream, true) do
      [Signal.Alpaca.StreamSupervisor]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SignalWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
