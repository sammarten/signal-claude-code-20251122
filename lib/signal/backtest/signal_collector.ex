defmodule Signal.Backtest.SignalCollector do
  @moduledoc """
  Collects and generates signals during backtests.

  The SignalCollector subscribes to bar updates, evaluates strategies,
  generates signals from setups, and forwards them to the TradeSimulator.

  ## How It Works

  1. Subscribes to PubSub bar topics for configured symbols
  2. Maintains rolling window of bars for each symbol
  3. Tracks key levels (PDH/PDL, ORH/ORL) for each symbol
  4. On each bar, evaluates configured strategies
  5. Generates signals from valid setups
  6. Forwards signals to TradeSimulator

  ## Usage

      {:ok, collector} = SignalCollector.start_link(
        run_id: "abc123",
        symbols: ["AAPL", "TSLA"],
        strategies: [:break_and_retest],
        trade_simulator: trade_simulator_pid
      )
  """

  use GenServer
  require Logger

  alias Signal.Strategies.BreakAndRetest
  alias Signal.Technicals.KeyLevels
  alias Signal.Backtest.TradeSimulator
  alias Signal.Backtest.VirtualClock

  @bar_window_size 100

  defstruct [
    :run_id,
    :symbols,
    :strategies,
    :trade_simulator,
    :clock,
    :bar_windows,
    :key_levels,
    :signals_generated,
    :min_rr
  ]

  # Client API

  @doc """
  Starts the signal collector.

  ## Options

    * `:run_id` - Backtest run ID (required)
    * `:symbols` - List of symbols to monitor (required)
    * `:strategies` - List of strategy atoms (required)
    * `:trade_simulator` - TradeSimulator server (required)
    * `:clock` - VirtualClock server (required)
    * `:min_rr` - Minimum risk/reward ratio (default: 2.0)
    * `:name` - Optional GenServer name
  """
  def start_link(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    name = Keyword.get(opts, :name, via_tuple(run_id))
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Processes a new bar.
  """
  @spec process_bar(GenServer.server(), map()) :: :ok
  def process_bar(collector, bar) do
    GenServer.cast(collector, {:bar, bar})
  end

  @doc """
  Returns the number of signals generated.
  """
  @spec signals_count(GenServer.server()) :: integer()
  def signals_count(collector) do
    GenServer.call(collector, :signals_count)
  end

  @doc """
  Stops the collector.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(collector) do
    GenServer.stop(collector, :normal)
  end

  @doc """
  Returns the Registry via tuple for a run_id.
  """
  def via_tuple(run_id) do
    {:via, Registry, {Signal.Backtest.Registry, {:signal_collector, run_id}}}
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    symbols = Keyword.fetch!(opts, :symbols)
    strategies = Keyword.fetch!(opts, :strategies)
    trade_simulator = Keyword.fetch!(opts, :trade_simulator)
    clock = Keyword.fetch!(opts, :clock)
    min_rr = Keyword.get(opts, :min_rr, Decimal.new("2.0"))

    # Initialize bar windows and key levels for each symbol
    bar_windows = Map.new(symbols, fn symbol -> {symbol, []} end)
    key_levels = Map.new(symbols, fn symbol -> {symbol, %KeyLevels{symbol: symbol}} end)

    state = %__MODULE__{
      run_id: run_id,
      symbols: symbols,
      strategies: strategies,
      trade_simulator: trade_simulator,
      clock: clock,
      bar_windows: bar_windows,
      key_levels: key_levels,
      signals_generated: 0,
      min_rr: min_rr
    }

    Logger.debug(
      "[SignalCollector] Started for run #{run_id}, strategies: #{inspect(strategies)}"
    )

    {:ok, state}
  end

  @impl true
  def handle_cast({:bar, bar}, state) do
    if bar.symbol in state.symbols do
      state
      |> update_bar_window(bar)
      |> update_key_levels(bar)
      |> evaluate_strategies(bar)
      |> then(&{:noreply, &1})
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_call(:signals_count, _from, state) do
    {:reply, state.signals_generated, state}
  end

  # Private Functions

  defp update_bar_window(state, bar) do
    symbol = bar.symbol
    current_window = Map.get(state.bar_windows, symbol, [])

    # Add new bar to the end, trim to window size
    new_window =
      (current_window ++ [bar])
      |> Enum.take(-@bar_window_size)

    %{state | bar_windows: Map.put(state.bar_windows, symbol, new_window)}
  end

  defp update_key_levels(state, bar) do
    symbol = bar.symbol
    current_levels = Map.get(state.key_levels, symbol, %KeyLevels{symbol: symbol})

    # Get the current simulated date in ET
    current_date =
      case VirtualClock.today_et(state.clock) do
        nil -> nil
        date -> date
      end

    # Get bar time in ET
    bar_time_et = DateTime.shift_zone!(bar.bar_time, "America/New_York")
    bar_date = DateTime.to_date(bar_time_et)
    bar_time = DateTime.to_time(bar_time_et)

    # Update levels based on bar timing
    updated_levels =
      current_levels
      |> maybe_update_previous_day_levels(bar, bar_date, current_date)
      |> maybe_update_premarket_levels(bar, bar_time)
      |> maybe_update_opening_range(bar, bar_time, state.bar_windows[symbol])

    %{state | key_levels: Map.put(state.key_levels, symbol, updated_levels)}
  end

  defp maybe_update_previous_day_levels(levels, bar, bar_date, current_date) do
    # If this is the first bar of a new day, the previous day's levels need updating
    # For simplicity in backtest, we track intraday high/low and roll them over
    if current_date && Date.compare(bar_date, current_date) == :gt do
      # New day - previous day levels should already be set from yesterday's tracking
      levels
    else
      # Same day - track intraday high/low for potential rollover
      update_intraday_levels(levels, bar)
    end
  end

  defp update_intraday_levels(levels, bar) do
    # Track the day's high/low (will become PDH/PDL tomorrow)
    high =
      case levels.previous_day_high do
        nil -> bar.high
        prev -> Decimal.max(prev, bar.high)
      end

    low =
      case levels.previous_day_low do
        nil -> bar.low
        prev -> Decimal.min(prev, bar.low)
      end

    %{levels | previous_day_high: high, previous_day_low: low}
  end

  defp maybe_update_premarket_levels(levels, bar, bar_time) do
    # Premarket is 4:00 AM - 9:30 AM ET
    premarket_start = ~T[04:00:00]
    market_open = ~T[09:30:00]

    if Time.compare(bar_time, premarket_start) != :lt and
         Time.compare(bar_time, market_open) == :lt do
      high =
        case levels.premarket_high do
          nil -> bar.high
          prev -> Decimal.max(prev, bar.high)
        end

      low =
        case levels.premarket_low do
          nil -> bar.low
          prev -> Decimal.min(prev, bar.low)
        end

      %{levels | premarket_high: high, premarket_low: low}
    else
      levels
    end
  end

  defp maybe_update_opening_range(levels, _bar, bar_time, bar_window) do
    market_open = ~T[09:30:00]
    or5_end = ~T[09:35:00]
    or15_end = ~T[09:45:00]

    cond do
      # Before market open - no OR yet
      Time.compare(bar_time, market_open) == :lt ->
        levels

      # During OR5 window (9:30-9:35)
      Time.compare(bar_time, or5_end) == :lt ->
        update_or_from_window(levels, bar_window, :or5)

      # During OR15 window but after OR5 (9:35-9:45)
      Time.compare(bar_time, or15_end) == :lt ->
        update_or_from_window(levels, bar_window, :or15)

      # After OR window
      true ->
        levels
    end
  end

  defp update_or_from_window(levels, bar_window, or_type) do
    # Get bars within the opening range window
    or_bars =
      Enum.filter(bar_window, fn bar ->
        bar_time_et = DateTime.shift_zone!(bar.bar_time, "America/New_York")
        time = DateTime.to_time(bar_time_et)
        Time.compare(time, ~T[09:30:00]) != :lt
      end)

    if Enum.empty?(or_bars) do
      levels
    else
      high = Enum.reduce(or_bars, Decimal.new(0), fn b, acc -> Decimal.max(acc, b.high) end)
      low = Enum.reduce(or_bars, Decimal.new("999999"), fn b, acc -> Decimal.min(acc, b.low) end)

      case or_type do
        :or5 ->
          %{levels | opening_range_5m_high: high, opening_range_5m_low: low}

        :or15 ->
          %{
            levels
            | opening_range_15m_high: high,
              opening_range_15m_low: low,
              opening_range_5m_high: levels.opening_range_5m_high || high,
              opening_range_5m_low: levels.opening_range_5m_low || low
          }
      end
    end
  end

  defp evaluate_strategies(state, bar) do
    symbol = bar.symbol
    bars = Map.get(state.bar_windows, symbol, [])
    levels = Map.get(state.key_levels, symbol, %KeyLevels{symbol: symbol})

    # Check if we're in trading window (9:30 AM - 11:00 AM ET)
    current_time = VirtualClock.now(state.clock)

    if in_trading_window?(current_time) and length(bars) >= 10 do
      # Evaluate each strategy
      Enum.reduce(state.strategies, state, fn strategy, acc_state ->
        evaluate_strategy(acc_state, strategy, symbol, bars, levels)
      end)
    else
      state
    end
  end

  defp in_trading_window?(nil), do: false

  defp in_trading_window?(current_time) do
    et_time =
      current_time
      |> DateTime.shift_zone!("America/New_York")
      |> DateTime.to_time()

    # Trading window: 9:30 AM - 11:00 AM ET
    Time.compare(et_time, ~T[09:30:00]) != :lt and
      Time.compare(et_time, ~T[11:00:00]) == :lt
  end

  defp evaluate_strategy(state, :break_and_retest, symbol, bars, levels) do
    case BreakAndRetest.evaluate(symbol, bars, levels, min_rr: state.min_rr) do
      {:ok, setups} when setups != [] ->
        # Generate signals from setups and forward to trade simulator
        Enum.reduce(setups, state, fn setup, acc ->
          generate_and_forward_signal(acc, setup)
        end)

      _ ->
        state
    end
  end

  defp evaluate_strategy(state, _other_strategy, _symbol, _bars, _levels) do
    # Other strategies not yet implemented for backtest
    state
  end

  defp generate_and_forward_signal(state, setup) do
    # Create a signal map that the TradeSimulator expects
    signal = %{
      id: Ecto.UUID.generate(),
      symbol: setup.symbol,
      direction: setup.direction,
      entry_price: setup.entry_price,
      stop_loss: setup.stop_loss,
      take_profit: setup.take_profit,
      strategy: setup.strategy,
      level_type: setup.level_type,
      generated_at: VirtualClock.now(state.clock)
    }

    # Forward to trade simulator
    TradeSimulator.submit_signal(state.trade_simulator, signal)

    Logger.debug(
      "[SignalCollector] Generated #{setup.direction} signal for #{setup.symbol} " <>
        "at #{setup.entry_price}, stop: #{setup.stop_loss}, target: #{setup.take_profit}"
    )

    %{state | signals_generated: state.signals_generated + 1}
  end
end
