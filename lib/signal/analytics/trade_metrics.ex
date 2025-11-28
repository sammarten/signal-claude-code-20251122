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
end
