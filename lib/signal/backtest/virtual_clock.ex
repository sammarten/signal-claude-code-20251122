defmodule Signal.Backtest.VirtualClock do
  @moduledoc """
  Simulates time progression during backtests.

  The VirtualClock replaces system time calls during backtests, allowing
  modules to query the "current" time which advances as bars are replayed.

  ## Usage

      # Start a clock for a backtest
      {:ok, clock} = VirtualClock.start_link(run_id: "abc123")

      # Advance time (called by BarReplayer)
      VirtualClock.advance(clock, ~U[2024-01-15 14:31:00Z])

      # Query current time
      VirtualClock.now(clock)
      #=> ~U[2024-01-15 14:31:00Z]

      # Check if within market hours
      VirtualClock.market_open?(clock)
      #=> true

  ## Market Hours

  The clock is aware of US market hours (9:30 AM - 4:00 PM ET) and can
  report whether the current simulated time falls within trading hours.
  """

  use GenServer
  require Logger

  @timezone "America/New_York"
  @market_open ~T[09:30:00]
  @market_close ~T[16:00:00]

  # Client API

  @doc """
  Starts a VirtualClock for a backtest run.

  ## Options

    * `:run_id` - The backtest run ID (required)
    * `:name` - Optional name for the GenServer

  ## Examples

      {:ok, clock} = VirtualClock.start_link(run_id: "abc123")
  """
  def start_link(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    name = Keyword.get(opts, :name, via_tuple(run_id))
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns the current simulated time.
  """
  @spec now(GenServer.server()) :: DateTime.t() | nil
  def now(clock) do
    GenServer.call(clock, :now)
  end

  @doc """
  Returns the current simulated date.
  """
  @spec today(GenServer.server()) :: Date.t() | nil
  def today(clock) do
    case now(clock) do
      nil -> nil
      datetime -> DateTime.to_date(datetime)
    end
  end

  @doc """
  Returns the current simulated date in Eastern Time.
  """
  @spec today_et(GenServer.server()) :: Date.t() | nil
  def today_et(clock) do
    case now(clock) do
      nil ->
        nil

      datetime ->
        datetime
        |> DateTime.shift_zone!(@timezone)
        |> DateTime.to_date()
    end
  end

  @doc """
  Advances the clock to the given time.

  Called by the BarReplayer as it processes each bar.
  """
  @spec advance(GenServer.server(), DateTime.t()) :: :ok
  def advance(clock, datetime) do
    GenServer.cast(clock, {:advance, datetime})
  end

  @doc """
  Returns true if the current simulated time is within market hours.

  Market hours are 9:30 AM - 4:00 PM Eastern Time.
  """
  @spec market_open?(GenServer.server()) :: boolean()
  def market_open?(clock) do
    GenServer.call(clock, :market_open?)
  end

  @doc """
  Returns the current time in Eastern timezone.
  """
  @spec now_et(GenServer.server()) :: DateTime.t() | nil
  def now_et(clock) do
    case now(clock) do
      nil -> nil
      datetime -> DateTime.shift_zone!(datetime, @timezone)
    end
  end

  @doc """
  Returns the time of day in Eastern timezone.
  """
  @spec time_et(GenServer.server()) :: Time.t() | nil
  def time_et(clock) do
    case now_et(clock) do
      nil -> nil
      datetime -> DateTime.to_time(datetime)
    end
  end

  @doc """
  Resets the clock to nil (no time set).
  """
  @spec reset(GenServer.server()) :: :ok
  def reset(clock) do
    GenServer.cast(clock, :reset)
  end

  @doc """
  Stops the clock.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(clock) do
    GenServer.stop(clock, :normal)
  end

  @doc """
  Returns the Registry via tuple for a run_id.
  """
  def via_tuple(run_id) do
    {:via, Registry, {Signal.Backtest.Registry, {:clock, run_id}}}
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    run_id = Keyword.fetch!(opts, :run_id)

    state = %{
      run_id: run_id,
      current_time: nil,
      bars_seen: 0
    }

    Logger.debug("[VirtualClock] Started for run #{run_id}")
    {:ok, state}
  end

  @impl true
  def handle_call(:now, _from, state) do
    {:reply, state.current_time, state}
  end

  @impl true
  def handle_call(:market_open?, _from, state) do
    result =
      case state.current_time do
        nil ->
          false

        datetime ->
          et_datetime = DateTime.shift_zone!(datetime, @timezone)
          time = DateTime.to_time(et_datetime)

          Time.compare(time, @market_open) in [:eq, :gt] and
            Time.compare(time, @market_close) == :lt
      end

    {:reply, result, state}
  end

  @impl true
  def handle_cast({:advance, datetime}, state) do
    new_state = %{
      state
      | current_time: datetime,
        bars_seen: state.bars_seen + 1
    }

    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:reset, state) do
    {:noreply, %{state | current_time: nil, bars_seen: 0}}
  end
end
