defmodule Signal.Analytics.TradeMetrics do
  @moduledoc """
  Calculates core trading performance metrics from a list of closed trades.

  ## Metrics Calculated

  - **Win/Loss Stats**: Total trades, winners, losers, win rate
  - **P&L Stats**: Gross profit, gross loss, net profit, profit factor
  - **Average Stats**: Average win, average loss, expectancy
  - **R-Multiple Stats**: Average R, max R, min R
  - **Hold Time Stats**: Average, max, min hold time in minutes

  ## Usage

      trades = account.closed_trades
      {:ok, metrics} = TradeMetrics.calculate(trades)

      metrics.win_rate  # => Decimal.new("65.56")
      metrics.profit_factor  # => Decimal.new("2.50")
  """

  defstruct [
    :total_trades,
    :winners,
    :losers,
    :breakeven,
    :win_rate,
    :loss_rate,
    :gross_profit,
    :gross_loss,
    :net_profit,
    :profit_factor,
    :avg_win,
    :avg_loss,
    :expectancy,
    :avg_r_multiple,
    :max_r_multiple,
    :min_r_multiple,
    :avg_pnl,
    :max_pnl,
    :min_pnl,
    :avg_hold_time_minutes,
    :max_hold_time_minutes,
    :min_hold_time_minutes,
    :total_hold_time_minutes
  ]

  @type t :: %__MODULE__{
          total_trades: non_neg_integer(),
          winners: non_neg_integer(),
          losers: non_neg_integer(),
          breakeven: non_neg_integer(),
          win_rate: Decimal.t(),
          loss_rate: Decimal.t(),
          gross_profit: Decimal.t(),
          gross_loss: Decimal.t(),
          net_profit: Decimal.t(),
          profit_factor: Decimal.t() | nil,
          avg_win: Decimal.t() | nil,
          avg_loss: Decimal.t() | nil,
          expectancy: Decimal.t(),
          avg_r_multiple: Decimal.t() | nil,
          max_r_multiple: Decimal.t() | nil,
          min_r_multiple: Decimal.t() | nil,
          avg_pnl: Decimal.t(),
          max_pnl: Decimal.t() | nil,
          min_pnl: Decimal.t() | nil,
          avg_hold_time_minutes: non_neg_integer() | nil,
          max_hold_time_minutes: non_neg_integer() | nil,
          min_hold_time_minutes: non_neg_integer() | nil,
          total_hold_time_minutes: non_neg_integer()
        }

  @zero Decimal.new(0)
  @hundred Decimal.new(100)

  @doc """
  Calculates trade metrics from a list of closed trades.

  ## Parameters

    * `trades` - List of trade maps, each containing:
      * `:pnl` - Profit/loss as Decimal
      * `:r_multiple` - R-multiple as Decimal
      * `:entry_time` - Entry timestamp
      * `:exit_time` - Exit timestamp

  ## Returns

    * `{:ok, %TradeMetrics{}}` - Metrics calculated successfully
    * `{:error, reason}` - Calculation failed
  """
  @spec calculate(list(map())) :: {:ok, t()} | {:error, term()}
  def calculate(trades) when is_list(trades) do
    if Enum.empty?(trades) do
      {:ok, empty_metrics()}
    else
      {:ok, do_calculate(trades)}
    end
  end

  @doc """
  Calculates profit factor (gross profit / gross loss).

  Returns `nil` if there are no losses (infinite profit factor).
  """
  @spec profit_factor(Decimal.t(), Decimal.t()) :: Decimal.t() | nil
  def profit_factor(gross_profit, gross_loss) do
    # gross_loss is stored as positive number
    if Decimal.compare(gross_loss, @zero) == :gt do
      Decimal.div(gross_profit, gross_loss) |> Decimal.round(2)
    else
      nil
    end
  end

  @doc """
  Calculates expectancy (expected value per trade).

  Expectancy = (Win Rate * Avg Win) - (Loss Rate * Avg Loss)
  """
  @spec expectancy(Decimal.t(), Decimal.t() | nil, Decimal.t(), Decimal.t() | nil) :: Decimal.t()
  def expectancy(win_rate, avg_win, loss_rate, avg_loss) do
    win_component =
      if avg_win do
        Decimal.mult(Decimal.div(win_rate, @hundred), avg_win)
      else
        @zero
      end

    loss_component =
      if avg_loss do
        # avg_loss is stored as positive, so we subtract
        Decimal.mult(Decimal.div(loss_rate, @hundred), avg_loss)
      else
        @zero
      end

    Decimal.sub(win_component, loss_component) |> Decimal.round(2)
  end

  @doc """
  Calculates Sharpe ratio from a series of returns.

  Sharpe = (Mean Return - Risk Free Rate) / Std Dev of Returns

  ## Parameters

    * `returns` - List of period returns as Decimals
    * `risk_free_rate` - Annualized risk-free rate (default: 0)
    * `periods_per_year` - Number of periods per year for annualization (default: 252)
  """
  @spec sharpe_ratio(list(Decimal.t()), Decimal.t(), non_neg_integer()) :: Decimal.t() | nil
  def sharpe_ratio(returns, risk_free_rate \\ @zero, periods_per_year \\ 252)

  def sharpe_ratio(returns, _risk_free_rate, _periods_per_year) when length(returns) < 2 do
    nil
  end

  def sharpe_ratio(returns, risk_free_rate, periods_per_year) do
    mean = mean(returns)
    std_dev = std_dev(returns, mean)

    if Decimal.compare(std_dev, @zero) == :gt do
      # Convert annual risk-free to period risk-free
      period_rf = Decimal.div(risk_free_rate, Decimal.new(periods_per_year))
      excess_return = Decimal.sub(mean, period_rf)

      # Annualize: Sharpe * sqrt(periods_per_year)
      annualization_factor = :math.sqrt(periods_per_year) |> Decimal.from_float()

      Decimal.div(excess_return, std_dev)
      |> Decimal.mult(annualization_factor)
      |> Decimal.round(2)
    else
      nil
    end
  end

  @doc """
  Calculates Sortino ratio from a series of returns.

  Like Sharpe, but only penalizes downside volatility.

  Sortino = (Mean Return - Risk Free Rate) / Downside Deviation
  """
  @spec sortino_ratio(list(Decimal.t()), Decimal.t(), non_neg_integer()) :: Decimal.t() | nil
  def sortino_ratio(returns, risk_free_rate \\ @zero, periods_per_year \\ 252)

  def sortino_ratio(returns, _risk_free_rate, _periods_per_year) when length(returns) < 2 do
    nil
  end

  def sortino_ratio(returns, risk_free_rate, periods_per_year) do
    mean = mean(returns)
    downside_dev = downside_deviation(returns)

    if downside_dev && Decimal.compare(downside_dev, @zero) == :gt do
      period_rf = Decimal.div(risk_free_rate, Decimal.new(periods_per_year))
      excess_return = Decimal.sub(mean, period_rf)

      annualization_factor = :math.sqrt(periods_per_year) |> Decimal.from_float()

      Decimal.div(excess_return, downside_dev)
      |> Decimal.mult(annualization_factor)
      |> Decimal.round(2)
    else
      nil
    end
  end

  @doc """
  Calculates exit strategy effectiveness metrics.

  Analyzes trades by exit type, trailing stop effectiveness, scaled exit performance,
  breakeven impact, and Maximum Favorable/Adverse Excursion (MFE/MAE).

  ## Parameters

    * `trades` - List of trade maps with exit strategy fields:
      * `:exit_strategy_type` - "fixed", "trailing", "scaled", or "combined"
      * `:stop_moved_to_breakeven` - Boolean
      * `:partial_exit_count` - Number of partial exits
      * `:max_favorable_r` - Maximum R reached during trade
      * `:max_adverse_r` - Maximum adverse R reached during trade
      * `:r_multiple` - Final R-multiple

  ## Returns

  A map containing:
    * `:by_exit_type` - Breakdown by exit strategy type
    * `:trailing_stop_effectiveness` - Trailing stop analysis (or nil)
    * `:scale_out_analysis` - Scaled exit analysis (or nil)
    * `:breakeven_impact` - Comparison of BE vs non-BE trades
    * `:max_favorable_excursion` - MFE analysis
    * `:max_adverse_excursion` - MAE analysis
  """
  @spec exit_strategy_analysis(list(map())) :: map()
  def exit_strategy_analysis(trades) when is_list(trades) do
    %{
      by_exit_type: group_by_exit_type(trades),
      trailing_stop_effectiveness: trailing_effectiveness(trades),
      scale_out_analysis: scale_out_analysis(trades),
      breakeven_impact: breakeven_impact(trades),
      max_favorable_excursion: mfe_analysis(trades),
      max_adverse_excursion: mae_analysis(trades)
    }
  end

  @doc """
  Groups trades by exit strategy type and calculates metrics for each group.
  """
  @spec group_by_exit_type(list(map())) :: map()
  def group_by_exit_type(trades) when is_list(trades) do
    trades
    |> Enum.group_by(&get_exit_strategy_type/1)
    |> Enum.map(fn {type, group_trades} ->
      {type,
       %{
         count: length(group_trades),
         win_rate: calculate_win_rate(group_trades),
         avg_r: calculate_average_r(group_trades),
         total_pnl: sum_pnl(group_trades)
       }}
    end)
    |> Enum.into(%{})
  end

  # Private Functions

  defp do_calculate(trades) do
    # Separate winners, losers, breakeven
    {winners, losers, breakeven} = partition_trades(trades)

    # Calculate P&L stats
    gross_profit = sum_pnl(winners)
    gross_loss = sum_pnl(losers) |> Decimal.abs()
    net_profit = Decimal.sub(gross_profit, gross_loss)

    # Calculate counts
    total = length(trades)
    win_count = length(winners)
    loss_count = length(losers)
    breakeven_count = length(breakeven)

    # Calculate rates
    win_rate = percentage(win_count, total)
    loss_rate = percentage(loss_count, total)

    # Calculate averages
    avg_win =
      if win_count > 0,
        do: Decimal.div(gross_profit, Decimal.new(win_count)) |> Decimal.round(2),
        else: nil

    avg_loss =
      if loss_count > 0,
        do: Decimal.div(gross_loss, Decimal.new(loss_count)) |> Decimal.round(2),
        else: nil

    # Calculate profit factor and expectancy
    pf = profit_factor(gross_profit, gross_loss)
    exp = expectancy(win_rate, avg_win, loss_rate, avg_loss)

    # Calculate R-multiple stats
    r_multiples = extract_r_multiples(trades)
    {avg_r, max_r, min_r} = r_multiple_stats(r_multiples)

    # Calculate P&L stats
    pnls = extract_pnls(trades)

    avg_pnl =
      if total > 0,
        do: Decimal.div(net_profit, Decimal.new(total)) |> Decimal.round(2),
        else: @zero

    max_pnl = if total > 0, do: Enum.max_by(pnls, &Decimal.to_float/1), else: nil
    min_pnl = if total > 0, do: Enum.min_by(pnls, &Decimal.to_float/1), else: nil

    # Calculate hold time stats
    hold_times = calculate_hold_times(trades)
    {avg_hold, max_hold, min_hold, total_hold} = hold_time_stats(hold_times)

    %__MODULE__{
      total_trades: total,
      winners: win_count,
      losers: loss_count,
      breakeven: breakeven_count,
      win_rate: win_rate,
      loss_rate: loss_rate,
      gross_profit: gross_profit,
      gross_loss: gross_loss,
      net_profit: net_profit,
      profit_factor: pf,
      avg_win: avg_win,
      avg_loss: avg_loss,
      expectancy: exp,
      avg_r_multiple: avg_r,
      max_r_multiple: max_r,
      min_r_multiple: min_r,
      avg_pnl: avg_pnl,
      max_pnl: max_pnl,
      min_pnl: min_pnl,
      avg_hold_time_minutes: avg_hold,
      max_hold_time_minutes: max_hold,
      min_hold_time_minutes: min_hold,
      total_hold_time_minutes: total_hold
    }
  end

  defp empty_metrics do
    %__MODULE__{
      total_trades: 0,
      winners: 0,
      losers: 0,
      breakeven: 0,
      win_rate: @zero,
      loss_rate: @zero,
      gross_profit: @zero,
      gross_loss: @zero,
      net_profit: @zero,
      profit_factor: nil,
      avg_win: nil,
      avg_loss: nil,
      expectancy: @zero,
      avg_r_multiple: nil,
      max_r_multiple: nil,
      min_r_multiple: nil,
      avg_pnl: @zero,
      max_pnl: nil,
      min_pnl: nil,
      avg_hold_time_minutes: nil,
      max_hold_time_minutes: nil,
      min_hold_time_minutes: nil,
      total_hold_time_minutes: 0
    }
  end

  defp partition_trades(trades) do
    Enum.reduce(trades, {[], [], []}, fn trade, {winners, losers, breakeven} ->
      pnl = Map.get(trade, :pnl, @zero) || @zero

      case Decimal.compare(pnl, @zero) do
        :gt -> {[trade | winners], losers, breakeven}
        :lt -> {winners, [trade | losers], breakeven}
        :eq -> {winners, losers, [trade | breakeven]}
      end
    end)
  end

  defp sum_pnl(trades) do
    Enum.reduce(trades, @zero, fn trade, acc ->
      pnl = Map.get(trade, :pnl, @zero) || @zero
      Decimal.add(acc, pnl)
    end)
  end

  defp percentage(_count, 0), do: @zero

  defp percentage(count, total) do
    Decimal.div(Decimal.new(count * 100), Decimal.new(total))
    |> Decimal.round(2)
  end

  defp extract_r_multiples(trades) do
    trades
    |> Enum.map(&Map.get(&1, :r_multiple))
    |> Enum.reject(&is_nil/1)
  end

  defp r_multiple_stats([]), do: {nil, nil, nil}

  defp r_multiple_stats(r_multiples) do
    sum = Enum.reduce(r_multiples, @zero, &Decimal.add/2)
    avg = Decimal.div(sum, Decimal.new(length(r_multiples))) |> Decimal.round(2)
    max_r = Enum.max_by(r_multiples, &Decimal.to_float/1)
    min_r = Enum.min_by(r_multiples, &Decimal.to_float/1)

    {avg, max_r, min_r}
  end

  defp extract_pnls(trades) do
    trades
    |> Enum.map(&(Map.get(&1, :pnl) || @zero))
  end

  defp calculate_hold_times(trades) do
    trades
    |> Enum.map(fn trade ->
      entry = Map.get(trade, :entry_time)
      exit = Map.get(trade, :exit_time)

      if entry && exit do
        DateTime.diff(exit, entry, :minute)
      else
        nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp hold_time_stats([]), do: {nil, nil, nil, 0}

  defp hold_time_stats(hold_times) do
    total = Enum.sum(hold_times)
    avg = div(total, length(hold_times))
    max_hold = Enum.max(hold_times)
    min_hold = Enum.min(hold_times)

    {avg, max_hold, min_hold, total}
  end

  # Statistical helpers

  defp mean(values) when length(values) == 0, do: @zero

  defp mean(values) do
    sum = Enum.reduce(values, @zero, &Decimal.add/2)
    Decimal.div(sum, Decimal.new(length(values)))
  end

  defp std_dev(values, _mean) when length(values) < 2, do: @zero

  defp std_dev(values, mean) do
    n = length(values)

    sum_sq_diff =
      Enum.reduce(values, @zero, fn val, acc ->
        diff = Decimal.sub(val, mean)
        sq_diff = Decimal.mult(diff, diff)
        Decimal.add(acc, sq_diff)
      end)

    variance = Decimal.div(sum_sq_diff, Decimal.new(n - 1))

    variance
    |> Decimal.to_float()
    |> :math.sqrt()
    |> Decimal.from_float()
  end

  defp downside_deviation(returns) when length(returns) < 2, do: nil

  defp downside_deviation(returns) do
    # Only consider negative returns
    negative_returns = Enum.filter(returns, &(Decimal.compare(&1, @zero) == :lt))

    if Enum.empty?(negative_returns) do
      @zero
    else
      n = length(returns)

      sum_sq =
        Enum.reduce(negative_returns, @zero, fn val, acc ->
          sq = Decimal.mult(val, val)
          Decimal.add(acc, sq)
        end)

      variance = Decimal.div(sum_sq, Decimal.new(n))

      variance
      |> Decimal.to_float()
      |> :math.sqrt()
      |> Decimal.from_float()
    end
  end

  # Exit strategy analysis helpers

  defp get_exit_strategy_type(trade) do
    Map.get(trade, :exit_strategy_type) || "fixed"
  end

  defp calculate_win_rate([]), do: @zero

  defp calculate_win_rate(trades) do
    winners =
      Enum.count(trades, fn trade ->
        pnl = Map.get(trade, :pnl, @zero) || @zero
        Decimal.compare(pnl, @zero) == :gt
      end)

    percentage(winners, length(trades))
  end

  defp calculate_average_r([]), do: nil

  defp calculate_average_r(trades) do
    r_values =
      trades
      |> Enum.map(&Map.get(&1, :r_multiple))
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(r_values) do
      nil
    else
      sum = Enum.reduce(r_values, @zero, &Decimal.add/2)
      Decimal.div(sum, Decimal.new(length(r_values))) |> Decimal.round(2)
    end
  end

  defp trailing_effectiveness(trades) do
    trailing_trades =
      Enum.filter(trades, fn trade ->
        get_exit_strategy_type(trade) == "trailing"
      end)

    if Enum.empty?(trailing_trades) do
      nil
    else
      %{
        count: length(trailing_trades),
        avg_captured_r: calculate_average_r(trailing_trades),
        avg_mfe_captured_pct: calculate_mfe_capture_percentage(trailing_trades)
      }
    end
  end

  defp scale_out_analysis(trades) do
    scaled_trades =
      Enum.filter(trades, fn trade ->
        (Map.get(trade, :partial_exit_count) || 0) > 0
      end)

    if Enum.empty?(scaled_trades) do
      nil
    else
      %{
        count: length(scaled_trades),
        avg_partial_exits: calculate_avg_partial_exits(scaled_trades),
        avg_total_r: calculate_average_r(scaled_trades),
        vs_fixed_comparison: compare_scaled_to_fixed(trades)
      }
    end
  end

  defp breakeven_impact(trades) do
    be_trades = Enum.filter(trades, &(Map.get(&1, :stop_moved_to_breakeven) == true))
    non_be_trades = Enum.reject(trades, &(Map.get(&1, :stop_moved_to_breakeven) == true))

    %{
      trades_moved_to_be: length(be_trades),
      be_win_rate: calculate_win_rate(be_trades),
      non_be_win_rate: calculate_win_rate(non_be_trades),
      be_avg_r: calculate_average_r(be_trades),
      non_be_avg_r: calculate_average_r(non_be_trades)
    }
  end

  defp mfe_analysis(trades) do
    trades_with_mfe =
      Enum.filter(trades, fn trade ->
        Map.get(trade, :max_favorable_r) != nil
      end)

    %{
      avg_mfe: calculate_avg_decimal(trades_with_mfe, :max_favorable_r),
      avg_captured_pct: calculate_mfe_capture_percentage(trades_with_mfe),
      left_on_table: calculate_left_on_table(trades_with_mfe)
    }
  end

  defp mae_analysis(trades) do
    trades_with_mae =
      Enum.filter(trades, fn trade ->
        Map.get(trade, :max_adverse_r) != nil
      end)

    %{
      avg_mae: calculate_avg_decimal(trades_with_mae, :max_adverse_r),
      winners_avg_mae: calculate_winners_avg_mae(trades_with_mae),
      losers_avg_mae: calculate_losers_avg_mae(trades_with_mae)
    }
  end

  defp calculate_avg_decimal([], _field), do: nil

  defp calculate_avg_decimal(trades, field) do
    values =
      trades
      |> Enum.map(&Map.get(&1, field))
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(values) do
      nil
    else
      sum = Enum.reduce(values, @zero, &Decimal.add/2)
      Decimal.div(sum, Decimal.new(length(values))) |> Decimal.round(2)
    end
  end

  defp calculate_mfe_capture_percentage([]), do: nil

  defp calculate_mfe_capture_percentage(trades) do
    # Capture rate = (actual R / MFE R) * 100 for winning trades
    trades_with_data =
      Enum.filter(trades, fn trade ->
        mfe = Map.get(trade, :max_favorable_r)
        r = Map.get(trade, :r_multiple)
        mfe != nil && r != nil && Decimal.compare(mfe, @zero) == :gt
      end)

    if Enum.empty?(trades_with_data) do
      nil
    else
      capture_rates =
        Enum.map(trades_with_data, fn trade ->
          mfe = Map.get(trade, :max_favorable_r)
          r = Map.get(trade, :r_multiple)
          # Capture rate as percentage (how much of MFE was captured)
          Decimal.div(r, mfe) |> Decimal.mult(@hundred)
        end)

      avg =
        capture_rates
        |> Enum.reduce(@zero, &Decimal.add/2)
        |> Decimal.div(Decimal.new(length(capture_rates)))
        |> Decimal.round(2)

      # Cap at 100% (can't capture more than MFE)
      if Decimal.compare(avg, @hundred) == :gt, do: @hundred, else: avg
    end
  end

  defp calculate_left_on_table([]), do: nil

  defp calculate_left_on_table(trades) do
    # Left on table = MFE - actual R (average)
    trades_with_data =
      Enum.filter(trades, fn trade ->
        mfe = Map.get(trade, :max_favorable_r)
        r = Map.get(trade, :r_multiple)
        mfe != nil && r != nil
      end)

    if Enum.empty?(trades_with_data) do
      nil
    else
      left_on_table_values =
        Enum.map(trades_with_data, fn trade ->
          mfe = Map.get(trade, :max_favorable_r)
          r = Map.get(trade, :r_multiple)
          # Can be negative if trade went worse than entry
          Decimal.sub(mfe, r)
        end)

      left_on_table_values
      |> Enum.reduce(@zero, &Decimal.add/2)
      |> Decimal.div(Decimal.new(length(left_on_table_values)))
      |> Decimal.round(2)
    end
  end

  defp calculate_avg_partial_exits([]), do: @zero

  defp calculate_avg_partial_exits(trades) do
    total =
      Enum.reduce(trades, 0, fn trade, acc ->
        acc + (Map.get(trade, :partial_exit_count) || 0)
      end)

    (total / length(trades)) |> Float.round(2) |> Decimal.from_float()
  end

  defp compare_scaled_to_fixed(trades) do
    scaled_trades =
      Enum.filter(trades, fn trade ->
        (Map.get(trade, :partial_exit_count) || 0) > 0
      end)

    fixed_trades =
      Enum.filter(trades, fn trade ->
        (Map.get(trade, :partial_exit_count) || 0) == 0 &&
          get_exit_strategy_type(trade) == "fixed"
      end)

    if Enum.empty?(scaled_trades) || Enum.empty?(fixed_trades) do
      nil
    else
      scaled_avg = calculate_average_r(scaled_trades)
      fixed_avg = calculate_average_r(fixed_trades)

      if scaled_avg && fixed_avg do
        %{
          scaled_avg_r: scaled_avg,
          fixed_avg_r: fixed_avg,
          r_difference: Decimal.sub(scaled_avg, fixed_avg) |> Decimal.round(2)
        }
      else
        nil
      end
    end
  end

  defp calculate_winners_avg_mae(trades) do
    winners =
      Enum.filter(trades, fn trade ->
        pnl = Map.get(trade, :pnl, @zero) || @zero
        Decimal.compare(pnl, @zero) == :gt
      end)

    calculate_avg_decimal(winners, :max_adverse_r)
  end

  defp calculate_losers_avg_mae(trades) do
    losers =
      Enum.filter(trades, fn trade ->
        pnl = Map.get(trade, :pnl, @zero) || @zero
        Decimal.compare(pnl, @zero) == :lt
      end)

    calculate_avg_decimal(losers, :max_adverse_r)
  end
end
