defmodule Signal.Monitor do
  @moduledoc """
  Track system health metrics and detect anomalies.

  This GenServer monitors:
  - Message rates (quotes/bars/trades per period)
  - Connection status and uptime
  - Database health
  - System anomalies

  Publishes stats every 60 seconds to PubSub "system:stats" topic.

  ## Examples

      iex> Signal.Monitor.track_message(:quote)
      :ok

      iex> Signal.Monitor.get_stats()
      %{quotes_per_sec: 137, bars_per_min: 25, ...}
  """

  use GenServer
  require Logger

  @stats_interval :timer.seconds(60)

  # Client API

  @doc """
  Start the Monitor GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Record a message received.

  ## Parameters

    - `type` - Message type (:quote | :bar | :trade)

  ## Returns

    - `:ok`
  """
  @spec track_message(:quote | :bar | :trade) :: :ok
  def track_message(type) when type in [:quote, :bar, :trade] do
    GenServer.cast(__MODULE__, {:track_message, type})
  end

  @doc """
  Record an error.

  ## Parameters

    - `error` - Error details (any type)

  ## Returns

    - `:ok`
  """
  @spec track_error(any()) :: :ok
  def track_error(error) do
    GenServer.cast(__MODULE__, {:track_error, error})
  end

  @doc """
  Update connection status.

  ## Parameters

    - `status` - Connection status (:connected | :disconnected | :reconnecting)

  ## Returns

    - `:ok`
  """
  @spec track_connection(:connected | :disconnected | :reconnecting) :: :ok
  def track_connection(status) when status in [:connected, :disconnected, :reconnecting] do
    GenServer.cast(__MODULE__, {:track_connection, status})
  end

  @doc """
  Get current statistics.

  ## Returns

    - Map with current stats
  """
  @spec get_stats() :: map()
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Schedule first stats report
    Process.send_after(self(), :report_stats, @stats_interval)

    state = %{
      counters: %{quotes: 0, bars: 0, trades: 0, errors: 0},
      connection_status: :disconnected,
      connection_start: nil,
      last_message: %{
        quote: nil,
        bar: nil,
        trade: nil
      },
      reconnect_count: 0,
      window_start: DateTime.utc_now(),
      db_healthy: true,
      last_db_check: DateTime.utc_now()
    }

    Logger.info("Monitor initialized")

    {:ok, state}
  end

  @impl true
  def handle_cast({:track_message, type}, state) do
    # Increment counter
    new_counters = Map.update!(state.counters, type, &(&1 + 1))

    # Update last message timestamp
    new_last_message = Map.put(state.last_message, type, DateTime.utc_now())

    new_state =
      state
      |> Map.put(:counters, new_counters)
      |> Map.put(:last_message, new_last_message)

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:track_error, _error}, state) do
    # Increment error counter
    new_counters = Map.update!(state.counters, :errors, &(&1 + 1))

    {:noreply, Map.put(state, :counters, new_counters)}
  end

  @impl true
  def handle_cast({:track_connection, new_status}, state) do
    new_state =
      case {state.connection_status, new_status} do
        {:disconnected, :connected} ->
          # Just connected
          state
          |> Map.put(:connection_status, :connected)
          |> Map.put(:connection_start, DateTime.utc_now())

        {old, :reconnecting} when old in [:connected, :disconnected] ->
          # Starting reconnection
          state
          |> Map.put(:connection_status, :reconnecting)
          |> Map.update!(:reconnect_count, &(&1 + 1))

        {_old, new_status} ->
          # Other status change
          Map.put(state, :connection_status, new_status)
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    stats = build_stats(state)
    {:reply, stats, state}
  end

  @impl true
  def handle_info(:report_stats, state) do
    # Calculate rates
    window_seconds = DateTime.diff(DateTime.utc_now(), state.window_start, :second)
    window_seconds = max(window_seconds, 1)

    quotes_per_sec = div(state.counters.quotes, window_seconds)
    bars_per_min = state.counters.bars
    trades_per_sec = div(state.counters.trades, window_seconds)

    # Check database health
    db_healthy = check_database_health()

    # Log summary
    Logger.info(
      "[Monitor] Stats (#{window_seconds}s): quotes=#{state.counters.quotes} (#{quotes_per_sec}/s), " <>
        "bars=#{state.counters.bars} (#{bars_per_min}/min), " <>
        "trades=#{state.counters.trades} (#{trades_per_sec}/s), " <>
        "errors=#{state.counters.errors}, " <>
        "uptime=#{format_uptime(state.connection_start)}, " <>
        "db=#{if db_healthy, do: "healthy", else: "unhealthy"}"
    )

    # Check for anomalies
    check_anomalies(state, quotes_per_sec, bars_per_min)

    # Build and publish stats to PubSub
    stats = %{
      quotes_per_sec: quotes_per_sec,
      bars_per_min: bars_per_min,
      trades_per_sec: trades_per_sec,
      uptime_seconds: calculate_uptime_seconds(state.connection_start),
      connection_status: state.connection_status,
      db_healthy: db_healthy,
      reconnect_count: state.reconnect_count,
      last_message: state.last_message
    }

    Phoenix.PubSub.broadcast(Signal.PubSub, "system:stats", stats)

    # Reset counters and schedule next report
    new_state =
      state
      |> Map.put(:counters, %{quotes: 0, bars: 0, trades: 0, errors: 0})
      |> Map.put(:window_start, DateTime.utc_now())
      |> Map.put(:db_healthy, db_healthy)
      |> Map.put(:last_db_check, DateTime.utc_now())

    Process.send_after(self(), :report_stats, @stats_interval)

    {:noreply, new_state}
  end

  # Private Helper Functions

  defp build_stats(state) do
    %{
      counters: state.counters,
      connection_status: state.connection_status,
      connection_start: state.connection_start,
      last_message: state.last_message,
      reconnect_count: state.reconnect_count,
      db_healthy: state.db_healthy
    }
  end

  defp check_database_health do
    try do
      Ecto.Adapters.SQL.query!(Signal.Repo, "SELECT 1")
      true
    rescue
      _ -> false
    end
  end

  defp calculate_uptime_seconds(nil), do: 0

  defp calculate_uptime_seconds(connection_start) do
    DateTime.diff(DateTime.utc_now(), connection_start, :second)
  end

  defp format_uptime(nil), do: "0m"

  defp format_uptime(connection_start) do
    seconds = calculate_uptime_seconds(connection_start)
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)

    cond do
      hours > 0 -> "#{hours}h #{minutes}m"
      minutes > 0 -> "#{minutes}m"
      true -> "#{seconds}s"
    end
  end

  defp check_anomalies(state, quotes_per_sec, bars_per_min) do
    # Check if quote rate is 0 during market hours
    if quotes_per_sec == 0 and market_open?() do
      Logger.warning("[Monitor] WARNING: Quote rate is 0 during market hours")
    end

    # Check if bar rate is 0 for extended period during market hours
    if bars_per_min == 0 and market_open?() do
      Logger.warning("[Monitor] WARNING: Bar rate is 0 during market hours")
    end

    # Check for excessive reconnections
    if state.reconnect_count > 10 do
      Logger.error("[Monitor] ERROR: High reconnection count (#{state.reconnect_count})")
    end

    # Check for prolonged disconnection
    if state.connection_status == :disconnected and
         calculate_uptime_seconds(state.connection_start) > 300 do
      Logger.error("[Monitor] ERROR: Disconnected for over 5 minutes")
    end

    # Check database health
    if not state.db_healthy do
      Logger.error("[Monitor] ERROR: Database is unhealthy")
    end
  end

  defp market_open? do
    # Simple market hours check (9:30 AM - 4:00 PM ET, Monday-Friday)
    # This is a simplified version - production should use tz library
    now = DateTime.now!("America/New_York")
    time = DateTime.to_time(now)
    day = Date.day_of_week(DateTime.to_date(now))

    # Monday-Friday (1-5), 9:30 AM - 4:00 PM
    day >= 1 and day <= 5 and
      Time.compare(time, ~T[09:30:00]) != :lt and
      Time.compare(time, ~T[16:00:00]) != :gt
  rescue
    # If timezone library isn't available, assume market is open
    _ -> true
  end
end
