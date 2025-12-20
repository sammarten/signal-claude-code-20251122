defmodule Signal.Preview.DivergenceAnalyzer do
  @moduledoc """
  Analyzes divergence between major indices (SPY, QQQ, DIA).

  Compares performance and position relative to ATH to identify:
  - Which index is leading/lagging
  - Implications for trading strategies

  ## Usage

      {:ok, divergence} = DivergenceAnalyzer.analyze(~D[2024-12-14])
      # => %IndexDivergence{
      #   leader: "DIA",
      #   laggard: "QQQ",
      #   implication: "Tech lagging - harder to trade NQ names"
      # }
  """

  import Ecto.Query
  alias Signal.Repo
  alias Signal.MarketData.Bar
  alias Signal.Technicals.Levels
  alias Signal.Preview.IndexDivergence

  @indices [:SPY, :QQQ, :DIA]

  @doc """
  Analyzes index divergence for the given date.

  ## Parameters

    * `date` - Date to analyze

  ## Returns

    * `{:ok, %IndexDivergence{}}` - Divergence analysis
    * `{:error, atom()}` - Error during analysis
  """
  @spec analyze(Date.t()) :: {:ok, IndexDivergence.t()} | {:error, atom()}
  def analyze(date) do
    with {:ok, data} <- fetch_index_data(date) do
      divergence = calculate_divergence(data, date)
      {:ok, divergence}
    end
  end

  @doc """
  Analyzes index divergence and returns historical data for charting.

  ## Parameters

    * `date` - Date to analyze

  ## Returns

    * `{:ok, {%IndexDivergence{}, history}}` - Divergence analysis with historical series
    * `{:error, atom()}` - Error during analysis

  Where `history` is a map with cumulative return series for each index:
      %{
        spy: [%{time: unix_timestamp, value: cumulative_return_pct}, ...],
        qqq: [...],
        dia: [...]
      }
  """
  @spec analyze_with_history(Date.t()) ::
          {:ok, {IndexDivergence.t(), map()}} | {:error, atom()}
  def analyze_with_history(date) do
    with {:ok, data} <- fetch_index_data(date) do
      divergence = calculate_divergence(data, date)
      history = build_cumulative_return_history(data)
      {:ok, {divergence, history}}
    end
  end

  # Private Functions

  defp fetch_index_data(date) do
    start_date = Date.add(date, -25)

    results =
      @indices
      |> Enum.map(fn symbol ->
        {symbol, fetch_bars_for_symbol(symbol, start_date, date)}
      end)
      |> Enum.into(%{})

    if Enum.all?(results, fn {_, bars} -> length(bars) >= 5 end) do
      {:ok, results}
    else
      {:error, :insufficient_data}
    end
  end

  defp fetch_bars_for_symbol(symbol, start_date, end_date) do
    query =
      from b in Bar,
        where: b.symbol == ^to_string(symbol),
        where:
          fragment(
            "?::date >= ? AND ?::date <= ?",
            b.bar_time,
            ^start_date,
            b.bar_time,
            ^end_date
          ),
        order_by: [asc: b.bar_time]

    bars = Repo.all(query)
    aggregate_to_daily(bars)
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
        close: List.last(sorted).close,
        high: Enum.max_by(sorted, & &1.high).high
      }
    end)
    |> Enum.sort_by(& &1.date)
  end

  defp calculate_divergence(data, date) do
    spy_bars = data[:SPY]
    qqq_bars = data[:QQQ]
    dia_bars = data[:DIA]

    # Calculate 1-day and 5-day performance
    spy_1d = calculate_return(spy_bars, 1)
    spy_5d = calculate_return(spy_bars, 5)
    qqq_1d = calculate_return(qqq_bars, 1)
    qqq_5d = calculate_return(qqq_bars, 5)
    dia_1d = calculate_return(dia_bars, 1)
    dia_5d = calculate_return(dia_bars, 5)

    # Calculate distance from ATH
    spy_from_ath = calculate_ath_distance(:SPY, spy_bars)
    qqq_from_ath = calculate_ath_distance(:QQQ, qqq_bars)
    dia_from_ath = calculate_ath_distance(:DIA, dia_bars)

    # Determine leader and laggard based on 5-day performance
    performances = [
      {"SPY", spy_5d},
      {"QQQ", qqq_5d},
      {"DIA", dia_5d}
    ]

    sorted = Enum.sort_by(performances, fn {_, pct} -> Decimal.to_float(pct) end, :desc)
    {leader, _} = List.first(sorted)
    {laggard, _} = List.last(sorted)

    # Determine status for each index
    spy_status = determine_status(spy_5d, performances)
    qqq_status = determine_status(qqq_5d, performances)
    dia_status = determine_status(dia_5d, performances)

    # Generate implication
    implication = generate_implication(qqq_status, spy_from_ath, qqq_from_ath)

    %IndexDivergence{
      date: date,
      spy_status: spy_status,
      qqq_status: qqq_status,
      dia_status: dia_status,
      spy_1d_pct: spy_1d,
      qqq_1d_pct: qqq_1d,
      dia_1d_pct: dia_1d,
      spy_5d_pct: spy_5d,
      qqq_5d_pct: qqq_5d,
      dia_5d_pct: dia_5d,
      spy_from_ath_pct: spy_from_ath,
      qqq_from_ath_pct: qqq_from_ath,
      dia_from_ath_pct: dia_from_ath,
      leader: leader,
      laggard: laggard,
      implication: implication
    }
  end

  defp calculate_return(bars, days) when length(bars) > days do
    recent = Enum.take(bars, -days - 1)
    start_price = List.first(recent).close
    end_price = List.last(recent).close

    Decimal.mult(
      Decimal.div(Decimal.sub(end_price, start_price), start_price),
      Decimal.new("100")
    )
  end

  defp calculate_return(_, _), do: Decimal.new("0")

  defp calculate_ath_distance(symbol, bars) do
    current_price = List.last(bars).close

    case Levels.calculate_all_time_high(symbol) do
      {:ok, ath} ->
        Decimal.mult(
          Decimal.div(Decimal.sub(ath, current_price), ath),
          Decimal.new("100")
        )

      _ ->
        Decimal.new("0")
    end
  end

  defp determine_status(pct, performances) do
    sorted = Enum.sort_by(performances, fn {_, p} -> Decimal.to_float(p) end, :desc)

    case Enum.find_index(sorted, fn {_, p} -> Decimal.equal?(p, pct) end) do
      0 -> :leading
      2 -> :lagging
      _ -> :neutral
    end
  end

  defp generate_implication(qqq_status, spy_from_ath, qqq_from_ath) do
    spy_from_ath_float = Decimal.to_float(spy_from_ath)
    qqq_from_ath_float = Decimal.to_float(qqq_from_ath)

    cond do
      qqq_status == :lagging and qqq_from_ath_float > spy_from_ath_float + 2.0 ->
        "Tech lagging - harder to trade NQ names, look at SPY components"

      spy_from_ath_float < 1.0 and qqq_from_ath_float < 1.0 ->
        "Both indices near ATH - watch for breakout or rejection"

      spy_from_ath_float > 5.0 and qqq_from_ath_float > 5.0 ->
        "Both indices extended from ATH - potential mean reversion"

      true ->
        "Indices relatively aligned"
    end
  end

  defp build_cumulative_return_history(data) do
    %{
      spy: build_return_series(data[:SPY]),
      qqq: build_return_series(data[:QQQ]),
      dia: build_return_series(data[:DIA])
    }
  end

  defp build_return_series(bars) when length(bars) > 0 do
    base_price = List.first(bars).close

    Enum.map(bars, fn bar ->
      # Calculate cumulative return from start of period
      return_pct =
        Decimal.mult(
          Decimal.div(Decimal.sub(bar.close, base_price), base_price),
          Decimal.new("100")
        )

      # Convert date to Unix timestamp for Lightweight Charts
      datetime = DateTime.new!(bar.date, ~T[16:00:00], "Etc/UTC")
      unix_time = DateTime.to_unix(datetime)

      %{
        time: unix_time,
        value: Decimal.to_float(return_pct)
      }
    end)
  end

  defp build_return_series(_), do: []
end
