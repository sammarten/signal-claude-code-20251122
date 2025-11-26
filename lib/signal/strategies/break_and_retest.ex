defmodule Signal.Strategies.BreakAndRetest do
  @moduledoc """
  Detects break and retest patterns on key levels.

  The Break and Retest strategy identifies setups where price breaks through a
  significant level, then returns to test that level before continuing in the
  break direction.

  ## Entry Model

  1. **Break Phase**: Price breaks above/below a key level with momentum
  2. **Retest Phase**: Price pulls back to test the broken level
  3. **Confirmation Phase**: Strong rejection candle at the retest
  4. **Entry**: Above/below the retest candle in the direction of the break

  ## Entry Criteria

  - Break of key level (PDH/PDL, PMH/PML, ORH/ORL)
  - Retest shows price touching the level and rejecting
  - Minimum 2:1 risk-reward available
  - Aligns with market structure (optional confluence)
  - Occurs within trading window (9:30-11:00 AM ET)

  ## Usage

      # Evaluate a symbol for break and retest setups
      {:ok, setups} = BreakAndRetest.evaluate("AAPL", bars, levels)

      # Check if a specific level was broken
      {:ok, break} = BreakAndRetest.check_level_break(bars, level, :pdh)

      # Find retest of a broken level
      {:ok, retest} = BreakAndRetest.find_retest(bars, broken_level)
  """

  alias Signal.MarketData.Bar
  alias Signal.Technicals.KeyLevels
  alias Signal.Strategies.Setup

  @type broken_level :: %{
          type: Setup.level_type(),
          price: Decimal.t(),
          direction: :long | :short,
          break_bar: Bar.t(),
          break_index: integer()
        }

  @doc """
  Evaluates a symbol for break and retest setups.

  ## Parameters

    * `symbol` - The trading symbol
    * `bars` - List of recent bars (oldest first)
    * `levels` - KeyLevels struct with current levels
    * `opts` - Options
      * `:min_rr` - Minimum risk/reward ratio (default: 2.0)
      * `:lookback` - Bars to look back for breaks (default: 30)
      * `:retest_window` - Bars to look for retest after break (default: 15)

  ## Returns

    * `{:ok, [%Setup{}, ...]}` - List of valid setups found
    * `{:error, reason}` - If evaluation fails

  ## Examples

      iex> BreakAndRetest.evaluate("AAPL", bars, levels)
      {:ok, [%Setup{strategy: :break_and_retest, direction: :long, ...}]}
  """
  @spec evaluate(String.t(), list(Bar.t()), KeyLevels.t(), keyword()) ::
          {:ok, list(Setup.t())} | {:error, atom()}
  def evaluate(symbol, bars, %KeyLevels{} = levels, opts \\ []) do
    min_rr = Keyword.get(opts, :min_rr, Decimal.new("2.0"))
    lookback = Keyword.get(opts, :lookback, 30)
    retest_window = Keyword.get(opts, :retest_window, 15)

    recent_bars = Enum.take(bars, -lookback)

    if length(recent_bars) < 5 do
      {:ok, []}
    else
      setups =
        levels
        |> get_all_levels()
        |> Enum.flat_map(fn {level_type, level_price} ->
          find_setups_for_level(
            symbol,
            recent_bars,
            level_type,
            level_price,
            retest_window,
            min_rr
          )
        end)
        |> Enum.filter(&Setup.valid?/1)

      {:ok, setups}
    end
  end

  @doc """
  Checks if a level was broken in the given bars.

  A break is detected when price crosses from one side of the level to the other.

  ## Parameters

    * `bars` - List of bars to analyze
    * `level_price` - The price level to check
    * `level_type` - Type of level (for labeling)

  ## Returns

    * `{:ok, broken_level}` - If break detected
    * `{:error, :no_break}` - If no break found

  ## Examples

      iex> BreakAndRetest.check_level_break(bars, Decimal.new("175.50"), :pdh)
      {:ok, %{type: :pdh, price: #Decimal<175.50>, direction: :long, ...}}
  """
  @spec check_level_break(list(Bar.t()), Decimal.t(), Setup.level_type()) ::
          {:ok, broken_level()} | {:error, :no_break}
  def check_level_break(bars, level_price, level_type) when length(bars) >= 2 do
    bars
    |> Enum.with_index()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value({:error, :no_break}, fn [{prev_bar, _prev_idx}, {curr_bar, curr_idx}] ->
      case detect_break(prev_bar, curr_bar, level_price) do
        {:break, direction} ->
          {:ok,
           %{
             type: level_type,
             price: level_price,
             direction: direction,
             break_bar: curr_bar,
             break_index: curr_idx
           }}

        :no_break ->
          nil
      end
    end)
  end

  def check_level_break(_bars, _level_price, _level_type), do: {:error, :no_break}

  @doc """
  Finds a retest of a broken level in subsequent bars.

  For a bullish break, looks for price to pull back and touch the level from above.
  For a bearish break, looks for price to pull back and touch the level from below.

  ## Parameters

    * `bars` - Bars after the break
    * `broken_level` - The broken level info
    * `opts` - Options
      * `:tolerance` - Price tolerance for retest (default: 0.05%)

  ## Returns

    * `{:ok, retest_bar}` - If retest found
    * `{:error, :no_retest}` - If no retest found

  ## Examples

      iex> BreakAndRetest.find_retest(bars, broken_level)
      {:ok, %Bar{...}}
  """
  @spec find_retest(list(Bar.t()), broken_level(), keyword()) ::
          {:ok, Bar.t()} | {:error, :no_retest}
  def find_retest(bars, broken_level, opts \\ []) do
    tolerance_pct = Keyword.get(opts, :tolerance, Decimal.new("0.0005"))
    tolerance = Decimal.mult(broken_level.price, tolerance_pct)
    level_with_tolerance_high = Decimal.add(broken_level.price, tolerance)
    level_with_tolerance_low = Decimal.sub(broken_level.price, tolerance)

    retest_bar =
      Enum.find(bars, fn bar ->
        case broken_level.direction do
          :long ->
            # For bullish break, retest should touch level from above and reject
            touches_level = Decimal.compare(bar.low, level_with_tolerance_high) != :gt
            closes_above = Decimal.compare(bar.close, broken_level.price) == :gt
            touches_level and closes_above

          :short ->
            # For bearish break, retest should touch level from below and reject
            touches_level = Decimal.compare(bar.high, level_with_tolerance_low) != :lt
            closes_below = Decimal.compare(bar.close, broken_level.price) == :lt
            touches_level and closes_below
        end
      end)

    case retest_bar do
      nil -> {:error, :no_retest}
      bar -> {:ok, bar}
    end
  end

  @doc """
  Calculates entry price for a setup.

  For long setups, entry is above the retest bar's high.
  For short setups, entry is below the retest bar's low.

  ## Parameters

    * `retest_bar` - The retest bar
    * `direction` - Trade direction (:long or :short)
    * `buffer` - Price buffer above/below (default: 0.02)

  ## Returns

  Entry price as Decimal.
  """
  @spec calculate_entry(Bar.t(), :long | :short, Decimal.t()) :: Decimal.t()
  def calculate_entry(%Bar{} = retest_bar, direction, buffer \\ Decimal.new("0.02")) do
    case direction do
      :long -> Decimal.add(retest_bar.high, buffer)
      :short -> Decimal.sub(retest_bar.low, buffer)
    end
  end

  @doc """
  Calculates stop loss for a setup.

  For long setups, stop is below the retest bar's low.
  For short setups, stop is above the retest bar's high.

  ## Parameters

    * `retest_bar` - The retest bar
    * `direction` - Trade direction (:long or :short)
    * `buffer` - Price buffer beyond the bar (default: 0.10)

  ## Returns

  Stop loss price as Decimal.
  """
  @spec calculate_stop(Bar.t(), :long | :short, Decimal.t()) :: Decimal.t()
  def calculate_stop(%Bar{} = retest_bar, direction, buffer \\ Decimal.new("0.10")) do
    case direction do
      :long -> Decimal.sub(retest_bar.low, buffer)
      :short -> Decimal.add(retest_bar.high, buffer)
    end
  end

  @doc """
  Calculates take profit target based on risk/reward ratio.

  ## Parameters

    * `entry` - Entry price
    * `stop` - Stop loss price
    * `direction` - Trade direction
    * `rr_ratio` - Risk/reward ratio (default: 2.0)

  ## Returns

  Take profit price as Decimal.
  """
  @spec calculate_target(Decimal.t(), Decimal.t(), :long | :short, Decimal.t()) :: Decimal.t()
  def calculate_target(entry, stop, direction, rr_ratio \\ Decimal.new("2.0")) do
    risk = Decimal.abs(Decimal.sub(entry, stop))
    reward = Decimal.mult(risk, rr_ratio)

    case direction do
      :long -> Decimal.add(entry, reward)
      :short -> Decimal.sub(entry, reward)
    end
  end

  @doc """
  Checks if a retest bar shows strong rejection (good price action).

  A strong rejection for a bullish setup has:
  - Long lower wick relative to body
  - Close in upper portion of bar

  A strong rejection for a bearish setup has:
  - Long upper wick relative to body
  - Close in lower portion of bar

  ## Parameters

    * `bar` - The retest bar to analyze
    * `direction` - Expected direction (:long or :short)

  ## Returns

  Boolean indicating if rejection is strong.
  """
  @spec strong_rejection?(Bar.t(), :long | :short) :: boolean()
  def strong_rejection?(%Bar{} = bar, direction) do
    total_range = Decimal.sub(bar.high, bar.low)

    # Avoid division by zero
    if Decimal.compare(total_range, Decimal.new(0)) == :eq do
      false
    else
      lower_wick =
        Decimal.sub(Enum.min_by([bar.open, bar.close], &Decimal.to_float/1), bar.low)

      upper_wick =
        Decimal.sub(bar.high, Enum.max_by([bar.open, bar.close], &Decimal.to_float/1))

      case direction do
        :long ->
          # For bullish rejection: lower wick should be significant
          wick_ratio = Decimal.div(lower_wick, total_range)
          Decimal.compare(wick_ratio, Decimal.new("0.3")) != :lt

        :short ->
          # For bearish rejection: upper wick should be significant
          wick_ratio = Decimal.div(upper_wick, total_range)
          Decimal.compare(wick_ratio, Decimal.new("0.3")) != :lt
      end
    end
  end

  # Private Functions

  defp get_all_levels(%KeyLevels{} = levels) do
    [
      {:pdh, levels.previous_day_high},
      {:pdl, levels.previous_day_low},
      {:pmh, levels.premarket_high},
      {:pml, levels.premarket_low},
      {:or5h, levels.opening_range_5m_high},
      {:or5l, levels.opening_range_5m_low},
      {:or15h, levels.opening_range_15m_high},
      {:or15l, levels.opening_range_15m_low}
    ]
    |> Enum.reject(fn {_type, price} -> is_nil(price) end)
  end

  defp find_setups_for_level(symbol, bars, level_type, level_price, retest_window, min_rr) do
    case check_level_break(bars, level_price, level_type) do
      {:ok, broken_level} ->
        # Get bars after the break for retest detection
        bars_after_break = Enum.drop(bars, broken_level.break_index + 1)
        retest_bars = Enum.take(bars_after_break, retest_window)

        case find_retest(retest_bars, broken_level) do
          {:ok, retest_bar} ->
            build_setup(symbol, broken_level, retest_bar, min_rr)

          {:error, :no_retest} ->
            []
        end

      {:error, :no_break} ->
        []
    end
  end

  defp build_setup(symbol, broken_level, retest_bar, min_rr) do
    entry = calculate_entry(retest_bar, broken_level.direction)
    stop = calculate_stop(retest_bar, broken_level.direction)
    target = calculate_target(entry, stop, broken_level.direction)

    setup =
      Setup.new(%{
        symbol: symbol,
        strategy: :break_and_retest,
        direction: broken_level.direction,
        level_type: broken_level.type,
        level_price: broken_level.price,
        entry_price: entry,
        stop_loss: stop,
        take_profit: target,
        retest_bar: retest_bar,
        break_bar: broken_level.break_bar,
        confluence: %{
          strong_rejection: strong_rejection?(retest_bar, broken_level.direction)
        },
        quality_score: calculate_quality_score(retest_bar, broken_level)
      })

    if Setup.meets_risk_reward?(setup, min_rr) do
      [setup]
    else
      []
    end
  end

  defp detect_break(prev_bar, curr_bar, level_price) do
    prev_below = Decimal.compare(prev_bar.close, level_price) != :gt
    curr_above = Decimal.compare(curr_bar.close, level_price) == :gt

    prev_above = Decimal.compare(prev_bar.close, level_price) != :lt
    curr_below = Decimal.compare(curr_bar.close, level_price) == :lt

    cond do
      prev_below and curr_above -> {:break, :long}
      prev_above and curr_below -> {:break, :short}
      true -> :no_break
    end
  end

  defp calculate_quality_score(retest_bar, broken_level) do
    score = 5

    # +2 for strong rejection
    score =
      if strong_rejection?(retest_bar, broken_level.direction) do
        score + 2
      else
        score
      end

    # +1 for high-value level types
    score =
      if broken_level.type in [:pdh, :pdl] do
        score + 1
      else
        score
      end

    min(score, 10)
  end
end
