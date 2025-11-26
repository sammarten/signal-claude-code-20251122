defmodule Signal.Strategies.OneCandleRule do
  @moduledoc """
  Implements the One Candle Rule trading strategy.

  The One Candle Rule identifies the last opposing candle before a trend continuation
  move and uses it as a key support/resistance level.

  ## Strategy Rules

  **In an Uptrend:**
  - Find the last red (bearish) candle before price continues higher
  - This candle's range becomes a support zone
  - Wait for price to break above, then retest

  **In a Downtrend:**
  - Find the last green (bullish) candle before price continues lower
  - This candle's range becomes a resistance zone
  - Wait for price to break below, then retest

  ## Entry Model

  1. Identify trend direction from market structure
  2. Find the last opposing candle before continuation
  3. Wait for price to break the candle's high/low
  4. Look for retest of the broken level
  5. Enter on confirmation with stop beyond the candle

  ## Usage

      # Evaluate for one candle rule setups
      {:ok, setups} = OneCandleRule.evaluate("AAPL", bars, structure)

      # Find the one candle in an uptrend
      {:ok, candle} = OneCandleRule.find_one_candle(bars, :bullish)
  """

  alias Signal.MarketData.Bar
  alias Signal.Strategies.Setup
  alias Signal.Strategies.BreakAndRetest
  alias Signal.Technicals.StructureDetector

  @type one_candle :: %{
          bar: Bar.t(),
          index: integer(),
          high: Decimal.t(),
          low: Decimal.t(),
          candle_type: :bullish | :bearish
        }

  @doc """
  Evaluates a symbol for one candle rule setups.

  ## Parameters

    * `symbol` - The trading symbol
    * `bars` - List of recent bars (oldest first)
    * `opts` - Options
      * `:min_rr` - Minimum risk/reward ratio (default: 2.0)
      * `:lookback` - Bars to analyze (default: 50)
      * `:retest_window` - Bars to look for retest (default: 15)

  ## Returns

    * `{:ok, [%Setup{}, ...]}` - List of valid setups
    * `{:error, :no_trend}` - No clear trend detected
    * `{:error, reason}` - Other errors

  ## Examples

      iex> OneCandleRule.evaluate("AAPL", bars)
      {:ok, [%Setup{strategy: :one_candle_rule, ...}]}
  """
  @spec evaluate(String.t(), list(Bar.t()), keyword()) ::
          {:ok, list(Setup.t())} | {:error, atom()}
  def evaluate(symbol, bars, opts \\ []) do
    min_rr = Keyword.get(opts, :min_rr, Decimal.new("2.0"))
    lookback = Keyword.get(opts, :lookback, 50)
    retest_window = Keyword.get(opts, :retest_window, 15)

    recent_bars = Enum.take(bars, -lookback)

    if length(recent_bars) < 10 do
      {:ok, []}
    else
      # Analyze market structure to determine trend
      structure = StructureDetector.analyze(recent_bars)

      case structure.trend do
        :bullish ->
          find_bullish_setups(symbol, recent_bars, retest_window, min_rr)

        :bearish ->
          find_bearish_setups(symbol, recent_bars, retest_window, min_rr)

        :ranging ->
          {:error, :no_trend}
      end
    end
  end

  @doc """
  Finds the "one candle" - the last opposing candle before continuation.

  ## Parameters

    * `bars` - List of bars to analyze
    * `trend` - Current trend direction (:bullish or :bearish)
    * `opts` - Options
      * `:min_continuation_bars` - Minimum bars of continuation after (default: 2)

  ## Returns

    * `{:ok, one_candle}` - The one candle found
    * `{:error, :not_found}` - No qualifying candle found

  ## Examples

      iex> OneCandleRule.find_one_candle(bars, :bullish)
      {:ok, %{bar: %Bar{}, index: 15, candle_type: :bearish, ...}}
  """
  @spec find_one_candle(list(Bar.t()), :bullish | :bearish, keyword()) ::
          {:ok, one_candle()} | {:error, :not_found}
  def find_one_candle(bars, trend, opts \\ []) do
    min_continuation = Keyword.get(opts, :min_continuation_bars, 2)

    opposing_type = if trend == :bullish, do: :bearish, else: :bullish

    # Search from most recent backwards, looking for opposing candles
    # followed by continuation candles
    bars
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.drop(min_continuation)
    |> Enum.find_value({:error, :not_found}, fn {bar, idx} ->
      if candle_type(bar) == opposing_type do
        # Check if followed by continuation
        continuation_bars = Enum.slice(bars, (idx + 1)..-1//1)

        if has_continuation?(continuation_bars, trend, min_continuation) do
          {:ok,
           %{
             bar: bar,
             index: idx,
             high: bar.high,
             low: bar.low,
             candle_type: opposing_type
           }}
        else
          nil
        end
      else
        nil
      end
    end)
  end

  @doc """
  Checks if price has broken above/below the one candle.

  ## Parameters

    * `bars` - Bars after the one candle
    * `one_candle` - The one candle reference
    * `trend` - Trend direction

  ## Returns

    * `{:ok, break_info}` - Break detected
    * `{:error, :no_break}` - No break found
  """
  @spec check_one_candle_break(list(Bar.t()), one_candle(), :bullish | :bearish) ::
          {:ok, map()} | {:error, :no_break}
  def check_one_candle_break(bars, one_candle, trend) do
    level_price =
      case trend do
        :bullish -> one_candle.high
        :bearish -> one_candle.low
      end

    direction = if trend == :bullish, do: :long, else: :short

    bars
    |> Enum.with_index()
    |> Enum.find_value({:error, :no_break}, fn {bar, idx} ->
      broken =
        case trend do
          :bullish -> Decimal.compare(bar.close, level_price) == :gt
          :bearish -> Decimal.compare(bar.close, level_price) == :lt
        end

      if broken do
        {:ok,
         %{
           type: :swing_high,
           price: level_price,
           direction: direction,
           break_bar: bar,
           break_index: idx
         }}
      else
        nil
      end
    end)
  end

  @doc """
  Determines the candle type (bullish/bearish/neutral).

  ## Parameters

    * `bar` - The bar to analyze

  ## Returns

  Atom indicating candle type.
  """
  @spec candle_type(Bar.t()) :: :bullish | :bearish | :neutral
  def candle_type(%Bar{open: open, close: close}) do
    case Decimal.compare(close, open) do
      :gt -> :bullish
      :lt -> :bearish
      :eq -> :neutral
    end
  end

  @doc """
  Calculates the body size of a candle as a percentage of total range.

  ## Parameters

    * `bar` - The bar to analyze

  ## Returns

  Body percentage as Decimal (0.0 to 1.0).
  """
  @spec body_percentage(Bar.t()) :: Decimal.t()
  def body_percentage(%Bar{open: open, close: close, high: high, low: low}) do
    body = Decimal.abs(Decimal.sub(close, open))
    range = Decimal.sub(high, low)

    if Decimal.compare(range, Decimal.new(0)) == :gt do
      Decimal.div(body, range)
    else
      Decimal.new(0)
    end
  end

  @doc """
  Checks if a candle has a strong body (good for one candle rule).

  A strong body is typically >= 50% of the total range.

  ## Parameters

    * `bar` - The bar to check
    * `min_body_pct` - Minimum body percentage (default: 0.5)

  ## Returns

  Boolean indicating if body is strong.
  """
  @spec strong_body?(Bar.t(), Decimal.t()) :: boolean()
  def strong_body?(%Bar{} = bar, min_body_pct \\ Decimal.new("0.5")) do
    pct = body_percentage(bar)
    Decimal.compare(pct, min_body_pct) != :lt
  end

  # Private Functions

  defp find_bullish_setups(symbol, bars, retest_window, min_rr) do
    case find_one_candle(bars, :bullish) do
      {:ok, one_candle} ->
        # Get bars after the one candle
        bars_after = Enum.drop(bars, one_candle.index + 1)

        case check_one_candle_break(bars_after, one_candle, :bullish) do
          {:ok, broken_level} ->
            # Get bars after the break for retest
            bars_after_break = Enum.drop(bars_after, broken_level.break_index + 1)
            retest_bars = Enum.take(bars_after_break, retest_window)

            case BreakAndRetest.find_retest(retest_bars, broken_level) do
              {:ok, retest_bar} ->
                setup = build_setup(symbol, one_candle, broken_level, retest_bar, min_rr)
                {:ok, setup}

              {:error, :no_retest} ->
                {:ok, []}
            end

          {:error, :no_break} ->
            {:ok, []}
        end

      {:error, :not_found} ->
        {:ok, []}
    end
  end

  defp find_bearish_setups(symbol, bars, retest_window, min_rr) do
    case find_one_candle(bars, :bearish) do
      {:ok, one_candle} ->
        bars_after = Enum.drop(bars, one_candle.index + 1)

        case check_one_candle_break(bars_after, one_candle, :bearish) do
          {:ok, broken_level} ->
            bars_after_break = Enum.drop(bars_after, broken_level.break_index + 1)
            retest_bars = Enum.take(bars_after_break, retest_window)

            case BreakAndRetest.find_retest(retest_bars, broken_level) do
              {:ok, retest_bar} ->
                setup = build_setup(symbol, one_candle, broken_level, retest_bar, min_rr)
                {:ok, setup}

              {:error, :no_retest} ->
                {:ok, []}
            end

          {:error, :no_break} ->
            {:ok, []}
        end

      {:error, :not_found} ->
        {:ok, []}
    end
  end

  defp build_setup(symbol, one_candle, broken_level, retest_bar, min_rr) do
    entry = BreakAndRetest.calculate_entry(retest_bar, broken_level.direction)
    stop = calculate_stop_from_one_candle(one_candle, broken_level.direction)
    target = BreakAndRetest.calculate_target(entry, stop, broken_level.direction)

    setup =
      Setup.new(%{
        symbol: symbol,
        strategy: :one_candle_rule,
        direction: broken_level.direction,
        level_type: level_type_from_direction(broken_level.direction),
        level_price: broken_level.price,
        entry_price: entry,
        stop_loss: stop,
        take_profit: target,
        retest_bar: retest_bar,
        break_bar: broken_level.break_bar,
        confluence: %{
          one_candle: one_candle.bar,
          strong_body: strong_body?(one_candle.bar),
          strong_rejection: BreakAndRetest.strong_rejection?(retest_bar, broken_level.direction)
        },
        quality_score: calculate_quality(one_candle, retest_bar, broken_level.direction)
      })

    if Setup.meets_risk_reward?(setup, min_rr) do
      [setup]
    else
      []
    end
  end

  defp calculate_stop_from_one_candle(one_candle, direction) do
    buffer = Decimal.new("0.10")

    case direction do
      :long -> Decimal.sub(one_candle.low, buffer)
      :short -> Decimal.add(one_candle.high, buffer)
    end
  end

  defp level_type_from_direction(:long), do: :swing_high
  defp level_type_from_direction(:short), do: :swing_low

  defp has_continuation?(bars, trend, min_bars) when length(bars) >= min_bars do
    continuation_bars = Enum.take(bars, min_bars)

    case trend do
      :bullish ->
        # All bars should be bullish or neutral
        Enum.all?(continuation_bars, fn bar ->
          candle_type(bar) in [:bullish, :neutral]
        end)

      :bearish ->
        # All bars should be bearish or neutral
        Enum.all?(continuation_bars, fn bar ->
          candle_type(bar) in [:bearish, :neutral]
        end)
    end
  end

  defp has_continuation?(_bars, _trend, _min_bars), do: false

  defp calculate_quality(one_candle, retest_bar, direction) do
    score = 5

    # +2 for strong body on one candle
    score =
      if strong_body?(one_candle.bar) do
        score + 2
      else
        score
      end

    # +1 for strong rejection on retest
    score =
      if BreakAndRetest.strong_rejection?(retest_bar, direction) do
        score + 1
      else
        score
      end

    # +1 for larger body percentage (cleaner one candle)
    score =
      if Decimal.compare(body_percentage(one_candle.bar), Decimal.new("0.7")) != :lt do
        score + 1
      else
        score
      end

    min(score, 10)
  end
end
