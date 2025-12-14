defmodule Signal.Preview.RegimeDetector do
  @moduledoc """
  Detects market regime for daily preview analysis.

  Classifies the market into one of four regimes:
  - **trending_up**: Higher highs and higher lows pattern
  - **trending_down**: Lower highs and lower lows pattern
  - **ranging**: Price oscillating within a defined range with multiple touches
  - **breakout_pending**: At range extremes, potential breakout imminent

  ## Usage

      {:ok, regime} = RegimeDetector.detect(:SPY, ~D[2024-12-14])
      # => %MarketRegime{
      #   regime: :ranging,
      #   range_high: #Decimal<690.00>,
      #   range_low: #Decimal<685.00>,
      #   range_duration_days: 10,
      #   ...
      # }
  """

  import Ecto.Query
  alias Signal.Repo
  alias Signal.MarketData.Bar
  alias Signal.Technicals.{Swings, Levels}
  alias Signal.Preview.MarketRegime

  @default_lookback_days 20
  @range_touch_threshold 0.005
  @atr_range_multiple 3.0

  @doc """
  Detects the current market regime for a symbol.

  ## Parameters

    * `symbol` - Symbol atom (e.g., :SPY)
    * `date` - Date to analyze (typically today)
    * `opts` - Options:
      * `:lookback_days` - Number of days to analyze (default: 20)

  ## Returns

    * `{:ok, %MarketRegime{}}` - Detected regime
    * `{:error, atom()}` - Error during detection
  """
  @spec detect(atom(), Date.t(), keyword()) ::
          {:ok, MarketRegime.t()} | {:error, atom()}
  def detect(symbol, date, opts \\ []) do
    lookback_days = Keyword.get(opts, :lookback_days, @default_lookback_days)

    with {:ok, daily_bars} <- get_daily_bars(symbol, date, lookback_days),
         {:ok, ath} <- Levels.calculate_all_time_high(symbol) do
      regime = analyze_regime(daily_bars, symbol, date, ath)
      {:ok, regime}
    end
  end

  @doc """
  Aggregates minute bars into daily OHLC bars.
  """
  @spec aggregate_to_daily(list(Bar.t())) :: list(map())
  def aggregate_to_daily(bars) do
    bars
    |> Enum.group_by(fn bar ->
      DateTime.to_date(bar.bar_time)
    end)
    |> Enum.map(fn {date, day_bars} ->
      sorted = Enum.sort_by(day_bars, & &1.bar_time)

      %{
        date: date,
        open: List.first(sorted).open,
        high: Enum.max_by(sorted, & &1.high).high,
        low: Enum.min_by(sorted, & &1.low).low,
        close: List.last(sorted).close,
        volume: Enum.reduce(sorted, 0, &(&1.volume + &2))
      }
    end)
    |> Enum.sort_by(& &1.date)
  end

  # Private Functions

  defp get_daily_bars(symbol, date, lookback_days) do
    start_date = Date.add(date, -lookback_days - 5)

    query =
      from b in Bar,
        where: b.symbol == ^to_string(symbol),
        where:
          fragment("?::date >= ? AND ?::date <= ?", b.bar_time, ^start_date, b.bar_time, ^date),
        order_by: [asc: b.bar_time]

    bars = Repo.all(query)

    if length(bars) < 100 do
      {:error, :insufficient_data}
    else
      daily_bars = aggregate_to_daily(bars)
      {:ok, daily_bars}
    end
  end

  defp analyze_regime(daily_bars, symbol, date, ath) do
    recent_bars = Enum.take(daily_bars, -10)
    current_price = List.last(daily_bars).close

    # Calculate range metrics
    range_high = Enum.max_by(recent_bars, & &1.high).high
    range_low = Enum.min_by(recent_bars, & &1.low).low
    range_size = Decimal.sub(range_high, range_low)

    # Calculate ATR for context
    atr = calculate_atr(daily_bars, 14)

    # Count touches of range extremes
    touches_high = count_touches(recent_bars, range_high, :high)
    touches_low = count_touches(recent_bars, range_low, :low)

    # Detect swings for trend analysis
    bar_structs = convert_to_bar_structs(daily_bars)
    swings = Swings.identify_swings(bar_structs, lookback: 2)
    swing_highs = Enum.filter(swings, &(&1.type == :high))
    swing_lows = Enum.filter(swings, &(&1.type == :low))

    # Count higher lows and lower highs
    higher_lows_count = count_higher_lows(swing_lows)
    lower_highs_count = count_lower_highs(swing_highs)

    # Determine if ranging
    is_ranging =
      touches_high >= 2 and
        touches_low >= 2 and
        Decimal.compare(range_size, Decimal.mult(atr, Decimal.new("#{@atr_range_multiple}"))) ==
          :lt

    # Determine trend
    has_higher_highs = consecutive_higher?(swing_highs)
    has_higher_lows = consecutive_higher?(swing_lows)
    has_lower_highs = consecutive_lower?(swing_highs)
    has_lower_lows = consecutive_lower?(swing_lows)

    # Distance from ATH
    distance_from_ath =
      Decimal.mult(
        Decimal.div(Decimal.sub(ath, current_price), ath),
        Decimal.new("100")
      )

    # At range extreme?
    near_range_high = near_level?(current_price, range_high)
    near_range_low = near_level?(current_price, range_low)

    # Classify regime
    {regime, trend_direction} =
      cond do
        is_ranging and (near_range_high or near_range_low) ->
          {:breakout_pending, :neutral}

        is_ranging ->
          {:ranging, :neutral}

        has_higher_highs and has_higher_lows ->
          {:trending_up, :up}

        has_lower_highs and has_lower_lows ->
          {:trending_down, :down}

        true ->
          {:ranging, :neutral}
      end

    # Calculate range duration (days in current range)
    range_duration = calculate_range_duration(daily_bars, range_high, range_low)

    %MarketRegime{
      symbol: to_string(symbol),
      date: date,
      timeframe: "daily",
      regime: regime,
      range_high: range_high,
      range_low: range_low,
      range_duration_days: range_duration,
      distance_from_ath_percent: distance_from_ath,
      trend_direction: trend_direction,
      higher_lows_count: higher_lows_count,
      lower_highs_count: lower_highs_count
    }
  end

  defp calculate_atr(bars, period) when length(bars) >= period + 1 do
    recent = Enum.take(bars, -(period + 1))

    trs =
      recent
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [prev, curr] ->
        tr1 = Decimal.sub(curr.high, curr.low)
        tr2 = Decimal.abs(Decimal.sub(curr.high, prev.close))
        tr3 = Decimal.abs(Decimal.sub(curr.low, prev.close))
        Enum.max([tr1, tr2, tr3], &(Decimal.compare(&1, &2) != :lt))
      end)

    sum = Enum.reduce(trs, Decimal.new("0"), &Decimal.add/2)
    Decimal.div(sum, Decimal.new("#{period}"))
  end

  defp calculate_atr(_, _), do: Decimal.new("1")

  defp count_touches(bars, level, field) do
    threshold = Decimal.mult(level, Decimal.new("#{@range_touch_threshold}"))

    Enum.count(bars, fn bar ->
      value = Map.get(bar, field)
      diff = Decimal.abs(Decimal.sub(value, level))
      Decimal.compare(diff, threshold) != :gt
    end)
  end

  defp count_higher_lows(swing_lows) when length(swing_lows) >= 2 do
    swing_lows
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.count(fn [prev, curr] ->
      Decimal.compare(curr.price, prev.price) == :gt
    end)
  end

  defp count_higher_lows(_), do: 0

  defp count_lower_highs(swing_highs) when length(swing_highs) >= 2 do
    swing_highs
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.count(fn [prev, curr] ->
      Decimal.compare(curr.price, prev.price) == :lt
    end)
  end

  defp count_lower_highs(_), do: 0

  defp consecutive_higher?(swings) when length(swings) >= 2 do
    swings
    |> Enum.take(-3)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [prev, curr] ->
      Decimal.compare(curr.price, prev.price) == :gt
    end)
  end

  defp consecutive_higher?(_), do: false

  defp consecutive_lower?(swings) when length(swings) >= 2 do
    swings
    |> Enum.take(-3)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [prev, curr] ->
      Decimal.compare(curr.price, prev.price) == :lt
    end)
  end

  defp consecutive_lower?(_), do: false

  defp near_level?(price, level) do
    threshold = Decimal.mult(level, Decimal.new("0.01"))
    diff = Decimal.abs(Decimal.sub(price, level))
    Decimal.compare(diff, threshold) != :gt
  end

  defp calculate_range_duration(bars, range_high, range_low) do
    tolerance = Decimal.mult(Decimal.sub(range_high, range_low), Decimal.new("0.1"))
    expanded_high = Decimal.add(range_high, tolerance)
    expanded_low = Decimal.sub(range_low, tolerance)

    bars
    |> Enum.reverse()
    |> Enum.take_while(fn bar ->
      Decimal.compare(bar.high, expanded_high) != :gt and
        Decimal.compare(bar.low, expanded_low) != :lt
    end)
    |> length()
  end

  defp convert_to_bar_structs(daily_bars) do
    Enum.map(daily_bars, fn bar ->
      %Bar{
        symbol: "TEMP",
        bar_time: DateTime.new!(bar.date, ~T[16:00:00], "America/New_York"),
        open: bar.open,
        high: bar.high,
        low: bar.low,
        close: bar.close,
        volume: bar.volume
      }
    end)
  end
end
