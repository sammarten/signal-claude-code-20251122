defmodule Signal.Technicals.PdArrays.OrderBlock do
  @moduledoc """
  Detects Order Blocks (OB) in price data.

  An Order Block is the last opposing candle (or candles) before a significant move
  in price that results in a Break of Structure (BOS). Order blocks represent areas
  where institutional orders were placed and are often revisited as support/resistance.

  ## Detection Algorithm

  1. Identify a Break of Structure (BOS) in the price series
  2. Look back to find the last opposing candle(s) before the BOS
  3. Mark the candle range as the order block zone
  4. Check for FVG overlap to increase quality score

  ## Order Block Types

  * **Bullish Order Block**: Last bearish candle(s) before a bullish BOS
    - Typically acts as support when price returns
  * **Bearish Order Block**: Last bullish candle(s) before a bearish BOS
    - Typically acts as resistance when price returns

  ## Usage

      # Detect order blocks in a bar series
      order_blocks = OrderBlock.scan(bars)

      # Check if an order block has been mitigated
      mitigated? = OrderBlock.mitigated?(ob, current_bar)

  ## Mitigation

  An order block is mitigated when price trades through it:
  - Bullish OB: Mitigated when price closes below the OB bottom
  - Bearish OB: Mitigated when price closes above the OB top
  """

  alias Signal.MarketData.Bar
  alias Signal.Technicals.StructureDetector
  alias Signal.Technicals.PdArrays.FairValueGap

  @type order_block :: %{
          symbol: String.t(),
          type: :bullish | :bearish,
          top: Decimal.t(),
          bottom: Decimal.t(),
          body_top: Decimal.t(),
          body_bottom: Decimal.t(),
          bar_time: DateTime.t(),
          bars: list(Bar.t()),
          bos_bar: Bar.t(),
          mitigated: boolean(),
          quality_score: integer(),
          has_fvg_confluence: boolean()
        }

  @doc """
  Scans a bar series to find all Order Blocks.

  ## Parameters

    * `bars` - List of bars in chronological order (oldest first)
    * `opts` - Options
      * `:lookback` - Swing detection lookback (default: 2)
      * `:max_ob_bars` - Maximum consecutive opposing bars to include (default: 3)
      * `:check_fvg` - Whether to check for FVG confluence (default: true)

  ## Returns

  List of order block maps in chronological order (oldest first).

  ## Examples

      iex> bars = [...]  # List of bars
      iex> OrderBlock.scan(bars)
      [
        %{type: :bullish, top: 175.50, bottom: 175.00, quality_score: 4, ...},
        %{type: :bearish, top: 174.00, bottom: 173.50, quality_score: 3, ...}
      ]
  """
  @spec scan(list(Bar.t()), keyword()) :: list(order_block())
  def scan(bars, opts \\ []) when is_list(bars) do
    lookback = Keyword.get(opts, :lookback, 2)
    max_ob_bars = Keyword.get(opts, :max_ob_bars, 3)
    check_fvg = Keyword.get(opts, :check_fvg, true)

    if length(bars) < 10 do
      []
    else
      # Find all BOS points
      bos_points = find_bos_points(bars, lookback)

      # For each BOS, find the order block
      fvgs = if check_fvg, do: FairValueGap.scan(bars), else: []

      bos_points
      |> Enum.map(fn bos ->
        find_order_block(bars, bos, max_ob_bars, fvgs)
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.reverse()
    end
  end

  @doc """
  Detects order blocks around a known BOS point.

  ## Parameters

    * `bars` - List of bars
    * `bos_index` - Index of the BOS bar in the series
    * `bos_type` - Type of BOS (:bullish or :bearish)
    * `opts` - Options (same as scan/2)

  ## Returns

    * `{:ok, order_block}` - Order block found
    * `{:error, reason}` - No order block found
  """
  @spec detect(list(Bar.t()), integer(), :bullish | :bearish, keyword()) ::
          {:ok, order_block()} | {:error, atom()}
  def detect(bars, bos_index, bos_type, opts \\ []) do
    max_ob_bars = Keyword.get(opts, :max_ob_bars, 3)
    check_fvg = Keyword.get(opts, :check_fvg, true)

    if bos_index < 1 or bos_index >= length(bars) do
      {:error, :invalid_index}
    else
      bos_bar = Enum.at(bars, bos_index)

      bos = %{
        type: bos_type,
        index: bos_index,
        bar: bos_bar
      }

      fvgs = if check_fvg, do: FairValueGap.scan(bars), else: []

      case find_order_block(bars, bos, max_ob_bars, fvgs) do
        nil -> {:error, :no_order_block}
        ob -> {:ok, ob}
      end
    end
  end

  @doc """
  Checks if an order block has been mitigated by a given bar.

  A bullish OB is mitigated when price trades through the bottom.
  A bearish OB is mitigated when price trades through the top.

  ## Parameters

    * `ob` - The order block to check
    * `bar` - The bar to check against

  ## Returns

  Boolean indicating if the order block has been mitigated.

  ## Examples

      iex> ob = %{type: :bullish, bottom: 175.00, ...}
      iex> bar = %Bar{close: 174.50, ...}  # Close below OB bottom
      iex> OrderBlock.mitigated?(ob, bar)
      true
  """
  @spec mitigated?(order_block(), Bar.t()) :: boolean()
  def mitigated?(%{type: :bullish, bottom: bottom}, %Bar{close: close}) do
    # Bullish OB mitigated when price closes below
    Decimal.compare(close, bottom) == :lt
  end

  def mitigated?(%{type: :bearish, top: top}, %Bar{close: close}) do
    # Bearish OB mitigated when price closes above
    Decimal.compare(close, top) == :gt
  end

  @doc """
  Checks if price is currently in the order block zone.

  ## Parameters

    * `ob` - The order block
    * `price` - Current price

  ## Returns

  Boolean indicating if price is within the OB zone.
  """
  @spec in_zone?(order_block(), Decimal.t()) :: boolean()
  def in_zone?(%{top: top, bottom: bottom}, price) do
    Decimal.compare(price, bottom) != :lt and Decimal.compare(price, top) != :gt
  end

  @doc """
  Calculates the 50% level (equilibrium) of an order block.

  The equilibrium is often used as a precise entry point.

  ## Parameters

    * `ob` - The order block

  ## Returns

  Decimal representing the midpoint of the OB.
  """
  @spec equilibrium(order_block()) :: Decimal.t()
  def equilibrium(%{top: top, bottom: bottom}) do
    top
    |> Decimal.add(bottom)
    |> Decimal.div(2)
  end

  @doc """
  Scores an order block based on quality factors.

  ## Scoring Criteria

    * +2 points: Has FVG confluence
    * +1 point: Unmitigated
    * +1 point: Body range is at least 50% of total range
    * +1 point: Displacement move was significant (> 2x OB range)

  ## Parameters

    * `ob` - The order block to score
    * `context` - Optional context map with additional factors

  ## Returns

  Integer score from 0 to 5.
  """
  @spec score(order_block(), map()) :: integer()
  def score(ob, context \\ %{}) do
    base_score = 0

    # +2 for FVG confluence
    score = if ob.has_fvg_confluence, do: base_score + 2, else: base_score

    # +1 for unmitigated
    score = if !ob.mitigated, do: score + 1, else: score

    # +1 for good body ratio
    score = if good_body_ratio?(ob), do: score + 1, else: score

    # +1 for significant displacement
    score = if significant_displacement?(ob), do: score + 1, else: score

    # Context-based scoring
    score =
      if Map.get(context, :htf_aligned?, false) do
        score + 1
      else
        score
      end

    min(score, 6)
  end

  @doc """
  Filters order blocks to return only unmitigated ones.

  ## Parameters

    * `obs` - List of order blocks
    * `bars` - Bars to check for mitigation

  ## Returns

  List of order blocks that haven't been mitigated.
  """
  @spec filter_unmitigated(list(order_block()), list(Bar.t())) :: list(order_block())
  def filter_unmitigated(obs, bars) do
    Enum.filter(obs, fn ob ->
      not Enum.any?(bars, fn bar -> mitigated?(ob, bar) end)
    end)
  end

  @doc """
  Gets the nearest unmitigated order block to current price.

  ## Parameters

    * `obs` - List of order blocks
    * `current_price` - Current price to measure distance from
    * `direction` - Optional filter by direction (:bullish or :bearish)

  ## Returns

  The nearest order block or nil if none found.
  """
  @spec nearest(list(order_block()), Decimal.t(), atom() | nil) :: order_block() | nil
  def nearest(obs, current_price, direction \\ nil) do
    obs
    |> Enum.filter(fn ob ->
      !ob.mitigated and (is_nil(direction) or ob.type == direction)
    end)
    |> Enum.min_by(
      fn ob ->
        eq = equilibrium(ob)
        Decimal.abs(Decimal.sub(current_price, eq))
      end,
      fn -> nil end
    )
  end

  # Private Functions

  defp find_bos_points(bars, lookback) do
    # Use sliding window to detect BOS at each point
    min_index = lookback * 2 + 5

    if length(bars) <= min_index do
      []
    else
      min_index..(length(bars) - 1)
      |> Enum.reduce([], fn idx, acc ->
        window = Enum.slice(bars, 0, idx + 1)
        structure = StructureDetector.analyze(window, lookback: lookback)

        case structure do
          %{latest_bos: %{type: type, index: bos_idx}} when not is_nil(type) ->
            bos_bar = Enum.at(window, bos_idx)

            bos = %{
              type: type,
              index: bos_idx,
              bar: bos_bar
            }

            # Only add if this is a new BOS (not already in the list)
            if not Enum.any?(acc, fn b -> b.index == bos_idx end) do
              [bos | acc]
            else
              acc
            end

          _ ->
            acc
        end
      end)
    end
  end

  defp find_order_block(bars, bos, max_ob_bars, fvgs) do
    bos_index = bos.index

    if bos_index < 1 do
      nil
    else
      # Determine what type of opposing candle we're looking for
      opposing_type = if bos.type == :bullish, do: :bearish, else: :bullish

      # Look back from BOS to find opposing candles
      preceding_bars = Enum.slice(bars, 0, bos_index) |> Enum.reverse()

      opposing_candles =
        preceding_bars
        |> Enum.take_while(fn bar -> candle_type(bar) == opposing_type end)
        |> Enum.take(max_ob_bars)

      if Enum.empty?(opposing_candles) do
        # No opposing candles immediately before BOS
        # Try to find at least one opposing candle within lookback
        single_opposing =
          Enum.find(Enum.take(preceding_bars, 5), fn bar ->
            candle_type(bar) == opposing_type
          end)

        if single_opposing do
          build_order_block([single_opposing], bos, fvgs)
        else
          nil
        end
      else
        build_order_block(opposing_candles, bos, fvgs)
      end
    end
  end

  defp build_order_block(ob_bars, bos, fvgs) do
    # ob_bars is in reverse order (most recent first)
    # last_bar is the most recent opposing candle (closest to BOS)
    last_bar = List.first(ob_bars)

    # Calculate the range
    all_highs = Enum.map(ob_bars, & &1.high)
    all_lows = Enum.map(ob_bars, & &1.low)
    all_opens = Enum.map(ob_bars, & &1.open)
    all_closes = Enum.map(ob_bars, & &1.close)

    top = Enum.max_by(all_highs, &Decimal.to_float/1)
    bottom = Enum.min_by(all_lows, &Decimal.to_float/1)

    body_top =
      Enum.max_by(all_opens ++ all_closes, &Decimal.to_float/1)

    body_bottom =
      Enum.min_by(all_opens ++ all_closes, &Decimal.to_float/1)

    # Check for FVG confluence
    has_fvg =
      Enum.any?(fvgs, fn fvg ->
        overlaps?(fvg, %{top: top, bottom: bottom})
      end)

    ob = %{
      symbol: last_bar.symbol,
      type: if(bos.type == :bullish, do: :bullish, else: :bearish),
      top: top,
      bottom: bottom,
      body_top: body_top,
      body_bottom: body_bottom,
      bar_time: last_bar.bar_time,
      bars: Enum.reverse(ob_bars),
      bos_bar: bos.bar,
      mitigated: false,
      quality_score: 0,
      has_fvg_confluence: has_fvg
    }

    %{ob | quality_score: score(ob)}
  end

  defp candle_type(%Bar{open: open, close: close}) do
    case Decimal.compare(close, open) do
      :gt -> :bullish
      :lt -> :bearish
      :eq -> :neutral
    end
  end

  defp overlaps?(%{top: fvg_top, bottom: fvg_bottom}, %{top: ob_top, bottom: ob_bottom}) do
    # Check if two ranges overlap
    not (Decimal.compare(fvg_bottom, ob_top) == :gt or
           Decimal.compare(fvg_top, ob_bottom) == :lt)
  end

  defp good_body_ratio?(%{top: top, bottom: bottom, body_top: body_top, body_bottom: body_bottom}) do
    total_range = Decimal.sub(top, bottom)
    body_range = Decimal.sub(body_top, body_bottom)

    if Decimal.compare(total_range, Decimal.new(0)) == :gt do
      ratio = Decimal.div(body_range, total_range)
      Decimal.compare(ratio, Decimal.new("0.5")) != :lt
    else
      false
    end
  end

  defp significant_displacement?(%{top: top, bottom: bottom, bos_bar: bos_bar}) do
    ob_range = Decimal.sub(top, bottom)
    displacement_range = Decimal.sub(bos_bar.high, bos_bar.low)

    if Decimal.compare(ob_range, Decimal.new(0)) == :gt do
      ratio = Decimal.div(displacement_range, ob_range)
      Decimal.compare(ratio, Decimal.new(2)) != :lt
    else
      false
    end
  end
end
