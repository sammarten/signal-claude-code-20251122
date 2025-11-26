defmodule Signal.Technicals.OpeningRangeCalculator do
  @moduledoc """
  GenServer that automatically calculates opening ranges at 9:35 AM and 9:45 AM ET.

  Subscribes to bar updates and tracks when the appropriate number of bars
  have been received for each symbol to trigger opening range calculations.

  ## How It Works

  1. At startup, subscribes to bar updates for all configured symbols
  2. Tracks bars received during the opening range window (9:30-9:45 AM ET)
  3. When 5 bars have been received for a symbol, calculates OR5
  4. When 15 bars have been received for a symbol, calculates OR15
  5. Resets tracking state at midnight ET for the next trading day

  ## Configuration

  Uses the same symbols configured in `:signal, :symbols`.
  """

  use GenServer
  require Logger

  alias Signal.Technicals.Levels

  @or5_bars 5
  @or15_bars 15

  # State structure:
  # %{
  #   date: Date.t(),           # Current trading date
  #   symbols: %{
  #     "AAPL" => %{
  #       bar_count: 0,         # Bars received in opening range window
  #       or5_calculated: false,
  #       or15_calculated: false
  #     },
  #     ...
  #   }
  # }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the current state of opening range tracking for debugging.
  """
  def get_state do
    GenServer.call(__MODULE__, :get_state)
  end

  @doc """
  Manually reset the state for a new trading day.
  """
  def reset do
    GenServer.cast(__MODULE__, :reset)
  end

  @doc """
  Recalculate opening ranges from historical bars for today.

  Use this when:
  - The server was started after market open
  - Opening ranges weren't calculated due to connection issues
  - You want to force a recalculation

  Returns a map of results per symbol.

  ## Examples

      iex> OpeningRangeCalculator.recalculate()
      %{
        "AAPL" => %{or5: :ok, or15: :ok},
        "TSLA" => %{or5: :ok, or15: {:error, :insufficient_bars}}
      }

      iex> OpeningRangeCalculator.recalculate(["AAPL"])
      %{"AAPL" => %{or5: :ok, or15: :ok}}
  """
  def recalculate(symbols \\ nil) do
    symbols = symbols || Application.get_env(:signal, :symbols, [])
    date = current_trading_date()

    results =
      symbols
      |> Enum.map(fn symbol ->
        symbol_str = to_string(symbol)
        symbol_atom = if is_atom(symbol), do: symbol, else: String.to_atom(symbol)

        or5_result = do_recalculate(symbol_atom, date, :five_min)
        or15_result = do_recalculate(symbol_atom, date, :fifteen_min)

        {symbol_str, %{or5: or5_result, or15: or15_result}}
      end)
      |> Map.new()

    # Update internal state to reflect calculations
    GenServer.cast(__MODULE__, {:mark_calculated, Map.keys(results)})

    results
  end

  defp do_recalculate(symbol, date, range_type) do
    range_name = if range_type == :five_min, do: "OR5", else: "OR15"

    case Levels.update_opening_range(symbol, date, range_type) do
      {:ok, levels} ->
        high =
          if range_type == :five_min,
            do: levels.opening_range_5m_high,
            else: levels.opening_range_15m_high

        low =
          if range_type == :five_min,
            do: levels.opening_range_5m_low,
            else: levels.opening_range_15m_low

        Logger.info(
          "[OpeningRangeCalculator] #{symbol} #{range_name} recalculated: High=#{high}, Low=#{low}"
        )

        :ok

      {:error, reason} = error ->
        Logger.warning(
          "[OpeningRangeCalculator] #{symbol} #{range_name} recalculation failed: #{inspect(reason)}"
        )

        error
    end
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    symbols = Application.get_env(:signal, :symbols, [])

    # Subscribe to bar updates for all symbols
    Enum.each(symbols, fn symbol ->
      Phoenix.PubSub.subscribe(Signal.PubSub, "bars:#{symbol}")
    end)

    # Schedule midnight reset check
    schedule_midnight_reset()

    state = %{
      date: current_trading_date(),
      symbols: initialize_symbol_state(symbols)
    }

    Logger.info("[OpeningRangeCalculator] Started for #{length(symbols)} symbols")

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast(:reset, state) do
    symbols = Map.keys(state.symbols)

    new_state = %{
      date: current_trading_date(),
      symbols: initialize_symbol_state(symbols)
    }

    Logger.info("[OpeningRangeCalculator] State reset for new trading day")
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:mark_calculated, symbol_strs}, state) do
    # Mark symbols as having their opening ranges calculated
    updated_symbols =
      Enum.reduce(symbol_strs, state.symbols, fn symbol_str, acc ->
        case Map.get(acc, symbol_str) do
          nil ->
            acc

          symbol_state ->
            Map.put(acc, symbol_str, %{
              symbol_state
              | or5_calculated: true,
                or15_calculated: true
            })
        end
      end)

    {:noreply, %{state | symbols: updated_symbols}}
  end

  @impl true
  def handle_info({:bar, symbol, bar}, state) do
    # Check if this bar is in the opening range window
    if in_opening_range_window?(bar.timestamp) and state.date == current_trading_date() do
      state = process_opening_range_bar(state, symbol, bar)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:midnight_reset, state) do
    # Reset state if date has changed
    current_date = current_trading_date()

    state =
      if state.date != current_date do
        symbols = Map.keys(state.symbols)

        Logger.info("[OpeningRangeCalculator] Midnight reset - new date: #{current_date}")

        %{
          date: current_date,
          symbols: initialize_symbol_state(symbols)
        }
      else
        state
      end

    # Schedule next check
    schedule_midnight_reset()

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private Functions

  defp initialize_symbol_state(symbols) do
    symbols
    |> Enum.map(fn symbol ->
      {to_string(symbol),
       %{
         bar_count: 0,
         or5_calculated: false,
         or15_calculated: false
       }}
    end)
    |> Map.new()
  end

  defp process_opening_range_bar(state, symbol, _bar) do
    symbol_str = to_string(symbol)

    case Map.get(state.symbols, symbol_str) do
      nil ->
        state

      symbol_state ->
        # Increment bar count
        new_count = symbol_state.bar_count + 1
        symbol_state = %{symbol_state | bar_count: new_count}

        # Check if we should calculate OR5
        symbol_state =
          if new_count >= @or5_bars and not symbol_state.or5_calculated do
            calculate_opening_range(symbol_str, state.date, :five_min)
            %{symbol_state | or5_calculated: true}
          else
            symbol_state
          end

        # Check if we should calculate OR15
        symbol_state =
          if new_count >= @or15_bars and not symbol_state.or15_calculated do
            calculate_opening_range(symbol_str, state.date, :fifteen_min)
            %{symbol_state | or15_calculated: true}
          else
            symbol_state
          end

        %{state | symbols: Map.put(state.symbols, symbol_str, symbol_state)}
    end
  end

  defp calculate_opening_range(symbol, date, range_type) do
    range_name = if range_type == :five_min, do: "OR5", else: "OR15"

    case Levels.update_opening_range(String.to_atom(symbol), date, range_type) do
      {:ok, levels} ->
        high =
          if range_type == :five_min,
            do: levels.opening_range_5m_high,
            else: levels.opening_range_15m_high

        low =
          if range_type == :five_min,
            do: levels.opening_range_5m_low,
            else: levels.opening_range_15m_low

        Logger.info(
          "[OpeningRangeCalculator] #{symbol} #{range_name} calculated: High=#{high}, Low=#{low}"
        )

      {:error, reason} ->
        Logger.warning(
          "[OpeningRangeCalculator] #{symbol} #{range_name} calculation failed: #{inspect(reason)}"
        )
    end
  end

  defp in_opening_range_window?(timestamp) do
    # Check if the bar timestamp is within 9:30-9:45 AM ET
    timezone = Application.get_env(:signal, :timezone, "America/New_York")

    case DateTime.shift_zone(timestamp, timezone) do
      {:ok, et_time} ->
        time = DateTime.to_time(et_time)
        market_open = ~T[09:30:00]
        or_window_end = ~T[09:45:00]

        Time.compare(time, market_open) != :lt and
          Time.compare(time, or_window_end) == :lt

      {:error, _} ->
        false
    end
  end

  defp current_trading_date do
    timezone = Application.get_env(:signal, :timezone, "America/New_York")
    DateTime.now!(timezone) |> DateTime.to_date()
  end

  defp schedule_midnight_reset do
    # Check every hour if we've crossed midnight
    Process.send_after(self(), :midnight_reset, :timer.hours(1))
  end
end
