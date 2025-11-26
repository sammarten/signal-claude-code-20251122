defmodule Signal.Strategies.OpeningRange do
  @moduledoc """
  Detects Opening Range Breakout (ORB) patterns.

  The Opening Range strategy focuses on breaks of the first 5-minute or 15-minute
  range after market open (9:30 AM ET), followed by a retest of the broken range.

  ## Strategy Rules

  1. Mark the 5-minute high/low (9:30-9:35 AM ET)
  2. Mark the 15-minute high/low (9:30-9:45 AM ET)
  3. Wait for price to break outside the range
  4. Look for retest of the broken range boundary
  5. Enter on confirmation candle
  6. Target minimum 2:1 risk/reward

  ## Opening Ranges

  * **5-minute range (OR5)**: First 5 minutes of regular session
  * **15-minute range (OR15)**: First 15 minutes of regular session

  ## Usage

      # Evaluate for opening range breakout setups
      {:ok, setups} = OpeningRange.evaluate("AAPL", bars, levels)

      # Check if opening ranges are established
      {:ok, :established} = OpeningRange.check_ranges_ready(levels)

      # Detect range break
      {:ok, break} = OpeningRange.detect_range_break(bars, levels)
  """

  alias Signal.MarketData.Bar
  alias Signal.Technicals.KeyLevels
  alias Signal.Strategies.Setup
  alias Signal.Strategies.BreakAndRetest

  @type range_type :: :or5m | :or15m

  @type range_break :: %{
          range: range_type(),
          direction: :long | :short,
          level_price: Decimal.t(),
          break_bar: Bar.t(),
          break_index: integer()
        }

  @doc """
  Evaluates a symbol for opening range breakout setups.

  ## Parameters

    * `symbol` - The trading symbol
    * `bars` - List of recent bars (oldest first)
    * `levels` - KeyLevels struct with opening range data
    * `opts` - Options
      * `:min_rr` - Minimum risk/reward ratio (default: 2.0)
      * `:prefer_range` - Preferred range to trade (:or5m, :or15m, or :both)
      * `:retest_window` - Bars to look for retest (default: 15)

  ## Returns

    * `{:ok, [%Setup{}, ...]}` - List of valid setups
    * `{:error, :ranges_not_ready}` - Opening ranges not yet established
    * `{:error, reason}` - Other errors

  ## Examples

      iex> OpeningRange.evaluate("AAPL", bars, levels)
      {:ok, [%Setup{strategy: :opening_range_breakout, ...}]}
  """
  @spec evaluate(String.t(), list(Bar.t()), KeyLevels.t(), keyword()) ::
          {:ok, list(Setup.t())} | {:error, atom()}
  def evaluate(symbol, bars, %KeyLevels{} = levels, opts \\ []) do
    min_rr = Keyword.get(opts, :min_rr, Decimal.new("2.0"))
    prefer_range = Keyword.get(opts, :prefer_range, :both)
    retest_window = Keyword.get(opts, :retest_window, 15)

    # Filter out invalid bars before processing
    valid_bars = Enum.filter(bars, &BreakAndRetest.valid_bar?/1)

    case check_ranges_ready(levels, prefer_range) do
      {:ok, :established} ->
        setups =
          get_ranges_to_check(levels, prefer_range)
          |> Enum.flat_map(fn {range_type, high, low} ->
            find_orb_setups(symbol, valid_bars, range_type, high, low, retest_window, min_rr)
          end)
          |> Enum.filter(&Setup.valid?/1)

        {:ok, setups}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Checks if opening ranges are established and ready for trading.

  ## Parameters

    * `levels` - KeyLevels struct
    * `range_type` - Which range to check (:or5m, :or15m, or :both)

  ## Returns

    * `{:ok, :established}` - Ranges are ready
    * `{:error, :ranges_not_ready}` - Ranges not yet calculated

  ## Examples

      iex> OpeningRange.check_ranges_ready(levels)
      {:ok, :established}

      iex> OpeningRange.check_ranges_ready(levels_without_or)
      {:error, :ranges_not_ready}
  """
  @spec check_ranges_ready(KeyLevels.t(), :or5m | :or15m | :both) ::
          {:ok, :established} | {:error, :ranges_not_ready}
  def check_ranges_ready(%KeyLevels{} = levels, range_type \\ :both) do
    case range_type do
      :or5m ->
        if levels.opening_range_5m_high && levels.opening_range_5m_low do
          {:ok, :established}
        else
          {:error, :ranges_not_ready}
        end

      :or15m ->
        if levels.opening_range_15m_high && levels.opening_range_15m_low do
          {:ok, :established}
        else
          {:error, :ranges_not_ready}
        end

      :both ->
        or5_ready = !is_nil(levels.opening_range_5m_high) && !is_nil(levels.opening_range_5m_low)

        or15_ready =
          !is_nil(levels.opening_range_15m_high) && !is_nil(levels.opening_range_15m_low)

        if or5_ready or or15_ready do
          {:ok, :established}
        else
          {:error, :ranges_not_ready}
        end
    end
  end

  @doc """
  Detects a break of an opening range.

  ## Parameters

    * `bars` - List of bars to analyze
    * `range_high` - High of the opening range
    * `range_low` - Low of the opening range
    * `range_type` - Type of range (:or5m or :or15m)

  ## Returns

    * `{:ok, range_break}` - Break detected
    * `{:error, :no_break}` - No break found
    * `{:error, :still_in_range}` - Price still within range

  ## Examples

      iex> OpeningRange.detect_range_break(bars, or_high, or_low, :or5m)
      {:ok, %{range: :or5m, direction: :long, ...}}
  """
  @spec detect_range_break(list(Bar.t()), Decimal.t(), Decimal.t(), range_type()) ::
          {:ok, range_break()} | {:error, atom()}
  def detect_range_break(bars, range_high, range_low, range_type) when length(bars) >= 2 do
    bars
    |> Enum.with_index()
    |> Enum.find_value({:error, :no_break}, fn {bar, idx} ->
      cond do
        # Bullish breakout: close above range high
        Decimal.compare(bar.close, range_high) == :gt ->
          {:ok,
           %{
             range: range_type,
             direction: :long,
             level_price: range_high,
             break_bar: bar,
             break_index: idx
           }}

        # Bearish breakdown: close below range low
        Decimal.compare(bar.close, range_low) == :lt ->
          {:ok,
           %{
             range: range_type,
             direction: :short,
             level_price: range_low,
             break_bar: bar,
             break_index: idx
           }}

        true ->
          nil
      end
    end)
  end

  def detect_range_break(_bars, _high, _low, _type), do: {:error, :no_break}

  @doc """
  Calculates the range size (high - low) of an opening range.

  ## Parameters

    * `high` - Range high price
    * `low` - Range low price

  ## Returns

  Range size as Decimal.
  """
  @spec range_size(Decimal.t(), Decimal.t()) :: Decimal.t()
  def range_size(high, low) do
    Decimal.sub(high, low)
  end

  @doc """
  Checks if the opening range is "tight" (small relative to price).

  A tight range often leads to explosive breakouts.

  ## Parameters

    * `high` - Range high
    * `low` - Range low
    * `threshold_pct` - Maximum percentage for tight range (default: 0.5%)

  ## Returns

  Boolean indicating if range is tight.
  """
  @spec tight_range?(Decimal.t(), Decimal.t(), Decimal.t()) :: boolean()
  def tight_range?(high, low, threshold_pct \\ Decimal.new("0.005")) do
    size = range_size(high, low)
    midpoint = Decimal.div(Decimal.add(high, low), 2)

    if Decimal.compare(midpoint, Decimal.new(0)) == :gt do
      pct = Decimal.div(size, midpoint)
      Decimal.compare(pct, threshold_pct) != :gt
    else
      false
    end
  end

  @doc """
  Gets the midpoint of an opening range.

  Useful for determining bias within the range.

  ## Parameters

    * `high` - Range high
    * `low` - Range low

  ## Returns

  Midpoint price as Decimal.
  """
  @spec range_midpoint(Decimal.t(), Decimal.t()) :: Decimal.t()
  def range_midpoint(high, low) do
    high
    |> Decimal.add(low)
    |> Decimal.div(2)
  end

  # Private Functions

  defp get_ranges_to_check(%KeyLevels{} = levels, prefer_range) do
    ranges = []

    ranges =
      if (prefer_range in [:or5m, :both] and
            levels.opening_range_5m_high) && levels.opening_range_5m_low do
        [{:or5m, levels.opening_range_5m_high, levels.opening_range_5m_low} | ranges]
      else
        ranges
      end

    ranges =
      if (prefer_range in [:or15m, :both] and
            levels.opening_range_15m_high) && levels.opening_range_15m_low do
        [{:or15m, levels.opening_range_15m_high, levels.opening_range_15m_low} | ranges]
      else
        ranges
      end

    ranges
  end

  defp find_orb_setups(symbol, bars, range_type, range_high, range_low, retest_window, min_rr) do
    case detect_range_break(bars, range_high, range_low, range_type) do
      {:ok, range_break} ->
        # Get bars after the break for retest detection
        bars_after_break = Enum.drop(bars, range_break.break_index + 1)
        retest_bars = Enum.take(bars_after_break, retest_window)

        # Convert range_break to broken_level format for retest detection
        broken_level = %{
          type: level_type_from_range(range_type, range_break.direction),
          price: range_break.level_price,
          direction: range_break.direction,
          break_bar: range_break.break_bar,
          break_index: range_break.break_index
        }

        case BreakAndRetest.find_retest(retest_bars, broken_level) do
          {:ok, retest_bar} ->
            build_orb_setup(symbol, range_break, retest_bar, range_high, range_low, min_rr)

          {:error, :no_retest} ->
            []
        end

      {:error, _} ->
        []
    end
  end

  defp build_orb_setup(symbol, range_break, retest_bar, range_high, range_low, min_rr) do
    entry = BreakAndRetest.calculate_entry(retest_bar, range_break.direction)
    stop = BreakAndRetest.calculate_stop(retest_bar, range_break.direction)
    target = BreakAndRetest.calculate_target(entry, stop, range_break.direction)

    setup =
      Setup.new(%{
        symbol: symbol,
        strategy: :opening_range_breakout,
        direction: range_break.direction,
        level_type: level_type_from_range(range_break.range, range_break.direction),
        level_price: range_break.level_price,
        entry_price: entry,
        stop_loss: stop,
        take_profit: target,
        retest_bar: retest_bar,
        break_bar: range_break.break_bar,
        confluence: %{
          range_type: range_break.range,
          tight_range: tight_range?(range_high, range_low),
          strong_rejection: BreakAndRetest.strong_rejection?(retest_bar, range_break.direction)
        },
        quality_score: calculate_orb_quality(range_break, retest_bar, range_high, range_low)
      })

    if Setup.meets_risk_reward?(setup, min_rr) do
      [setup]
    else
      []
    end
  end

  defp level_type_from_range(:or5m, :long), do: :or5h
  defp level_type_from_range(:or5m, :short), do: :or5l
  defp level_type_from_range(:or15m, :long), do: :or15h
  defp level_type_from_range(:or15m, :short), do: :or15l

  defp calculate_orb_quality(range_break, retest_bar, range_high, range_low) do
    score = 5

    # +2 for tight range (often leads to explosive moves)
    score =
      if tight_range?(range_high, range_low) do
        score + 2
      else
        score
      end

    # +1 for strong rejection candle
    score =
      if BreakAndRetest.strong_rejection?(retest_bar, range_break.direction) do
        score + 1
      else
        score
      end

    # +1 for 5-minute range (typically more significant)
    score =
      if range_break.range == :or5m do
        score + 1
      else
        score
      end

    min(score, 10)
  end
end
