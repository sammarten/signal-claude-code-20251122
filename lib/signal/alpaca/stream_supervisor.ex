defmodule Signal.Alpaca.StreamSupervisor do
  @moduledoc """
  Supervisor for Alpaca WebSocket stream.

  Starts and manages the Alpaca.Stream process with StreamHandler as the callback.
  Automatically subscribes to configured symbols for bars, quotes, and statuses.

  Only starts if Alpaca credentials are configured. If not configured, returns
  `:ignore` and logs a warning.

  ## Startup Resilience

  If Alpaca is unavailable on startup, the Stream will retry indefinitely with
  exponential backoff. The application still starts successfully and the dashboard
  will show "disconnected" status until Alpaca becomes available.
  """

  use Supervisor
  require Logger
  alias Signal.Alpaca.{Config, Stream, StreamHandler, MockStream}

  @doc """
  Start the supervisor.

  ## Parameters

    - `opts` - Keyword list (for supervisor compatibility)

  ## Returns

    - `{:ok, pid}` if credentials are configured
    - `:ignore` if credentials are not configured
  """
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(_opts) do
    use_mock = Application.get_env(:signal, :use_mock_stream, false)

    cond do
      use_mock ->
        Logger.info("Starting MockStream for development (credentials not required)")
        children = [build_stream_child_spec(MockStream)]
        Supervisor.init(children, strategy: :one_for_one)

      Config.configured?() ->
        Logger.info("Starting Alpaca stream with configured credentials")
        children = [build_stream_child_spec(Stream)]
        Supervisor.init(children, strategy: :one_for_one)

      true ->
        Logger.warning(
          "Alpaca credentials not configured. Stream will not start. " <>
            "Set ALPACA_API_KEY and ALPACA_API_SECRET environment variables, " <>
            "or set use_mock_stream: true in config for development."
        )

        :ignore
    end
  end

  # Private functions

  defp build_stream_child_spec(stream_module) do
    symbols = get_configured_symbols()

    {stream_module,
     callback_module: StreamHandler,
     callback_state: %{
       last_quotes: %{},
       counters: %{quotes: 0, bars: 0, trades: 0, statuses: 0},
       last_log: DateTime.utc_now()
     },
     initial_subscriptions: %{
       bars: symbols,
       quotes: symbols,
       statuses: ["*"]
     },
     name: stream_module}
  end

  defp get_configured_symbols do
    Application.get_env(:signal, :symbols, [])
  end
end
