defmodule Signal.Technicals.PdArrays.FairValueGap do
  @moduledoc """
  Detects Fair Value Gaps (FVG) in price data.

  A Fair Value Gap is an imbalance in price created by aggressive institutional order flow.
  It forms when there's a gap between the wicks of non-adjacent candles, indicating
  an area where price moved so quickly that it didn't efficiently deliver to all
  market participants.

  ## Detection Algorithm

  An FVG is detected across three consecutive candles:
  - **Bullish FVG**: Bar 3's low is higher than Bar 1's high, creating a gap
  - **Bearish FVG**: Bar 3's high is lower than Bar 1's low, creating a gap

  The middle bar (Bar 2) represents the displacement candle that created the imbalance.

  ## Usage

      # Detect FVG from three consecutive bars
      {:ok, fvg} = FairValueGap.detect(bar1, bar2, bar3)
      # => %{type: :bullish, top: 175.50, bottom: 175.20, bar_time: ~U[...], ...}

      # Scan a bar series for all FVGs
      fvgs = FairValueGap.scan(bars)

      # Check if an FVG has been mitigated by a bar
      mitigated? = FairValueGap.mitigated?(fvg, current_bar)

  ## Mitigation

  An FVG is considered mitigated when price returns to the gap zone:
  - Bullish FVG is mitigated when price trades down into the gap (low <= gap top)
  - Bearish FVG is mitigated when price trades up into the gap (high >= gap bottom)
  """

  alias Signal.MarketData.Bar

  @type fvg :: %{
          symbol: String.t(),
          type: :bullish | :bearish,
          top: Decimal.t(),
          bottom: Decimal.t(),
          bar_time: DateTime.t(),
          displacement_bar: Bar.t(),
          mitigated: boolean(),
          size: Decimal.t()
        }

  @doc """
  Detects a Fair Value Gap from three consecutive bars.

  ## Parameters

    * `bar1` - First bar in the sequence
    * `bar2` - Middle bar (displacement candle)
    * `bar3` - Third bar in the sequence

  ## Returns

    * `{:ok, fvg}` - FVG detected with details
    * `{:error, :no_gap}` - No FVG present in these bars
    * `{:error, :invalid_bars}` - Invalid bar data

  ## Examples

      iex> bar1 = %Bar{high: 175.00, low: 174.50, ...}
      iex> bar2 = %Bar{high: 176.50, low: 175.80, ...}  # Displacement candle
      iex> bar3 = %Bar{high: 177.00, low: 175.50, ...}  # Gap: 175.50 - 175.00 = 0.50
      iex> FairValueGap.detect(bar1, bar2, bar3)
      {:ok, %{type: :bullish, top: #Decimal<175.50>, bottom: #Decimal<175.00>, ...}}
  """
  @spec detect(Bar.t(), Bar.t(), Bar.t()) :: {:ok, fvg()} | {:error, atom()}
  def detect(%Bar{} = bar1, %Bar{symbol: symbol} = bar2, %Bar{} = bar3) do
    bullish_gap = Decimal.sub(bar3.low, bar1.high)
    bearish_gap = Decimal.sub(bar1.low, bar3.high)

    cond do
      Decimal.compare(bullish_gap, Decimal.new(0)) == :gt ->
        {:ok,
         %{
           symbol: symbol,
           type: :bullish,
           top: bar3.low,
           bottom: bar1.high,
           bar_time: bar2.bar_time,
           displacement_bar: bar2,
           mitigated: false,
           size: bullish_gap
         }}

      Decimal.compare(bearish_gap, Decimal.new(0)) == :gt ->
        {:ok,
         %{
           symbol: symbol,
           type: :bearish,
           top: bar1.low,
           bottom: bar3.high,
           bar_time: bar2.bar_time,
           displacement_bar: bar2,
           mitigated: false,
           size: bearish_gap
         }}

      true ->
        {:error, :no_gap}
    end
  end

  def detect(_, _, _), do: {:error, :invalid_bars}

  @doc """
  Scans a bar series to find all Fair Value Gaps.

  ## Parameters

    * `bars` - List of bars in chronological order (oldest first)
    * `opts` - Options
      * `:min_size` - Minimum gap size to include (default: 0)
      * `:include_mitigated` - Whether to check mitigation (default: false)

  ## Returns

  List of FVG maps in chronological order (oldest first).

  ## Examples

      iex> bars = [...]  # List of bars
      iex> FairValueGap.scan(bars)
      [
        %{type: :bullish, top: 176.00, bottom: 175.50, ...},
        %{type: :bearish, top: 174.50, bottom: 174.00, ...}
      ]
  """
  @spec scan(list(Bar.t()), keyword()) :: list(fvg())
  def scan(bars, opts \\ []) when is_list(bars) do
    min_size = Keyword.get(opts, :min_size, Decimal.new(0))
    include_mitigated = Keyword.get(opts, :include_mitigated, false)

    if length(bars) < 3 do
      []
    else
      bars
      |> Enum.chunk_every(3, 1, :discard)
      |> Enum.with_index()
      |> Enum.reduce([], fn {[bar1, bar2, bar3], start_idx}, acc ->
        case detect(bar1, bar2, bar3) do
          {:ok, fvg} ->
            if Decimal.compare(fvg.size, min_size) != :lt do
              fvg_with_index = Map.put(fvg, :index, start_idx + 1)

              fvg_final =
                if include_mitigated do
                  # Check subsequent bars for mitigation
                  subsequent_bars = Enum.drop(bars, start_idx + 3)
                  check_mitigation_in_bars(fvg_with_index, subsequent_bars)
                else
                  fvg_with_index
                end

              [fvg_final | acc]
            else
              acc
            end

          {:error, _} ->
            acc
        end
      end)
      |> Enum.reverse()
    end
  end

  @doc """
  Checks if an FVG has been mitigated by a given bar.

  A bullish FVG is mitigated when price trades down into the gap.
  A bearish FVG is mitigated when price trades up into the gap.

  ## Parameters

    * `fvg` - The Fair Value Gap to check
    * `bar` - The bar to check against

  ## Returns

  Boolean indicating if the FVG has been mitigated.

  ## Examples

      iex> fvg = %{type: :bullish, top: 175.50, bottom: 175.00, ...}
      iex> bar = %Bar{low: 175.20, ...}  # Low enters the gap
      iex> FairValueGap.mitigated?(fvg, bar)
      true

      iex> bar = %Bar{low: 175.60, ...}  # Low doesn't reach the gap
      iex> FairValueGap.mitigated?(fvg, bar)
      false
  """
  @spec mitigated?(fvg(), Bar.t()) :: boolean()
  def mitigated?(%{type: :bullish, top: top}, %Bar{low: low}) do
    # Bullish FVG mitigated when price trades down into gap (low <= top)
    Decimal.compare(low, top) != :gt
  end

  def mitigated?(%{type: :bearish, bottom: bottom}, %Bar{high: high}) do
    # Bearish FVG mitigated when price trades up into gap (high >= bottom)
    Decimal.compare(high, bottom) != :lt
  end

  @doc """
  Checks if an FVG has been fully filled (closed) by a bar.

  A bullish FVG is filled when price trades below the entire gap.
  A bearish FVG is filled when price trades above the entire gap.

  ## Parameters

    * `fvg` - The Fair Value Gap to check
    * `bar` - The bar to check against

  ## Returns

  Boolean indicating if the FVG has been completely filled.

  ## Examples

      iex> fvg = %{type: :bullish, top: 175.50, bottom: 175.00, ...}
      iex> bar = %Bar{low: 174.90, ...}  # Low goes below the gap
      iex> FairValueGap.filled?(fvg, bar)
      true
  """
  @spec filled?(fvg(), Bar.t()) :: boolean()
  def filled?(%{type: :bullish, bottom: bottom}, %Bar{low: low}) do
    Decimal.compare(low, bottom) != :gt
  end

  def filled?(%{type: :bearish, top: top}, %Bar{high: high}) do
    Decimal.compare(high, top) != :lt
  end

  @doc """
  Calculates the 50% level (consequent encroachment) of an FVG.

  The CE level is often used as a precise entry point in trading strategies.

  ## Parameters

    * `fvg` - The Fair Value Gap

  ## Returns

  Decimal representing the midpoint of the FVG.

  ## Examples

      iex> fvg = %{top: 175.50, bottom: 175.00, ...}
      iex> FairValueGap.consequent_encroachment(fvg)
      #Decimal<175.25>
  """
  @spec consequent_encroachment(fvg()) :: Decimal.t()
  def consequent_encroachment(%{top: top, bottom: bottom}) do
    top
    |> Decimal.add(bottom)
    |> Decimal.div(2)
  end

  @doc """
  Filters FVGs to return only unmitigated ones.

  ## Parameters

    * `fvgs` - List of FVGs
    * `bars` - Bars to check for mitigation

  ## Returns

  List of FVGs that haven't been mitigated.
  """
  @spec filter_unmitigated(list(fvg()), list(Bar.t())) :: list(fvg())
  def filter_unmitigated(fvgs, bars) do
    Enum.filter(fvgs, fn fvg ->
      not Enum.any?(bars, fn bar -> mitigated?(fvg, bar) end)
    end)
  end

  @doc """
  Gets the nearest unmitigated FVG to current price.

  ## Parameters

    * `fvgs` - List of FVGs
    * `current_price` - Current price to measure distance from
    * `direction` - Optional filter by direction (:bullish or :bearish)

  ## Returns

  The nearest FVG or nil if none found.
  """
  @spec nearest(list(fvg()), Decimal.t(), atom() | nil) :: fvg() | nil
  def nearest(fvgs, current_price, direction \\ nil) do
    fvgs
    |> Enum.filter(fn fvg ->
      !fvg.mitigated and (is_nil(direction) or fvg.type == direction)
    end)
    |> Enum.min_by(
      fn fvg ->
        ce = consequent_encroachment(fvg)
        Decimal.abs(Decimal.sub(current_price, ce))
      end,
      fn -> nil end
    )
  end

  # Private Functions

  defp check_mitigation_in_bars(fvg, bars) do
    mitigation_bar =
      Enum.find(bars, fn bar ->
        mitigated?(fvg, bar)
      end)

    if mitigation_bar do
      %{fvg | mitigated: true}
      |> Map.put(:mitigated_at, mitigation_bar.bar_time)
    else
      fvg
    end
  end
end
