defmodule Signal.Analytics.EquityCurve do
  @moduledoc """
  Processes and analyzes equity curve data for risk-adjusted return metrics.

  ## Metrics Calculated

  - **Return Stats**: Total return, annualized return
  - **Risk Stats**: Volatility (annualized std dev)
  - **Risk-Adjusted**: Sharpe ratio, Sortino ratio, Calmar ratio
  - **Rolling Metrics**: Rolling Sharpe, rolling win rate

  ## Usage

      equity_curve = account.equity_curve
      initial_capital = Decimal.new("100000")

      {:ok, analysis} = EquityCurve.analyze(equity_curve, initial_capital)

      analysis.sharpe_ratio  # => Decimal.new("1.85")
      analysis.total_return_pct  # => Decimal.new("27.00")
  """

  defstruct [
    :data_points,
    :initial_equity,
    :final_equity,
    :peak_equity,
    :trough_equity,
    :total_return_pct,
    :total_return_dollars,
    :annualized_return_pct,
    :volatility,
    :sharpe_ratio,
    :sortino_ratio,
    :calmar_ratio,
    :trading_days,
    :first_date,
    :last_date,
    :returns
  ]

  @type data_point :: %{
          timestamp: DateTime.t(),
          equity: Decimal.t(),
          drawdown_pct: Decimal.t()
        }

  @type t :: %__MODULE__{
          data_points: list(data_point()),
          initial_equity: Decimal.t(),
          final_equity: Decimal.t(),
          peak_equity: Decimal.t(),
          trough_equity: Decimal.t(),
          total_return_pct: Decimal.t(),
          total_return_dollars: Decimal.t(),
          annualized_return_pct: Decimal.t() | nil,
          volatility: Decimal.t() | nil,
          sharpe_ratio: Decimal.t() | nil,
          sortino_ratio: Decimal.t() | nil,
          calmar_ratio: Decimal.t() | nil,
          trading_days: non_neg_integer(),
          first_date: Date.t() | nil,
          last_date: Date.t() | nil,
          returns: list(Decimal.t())
        }

  @zero Decimal.new(0)
  @hundred Decimal.new(100)
  @trading_days_per_year 252

  @doc """
  Analyzes an equity curve and calculates risk-adjusted metrics.

  ## Parameters

    * `equity_curve` - List of `{DateTime.t(), Decimal.t()}` tuples
    * `initial_capital` - Starting capital as Decimal
    * `opts` - Options:
      * `:risk_free_rate` - Annualized risk-free rate (default: 0)
      * `:max_drawdown` - Pre-calculated max drawdown for Calmar (optional)

  ## Returns

    * `{:ok, %EquityCurve{}}` - Analysis completed
    * `{:error, reason}` - Analysis failed
  """
  @spec analyze(list({DateTime.t(), Decimal.t()}), Decimal.t(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def analyze(equity_curve, initial_capital, opts \\ []) do
    risk_free_rate = Keyword.get(opts, :risk_free_rate, @zero)
    max_drawdown = Keyword.get(opts, :max_drawdown)

    sorted_curve = sort_curve(equity_curve)

    if Enum.empty?(sorted_curve) do
      {:ok, empty_analysis(initial_capital)}
    else
      {:ok, do_analyze(sorted_curve, initial_capital, risk_free_rate, max_drawdown)}
    end
  end

  @doc """
  Calculates period-over-period returns from equity values.

  Returns a list of percentage returns.
  """
  @spec calculate_returns(list({DateTime.t(), Decimal.t()})) :: list(Decimal.t())
  def calculate_returns([]), do: []
  def calculate_returns([_single]), do: []

  def calculate_returns(equity_curve) do
    sorted = sort_curve(equity_curve)

    sorted
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [{_t1, prev_equity}, {_t2, curr_equity}] ->
      if Decimal.compare(prev_equity, @zero) == :gt do
        Decimal.sub(curr_equity, prev_equity)
        |> Decimal.div(prev_equity)
        |> Decimal.mult(@hundred)
      else
        @zero
      end
    end)
  end

  @doc """
  Calculates Sharpe ratio from returns.

  Sharpe = (Mean Return - Risk Free Rate) / Std Dev of Returns

  Annualized assuming 252 trading days per year.
  """
  @spec sharpe_ratio(list(Decimal.t()), Decimal.t()) :: Decimal.t() | nil
  def sharpe_ratio(returns, risk_free_rate \\ @zero)
  def sharpe_ratio(returns, _rf) when length(returns) < 2, do: nil

  def sharpe_ratio(returns, risk_free_rate) do
    mean_return = mean(returns)
    std_dev = std_dev(returns, mean_return)

    if std_dev && Decimal.compare(std_dev, @zero) == :gt do
      # Convert annual risk-free to daily
      daily_rf = Decimal.div(risk_free_rate, Decimal.new(@trading_days_per_year))
      excess_return = Decimal.sub(mean_return, daily_rf)

      # Annualize
      annualization = :math.sqrt(@trading_days_per_year) |> Decimal.from_float()

      Decimal.div(excess_return, std_dev)
      |> Decimal.mult(annualization)
      |> Decimal.round(2)
    else
      nil
    end
  end

  @doc """
  Calculates Sortino ratio from returns.

  Like Sharpe but only penalizes downside volatility.
  """
  @spec sortino_ratio(list(Decimal.t()), Decimal.t()) :: Decimal.t() | nil
  def sortino_ratio(returns, risk_free_rate \\ @zero)
  def sortino_ratio(returns, _rf) when length(returns) < 2, do: nil

  def sortino_ratio(returns, risk_free_rate) do
    mean_return = mean(returns)
    downside_dev = downside_deviation(returns)

    if downside_dev && Decimal.compare(downside_dev, @zero) == :gt do
      daily_rf = Decimal.div(risk_free_rate, Decimal.new(@trading_days_per_year))
      excess_return = Decimal.sub(mean_return, daily_rf)

      annualization = :math.sqrt(@trading_days_per_year) |> Decimal.from_float()

      Decimal.div(excess_return, downside_dev)
      |> Decimal.mult(annualization)
      |> Decimal.round(2)
    else
      nil
    end
  end

  @doc """
  Calculates Calmar ratio.

  Calmar = Annualized Return / Max Drawdown

  Higher is better - indicates good return relative to risk.
  """
  @spec calmar_ratio(Decimal.t(), Decimal.t()) :: Decimal.t() | nil
  def calmar_ratio(_ann_return, max_dd) when max_dd == @zero, do: nil

  def calmar_ratio(annualized_return, max_drawdown_pct) do
    if max_drawdown_pct && Decimal.compare(max_drawdown_pct, @zero) == :gt do
      Decimal.div(annualized_return, max_drawdown_pct) |> Decimal.round(2)
    else
      nil
    end
  end

  @doc """
  Calculates rolling metrics over a specified window.

  Returns a list of `{timestamp, metrics}` tuples.
  """
  @spec rolling_metrics(list({DateTime.t(), Decimal.t()}), non_neg_integer()) ::
          list({DateTime.t(), map()})
  def rolling_metrics(equity_curve, window_size \\ 20)
  def rolling_metrics(equity_curve, _window) when length(equity_curve) < 3, do: []

  def rolling_metrics(equity_curve, window_size) do
    sorted = sort_curve(equity_curve)

    sorted
    |> Enum.chunk_every(window_size, 1, :discard)
    |> Enum.map(fn window ->
      {last_time, _last_equity} = List.last(window)
      returns = calculate_returns(window)

      metrics = %{
        sharpe: sharpe_ratio(returns),
        volatility: volatility(returns),
        return: total_return_for_window(window)
      }

      {last_time, metrics}
    end)
  end

  @doc """
  Formats equity curve for charting libraries.

  Returns data in a format suitable for frontend visualization.
  """
  @spec to_chart_data(t()) :: list(map())
  def to_chart_data(%__MODULE__{data_points: data_points}) do
    Enum.map(data_points, fn point ->
      %{
        timestamp: DateTime.to_iso8601(point.timestamp),
        equity: Decimal.to_float(point.equity),
        drawdown_pct: Decimal.to_float(point.drawdown_pct)
      }
    end)
  end

  # Private Functions

  defp sort_curve(equity_curve) do
    equity_curve
    |> Enum.sort_by(fn {time, _equity} -> DateTime.to_unix(time) end)
  end

  defp empty_analysis(initial_capital) do
    %__MODULE__{
      data_points: [],
      initial_equity: initial_capital,
      final_equity: initial_capital,
      peak_equity: initial_capital,
      trough_equity: initial_capital,
      total_return_pct: @zero,
      total_return_dollars: @zero,
      annualized_return_pct: nil,
      volatility: nil,
      sharpe_ratio: nil,
      sortino_ratio: nil,
      calmar_ratio: nil,
      trading_days: 0,
      first_date: nil,
      last_date: nil,
      returns: []
    }
  end

  defp do_analyze(sorted_curve, initial_capital, risk_free_rate, max_drawdown) do
    # Build data points with drawdown
    data_points = build_data_points(sorted_curve, initial_capital)

    # Extract values
    {first_time, _} = List.first(sorted_curve)
    {last_time, final_equity} = List.last(sorted_curve)

    equities = Enum.map(sorted_curve, fn {_t, e} -> e end)
    peak = Enum.max_by(equities, &Decimal.to_float/1)
    trough = Enum.min_by(equities, &Decimal.to_float/1)

    # Calculate returns
    returns = calculate_returns(sorted_curve)

    # Calculate total return
    total_return_dollars = Decimal.sub(final_equity, initial_capital)

    total_return_pct =
      if Decimal.compare(initial_capital, @zero) == :gt do
        Decimal.div(total_return_dollars, initial_capital)
        |> Decimal.mult(@hundred)
        |> Decimal.round(2)
      else
        @zero
      end

    # Calculate trading days
    first_date = DateTime.to_date(first_time)
    last_date = DateTime.to_date(last_time)
    calendar_days = Date.diff(last_date, first_date)
    # Approximate trading days (5/7 of calendar days)
    trading_days = max(round(calendar_days * 5 / 7), 1)

    # Calculate annualized return
    annualized_return =
      if trading_days > 0 do
        annualize_return(total_return_pct, trading_days)
      else
        nil
      end

    # Calculate volatility
    vol = volatility(returns)

    # Calculate Sharpe and Sortino
    sharpe = sharpe_ratio(returns, risk_free_rate)
    sortino = sortino_ratio(returns, risk_free_rate)

    # Calculate Calmar (need max drawdown)
    max_dd =
      max_drawdown ||
        calculate_max_drawdown_pct(sorted_curve, initial_capital)

    calmar =
      if annualized_return do
        calmar_ratio(annualized_return, max_dd)
      else
        nil
      end

    %__MODULE__{
      data_points: data_points,
      initial_equity: initial_capital,
      final_equity: final_equity,
      peak_equity: peak,
      trough_equity: trough,
      total_return_pct: total_return_pct,
      total_return_dollars: total_return_dollars,
      annualized_return_pct: annualized_return,
      volatility: vol,
      sharpe_ratio: sharpe,
      sortino_ratio: sortino,
      calmar_ratio: calmar,
      trading_days: trading_days,
      first_date: first_date,
      last_date: last_date,
      returns: returns
    }
  end

  defp build_data_points(sorted_curve, initial_capital) do
    {data_points, _peak} =
      Enum.reduce(sorted_curve, {[], initial_capital}, fn {time, equity}, {points, peak} ->
        new_peak = Decimal.max(peak, equity)

        drawdown_pct =
          if Decimal.compare(new_peak, @zero) == :gt do
            Decimal.sub(new_peak, equity)
            |> Decimal.div(new_peak)
            |> Decimal.mult(@hundred)
            |> Decimal.round(2)
          else
            @zero
          end

        point = %{
          timestamp: time,
          equity: equity,
          drawdown_pct: drawdown_pct
        }

        {[point | points], new_peak}
      end)

    Enum.reverse(data_points)
  end

  defp annualize_return(total_return_pct, trading_days) do
    # Annualized return = (1 + total_return)^(252/days) - 1
    total_return_decimal = Decimal.div(total_return_pct, @hundred)
    one_plus_return = Decimal.add(Decimal.new(1), total_return_decimal)

    exponent = @trading_days_per_year / trading_days

    annualized =
      one_plus_return
      |> Decimal.to_float()
      |> :math.pow(exponent)
      |> Kernel.-(1)
      |> Kernel.*(100)
      |> Decimal.from_float()
      |> Decimal.round(2)

    annualized
  end

  defp volatility(returns) when length(returns) < 2, do: nil

  defp volatility(returns) do
    mean_ret = mean(returns)
    daily_vol = std_dev(returns, mean_ret)

    if daily_vol do
      # Annualize volatility
      annualization = :math.sqrt(@trading_days_per_year) |> Decimal.from_float()
      Decimal.mult(daily_vol, annualization) |> Decimal.round(2)
    else
      nil
    end
  end

  defp total_return_for_window(window) do
    {_first_time, first_equity} = List.first(window)
    {_last_time, last_equity} = List.last(window)

    if Decimal.compare(first_equity, @zero) == :gt do
      Decimal.sub(last_equity, first_equity)
      |> Decimal.div(first_equity)
      |> Decimal.mult(@hundred)
      |> Decimal.round(2)
    else
      @zero
    end
  end

  defp calculate_max_drawdown_pct(sorted_curve, initial_capital) do
    {_peak, max_dd_pct} =
      Enum.reduce(sorted_curve, {initial_capital, @zero}, fn {_time, equity}, {peak, max_dd} ->
        new_peak = Decimal.max(peak, equity)

        dd_pct =
          if Decimal.compare(new_peak, @zero) == :gt do
            Decimal.sub(new_peak, equity)
            |> Decimal.div(new_peak)
            |> Decimal.mult(@hundred)
          else
            @zero
          end

        {new_peak, Decimal.max(max_dd, dd_pct)}
      end)

    Decimal.round(max_dd_pct, 2)
  end

  # Statistical helpers

  defp mean(values) when length(values) == 0, do: @zero

  defp mean(values) do
    sum = Enum.reduce(values, @zero, &Decimal.add/2)
    Decimal.div(sum, Decimal.new(length(values)))
  end

  defp std_dev(values, _mean) when length(values) < 2, do: nil

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
