defmodule Signal.Preview.RelativeStrengthCalculator do
  @moduledoc """
  Calculates relative strength of symbols vs a benchmark (SPY or QQQ).

  ## Status Classifications

  - **strong_outperform**: RS > 3%
  - **outperform**: RS between 1% and 3%
  - **inline**: RS between -1% and 1%
  - **underperform**: RS between -3% and -1%
  - **strong_underperform**: RS < -3%

  ## Usage

      {:ok, rs} = RelativeStrengthCalculator.calculate(:NVDA, :SPY, ~D[2024-12-14])
      # => %RelativeStrength{
      #   symbol: "NVDA",
      #   rs_5d: #Decimal<2.50>,
      #   status: :outperform
      # }

      # Calculate for multiple symbols
      {:ok, results} = RelativeStrengthCalculator.calculate_all([:AAPL, :NVDA, :TSLA], :SPY, ~D[2024-12-14])
  """

  import Ecto.Query
  alias Signal.Repo
  alias Signal.MarketData.Bar
  alias Signal.Preview.RelativeStrength

  @doc """
  Calculates relative strength for a symbol vs benchmark.

  ## Parameters

    * `symbol` - Symbol to analyze
    * `benchmark` - Benchmark symbol (:SPY or :QQQ)
    * `date` - Date to analyze

  ## Returns

    * `{:ok, %RelativeStrength{}}` - RS analysis
    * `{:error, atom()}` - Error during calculation
  """
  @spec calculate(atom(), atom(), Date.t()) ::
          {:ok, RelativeStrength.t()} | {:error, atom()}
  def calculate(symbol, benchmark, date) do
    with {:ok, symbol_bars} <- fetch_daily_bars(symbol, date, 25),
         {:ok, bench_bars} <- fetch_daily_bars(benchmark, date, 25) do
      rs = calculate_rs(symbol, benchmark, date, symbol_bars, bench_bars)
      {:ok, rs}
    end
  end

  @doc """
  Calculates relative strength for multiple symbols.

  ## Parameters

    * `symbols` - List of symbols to analyze
    * `benchmark` - Benchmark symbol
    * `date` - Date to analyze

  ## Returns

    * `{:ok, [%RelativeStrength{}]}` - List of RS analyses
    * `{:error, atom()}` - Error during calculation
  """
  @spec calculate_all([atom()], atom(), Date.t()) ::
          {:ok, [RelativeStrength.t()]} | {:error, atom()}
  def calculate_all(symbols, benchmark, date) do
    with {:ok, bench_bars} <- fetch_daily_bars(benchmark, date, 25) do
      results =
        symbols
        |> Enum.map(fn symbol ->
          case fetch_daily_bars(symbol, date, 25) do
            {:ok, symbol_bars} ->
              calculate_rs(symbol, benchmark, date, symbol_bars, bench_bars)

            {:error, _} ->
              nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      {:ok, results}
    end
  end

  @doc """
  Ranks symbols by relative strength.

  ## Parameters

    * `rs_list` - List of RelativeStrength structs
    * `period` - Period to rank by (:rs_1d, :rs_5d, or :rs_20d)

  ## Returns

  Sorted list with :strong_outperform first, :strong_underperform last.
  """
  @spec rank([RelativeStrength.t()], atom()) :: [RelativeStrength.t()]
  def rank(rs_list, period \\ :rs_5d) do
    Enum.sort_by(
      rs_list,
      fn rs ->
        Map.get(rs, period) |> Decimal.to_float()
      end,
      :desc
    )
  end

  @doc """
  Gets leaders (top performers) from a list of RS analyses.
  """
  @spec get_leaders([RelativeStrength.t()], non_neg_integer()) :: [RelativeStrength.t()]
  def get_leaders(rs_list, count \\ 5) do
    rs_list
    |> rank(:rs_5d)
    |> Enum.take(count)
    |> Enum.filter(fn rs ->
      rs.status in [:strong_outperform, :outperform]
    end)
  end

  @doc """
  Gets laggards (worst performers) from a list of RS analyses.
  """
  @spec get_laggards([RelativeStrength.t()], non_neg_integer()) :: [RelativeStrength.t()]
  def get_laggards(rs_list, count \\ 5) do
    rs_list
    |> rank(:rs_5d)
    |> Enum.reverse()
    |> Enum.take(count)
    |> Enum.filter(fn rs ->
      rs.status in [:strong_underperform, :underperform]
    end)
  end

  # Private Functions

  defp fetch_daily_bars(symbol, date, days) do
    start_date = Date.add(date, -days - 5)

    query =
      from b in Bar,
        where: b.symbol == ^to_string(symbol),
        where:
          fragment("?::date >= ? AND ?::date <= ?", b.bar_time, ^start_date, b.bar_time, ^date),
        order_by: [asc: b.bar_time]

    bars = Repo.all(query)
    daily = aggregate_to_daily(bars)

    if length(daily) >= 5 do
      {:ok, daily}
    else
      {:error, :insufficient_data}
    end
  end

  defp aggregate_to_daily(bars) do
    bars
    |> Enum.group_by(fn bar ->
      DateTime.to_date(bar.bar_time)
    end)
    |> Enum.map(fn {date, day_bars} ->
      sorted = Enum.sort_by(day_bars, & &1.bar_time)

      %{
        date: date,
        close: List.last(sorted).close
      }
    end)
    |> Enum.sort_by(& &1.date)
  end

  defp calculate_rs(symbol, benchmark, date, symbol_bars, bench_bars) do
    rs_1d = calculate_relative_return(symbol_bars, bench_bars, 1)
    rs_5d = calculate_relative_return(symbol_bars, bench_bars, 5)
    rs_20d = calculate_relative_return(symbol_bars, bench_bars, 20)

    status = classify_status(rs_5d)

    %RelativeStrength{
      symbol: to_string(symbol),
      date: date,
      benchmark: to_string(benchmark),
      rs_1d: rs_1d,
      rs_5d: rs_5d,
      rs_20d: rs_20d,
      status: status
    }
  end

  defp calculate_relative_return(symbol_bars, bench_bars, days) do
    symbol_return = calculate_return(symbol_bars, days)
    bench_return = calculate_return(bench_bars, days)

    Decimal.mult(
      Decimal.sub(symbol_return, bench_return),
      Decimal.new("100")
    )
  end

  defp calculate_return(bars, days) when length(bars) > days do
    recent = Enum.take(bars, -days - 1)
    start_price = List.first(recent).close
    end_price = List.last(recent).close

    Decimal.div(Decimal.sub(end_price, start_price), start_price)
  end

  defp calculate_return(_, _), do: Decimal.new("0")

  defp classify_status(rs_5d) do
    rs_float = Decimal.to_float(rs_5d)

    cond do
      rs_float > 3.0 -> :strong_outperform
      rs_float > 1.0 -> :outperform
      rs_float > -1.0 -> :inline
      rs_float > -3.0 -> :underperform
      true -> :strong_underperform
    end
  end
end
