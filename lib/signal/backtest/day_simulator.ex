defmodule Signal.Backtest.DaySimulator do
  @moduledoc """
  Lightweight single-day trade simulator for sandbox testing.

  Runs a strategy against one day's data and returns simulated trades
  without persisting to the database. Designed for quick iteration
  and visual analysis on the symbol view.

  ## Example

      {:ok, trades} = DaySimulator.run("AAPL", ~D[2025-01-15], %{
        strategy: :break_and_retest,
        target_r: Decimal.new("2.0")
      })
  """

  import Ecto.Query
  alias Signal.MarketData.Bar
  alias Signal.Technicals.KeyLevels
  alias Signal.Technicals.Levels
  alias Signal.Strategies.BreakAndRetest
  alias Signal.Repo

  @doc """
  Runs a single-day simulation for the given symbol and date.

  ## Options

    * `:strategy` - Strategy to use (default: `:break_and_retest`)
    * `:target_r` - R-multiple for take profit (default: 2.0)
    * `:min_rr` - Minimum risk/reward to take a setup (default: 2.0)

  ## Returns

    * `{:ok, trades}` - List of simulated trade maps
  """
  def run(symbol, date, opts \\ %{}) do
    target_r = Map.get(opts, :target_r, Decimal.new("2.0"))
    min_rr = Map.get(opts, :min_rr, Decimal.new("2.0"))

    # Load bars for the day (full session for context)
    all_bars = load_all_bars(symbol, date)

    if Enum.empty?(all_bars) do
      {:ok, []}
    else
      # Get or calculate key levels for the day
      case get_or_calculate_levels(symbol, date) do
        {:ok, levels} ->
          # Run strategy to get setups
          setups = generate_setups(symbol, all_bars, levels, min_rr)

          # Load regular session bars for trade simulation
          session_bars = filter_regular_session(all_bars, date)

          # Simulate each setup as a trade
          trades = simulate_trades(setups, session_bars, target_r)

          {:ok, trades}

        {:error, _reason} ->
          # If no levels, try without them (simplified approach)
          {:ok, []}
      end
    end
  end

  # Load all bars for the day (premarket + regular session)
  defp load_all_bars(symbol, date) do
    start_dt = datetime_for_time(date, ~T[04:00:00], "America/New_York")
    end_dt = datetime_for_time(date, ~T[16:00:00], "America/New_York")

    from(b in Bar,
      where: b.symbol == ^symbol,
      where: b.bar_time >= ^start_dt,
      where: b.bar_time <= ^end_dt,
      order_by: [asc: b.bar_time]
    )
    |> Repo.all()
  end

  defp filter_regular_session(bars, date) do
    session_start = datetime_for_time(date, ~T[09:30:00], "America/New_York")
    session_end = datetime_for_time(date, ~T[16:00:00], "America/New_York")

    Enum.filter(bars, fn bar ->
      DateTime.compare(bar.bar_time, session_start) != :lt &&
        DateTime.compare(bar.bar_time, session_end) != :gt
    end)
  end

  defp datetime_for_time(date, time, timezone) do
    DateTime.new!(date, time, timezone)
    |> DateTime.shift_zone!("Etc/UTC")
  end

  defp get_or_calculate_levels(symbol, date) do
    symbol_str = to_string(symbol)

    # Try to fetch existing levels
    query =
      from(l in KeyLevels,
        where: l.symbol == ^symbol_str and l.date == ^date
      )

    case Repo.one(query) do
      nil ->
        # Try to calculate them
        Levels.calculate_daily_levels(String.to_atom(symbol), date)

      levels ->
        {:ok, levels}
    end
  end

  # Generate setups using break_and_retest strategy
  defp generate_setups(symbol, bars, levels, min_rr) do
    # Need enough bars for analysis
    if length(bars) < 30 do
      []
    else
      case BreakAndRetest.evaluate(symbol, bars, levels, min_rr: min_rr) do
        {:ok, setups} -> setups
        _ -> []
      end
    end
  end

  # Simulate trades from setups
  defp simulate_trades(setups, bars, target_r) do
    # Create a map of bars by time for quick lookup
    bars_by_time = Map.new(bars, fn bar -> {bar.bar_time, bar} end)
    bar_times = Enum.map(bars, & &1.bar_time) |> Enum.sort(DateTime)

    Enum.map(setups, fn setup ->
      simulate_single_trade(setup, bars_by_time, bar_times, target_r)
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp simulate_single_trade(setup, bars_by_time, bar_times, target_r) do
    # Find the bar closest to when the setup was generated
    # Use retest_bar.bar_time as the signal time
    signal_time = setup.retest_bar && setup.retest_bar.bar_time

    if is_nil(signal_time) do
      nil
    else
      # Find the nearest bar at or after signal time
      entry_bar =
        bar_times
        |> Enum.find(fn t -> DateTime.compare(t, signal_time) != :lt end)
        |> then(&Map.get(bars_by_time, &1))

      if is_nil(entry_bar) do
        nil
      else
        # Entry at the signal bar close
        entry_price = entry_bar.close
        entry_time = entry_bar.bar_time

        # Calculate stop and target from entry
        risk = calculate_risk(entry_price, setup.stop_loss, setup.direction)

        # Ensure valid risk
        if Decimal.compare(risk, Decimal.new("0.01")) == :lt do
          nil
        else
          target_price = calculate_target(entry_price, risk, setup.direction, target_r)

          # Find bars after entry
          future_bars =
            bar_times
            |> Enum.filter(&(DateTime.compare(&1, entry_time) == :gt))
            |> Enum.map(&Map.get(bars_by_time, &1))
            |> Enum.reject(&is_nil/1)

          # Simulate the trade outcome
          {exit_price, exit_time, status} =
            find_exit(future_bars, setup.direction, setup.stop_loss, target_price)

          # Calculate R-multiple
          r_multiple = calculate_r_multiple(entry_price, exit_price, risk, setup.direction)

          %{
            id: Ecto.UUID.generate(),
            symbol: setup.symbol,
            direction: setup.direction,
            entry_price: entry_price,
            entry_time: entry_time,
            stop_loss: setup.stop_loss,
            take_profit: target_price,
            exit_price: exit_price,
            exit_time: exit_time,
            status: status,
            r_multiple: r_multiple,
            level_type: setup.level_type,
            level_price: setup.level_price
          }
        end
      end
    end
  end

  defp calculate_risk(entry_price, stop_loss, direction) do
    case direction do
      :long -> Decimal.sub(entry_price, stop_loss) |> Decimal.abs()
      :short -> Decimal.sub(stop_loss, entry_price) |> Decimal.abs()
    end
  end

  defp calculate_target(entry_price, risk, direction, target_r) do
    target_move = Decimal.mult(risk, target_r)

    case direction do
      :long -> Decimal.add(entry_price, target_move)
      :short -> Decimal.sub(entry_price, target_move)
    end
  end

  defp find_exit(bars, direction, stop_loss, target_price) do
    # Walk through bars and find first stop or target hit
    result =
      Enum.reduce_while(bars, nil, fn bar, _acc ->
        cond do
          # Check stop hit first (worst case)
          stop_hit?(bar, stop_loss, direction) ->
            {:halt, {stop_loss, bar.bar_time, :stopped_out}}

          # Check target hit
          target_hit?(bar, target_price, direction) ->
            {:halt, {target_price, bar.bar_time, :target_hit}}

          true ->
            {:cont, nil}
        end
      end)

    case result do
      nil ->
        # No stop or target hit - exit at last bar close (time exit)
        last_bar = List.last(bars)

        if last_bar do
          {last_bar.close, last_bar.bar_time, :time_exit}
        else
          {nil, nil, :open}
        end

      exit ->
        exit
    end
  end

  defp stop_hit?(bar, stop_loss, :long) do
    Decimal.compare(bar.low, stop_loss) in [:lt, :eq]
  end

  defp stop_hit?(bar, stop_loss, :short) do
    Decimal.compare(bar.high, stop_loss) in [:gt, :eq]
  end

  defp target_hit?(bar, target, :long) do
    Decimal.compare(bar.high, target) in [:gt, :eq]
  end

  defp target_hit?(bar, target, :short) do
    Decimal.compare(bar.low, target) in [:lt, :eq]
  end

  defp calculate_r_multiple(entry_price, exit_price, risk, direction) do
    if is_nil(exit_price) || Decimal.compare(risk, Decimal.new(0)) != :gt do
      Decimal.new(0)
    else
      pnl =
        case direction do
          :long -> Decimal.sub(exit_price, entry_price)
          :short -> Decimal.sub(entry_price, exit_price)
        end

      Decimal.div(pnl, risk) |> Decimal.round(2)
    end
  end
end
