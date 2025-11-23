defmodule Signal.Technicals.StructureDetector do
  @moduledoc """
  Detects market structure patterns: Break of Structure (BOS) and Change of Character (ChoCh).

  ## Concepts

  **Break of Structure (BOS):**
  - Bullish BOS: Price breaks above previous swing high (trend continuation)
  - Bearish BOS: Price breaks below previous swing low (trend continuation)

  **Change of Character (ChoCh):**
  - Bullish ChoCh: In downtrend, price breaks above previous swing high (reversal)
  - Bearish ChoCh: In uptrend, price breaks below previous swing low (reversal)

  **Trend Determination:**
  - Bullish: Higher highs and higher lows
  - Bearish: Lower highs and lower lows
  - Ranging: No clear pattern

  ## Usage

      # Analyze market structure
      structure = StructureDetector.analyze(bars)
      # => %{
      #   trend: :bullish,
      #   latest_bos: %{type: :bullish, price: 175.50, bar_time: ~U[...]},
      #   latest_choch: nil,
      #   swing_highs: [...],
      #   swing_lows: [...]
      # }

      # Determine trend from swings
      trend = StructureDetector.determine_trend(swing_highs, swing_lows)
      # => :bullish | :bearish | :ranging

      # Detect BOS
      bos = StructureDetector.detect_bos(bars, swings, :bullish)
      # => %{type: :bullish, price: ..., bar_time: ..., broken_swing: ...}

      # Get structure state classification
      state = StructureDetector.get_structure_state(structure)
      # => :strong_bullish | :weak_bullish | :strong_bearish | :weak_bearish | :ranging
  """

  alias Signal.Technicals.Swings
  alias Signal.MarketData.Bar

  @doc """
  Performs comprehensive market structure analysis on a bar series.

  ## Options

    * `:lookback` - Swing detection lookback (default: 2)
    * `:min_swings` - Minimum swings needed for trend (default: 3)

  ## Returns

  Map containing:
    * `:trend` - :bullish, :bearish, or :ranging
    * `:latest_bos` - Most recent break of structure (or nil)
    * `:latest_choch` - Most recent change of character (or nil)
    * `:swing_highs` - List of swing high maps
    * `:swing_lows` - List of swing low maps

  ## Examples

      iex> bars = [...]  # List of bars
      iex> StructureDetector.analyze(bars)
      %{
        trend: :bullish,
        latest_bos: %{
          type: :bullish,
          price: #Decimal<175.50>,
          bar_time: ~U[2024-11-23 10:30:00Z],
          index: 45,
          broken_swing: %{...}
        },
        latest_choch: nil,
        swing_highs: [...],
        swing_lows: [...]
      }
  """
  @spec analyze(list(Bar.t()), keyword()) :: %{
          trend: :bullish | :bearish | :ranging,
          latest_bos: map() | nil,
          latest_choch: map() | nil,
          swing_highs: list(map()),
          swing_lows: list(map())
        }
  def analyze(bars, opts \\ []) when is_list(bars) do
    lookback = Keyword.get(opts, :lookback, 2)

    # Identify swings
    all_swings = Swings.identify_swings(bars, lookback: lookback)

    swing_highs = Enum.filter(all_swings, &(&1.type == :high))
    swing_lows = Enum.filter(all_swings, &(&1.type == :low))

    # Determine trend
    trend = determine_trend(swing_highs, swing_lows)

    # Detect BOS and ChoCh
    latest_bos = detect_latest_bos(bars, swing_highs, swing_lows, trend)
    latest_choch = detect_latest_choch(bars, swing_highs, swing_lows, trend)

    %{
      trend: trend,
      latest_bos: latest_bos,
      latest_choch: latest_choch,
      swing_highs: swing_highs,
      swing_lows: swing_lows
    }
  end

  @doc """
  Detects Break of Structure in a bar series.

  BOS represents trend continuation - breaking beyond the previous swing point
  in the direction of the trend.

  ## Parameters

    * `bars` - List of bars to analyze
    * `swings` - Previously identified swings
    * `trend` - Current trend direction (:bullish or :bearish)

  ## Returns

  Map with BOS details or nil if no BOS detected:
    * `:type` - :bullish or :bearish
    * `:price` - Price where BOS occurred
    * `:bar_time` - Timestamp of BOS
    * `:index` - Index in bars list
    * `:broken_swing` - The swing that was broken

  ## Examples

      iex> StructureDetector.detect_bos(bars, swings, :bullish)
      %{
        type: :bullish,
        price: #Decimal<175.50>,
        bar_time: ~U[2024-11-23 10:30:00Z],
        index: 45,
        broken_swing: %{type: :high, price: #Decimal<175.00>, ...}
      }

      iex> StructureDetector.detect_bos(bars, swings, :ranging)
      nil
  """
  @spec detect_bos(list(Bar.t()), list(map()), atom()) :: map() | nil
  def detect_bos(bars, swings, trend) when trend in [:bullish, :bearish] do
    if Enum.empty?(bars) or Enum.empty?(swings) do
      nil
    else
      latest_bar = List.last(bars)

      case trend do
        :bullish ->
          # Look for break above previous swing high
          swing_highs = Enum.filter(swings, &(&1.type == :high))

          if Enum.empty?(swing_highs) do
            nil
          else
            prev_swing = List.last(swing_highs)

            if Decimal.compare(latest_bar.close, prev_swing.price) == :gt do
              %{
                type: :bullish,
                price: latest_bar.close,
                bar_time: latest_bar.bar_time,
                index: length(bars) - 1,
                broken_swing: prev_swing
              }
            else
              nil
            end
          end

        :bearish ->
          # Look for break below previous swing low
          swing_lows = Enum.filter(swings, &(&1.type == :low))

          if Enum.empty?(swing_lows) do
            nil
          else
            prev_swing = List.last(swing_lows)

            if Decimal.compare(latest_bar.close, prev_swing.price) == :lt do
              %{
                type: :bearish,
                price: latest_bar.close,
                bar_time: latest_bar.bar_time,
                index: length(bars) - 1,
                broken_swing: prev_swing
              }
            else
              nil
            end
          end
      end
    end
  end

  def detect_bos(_bars, _swings, :ranging), do: nil

  @doc """
  Detects Change of Character (trend reversal signal).

  ChoCh represents potential trend reversal - breaking beyond a swing point
  in the opposite direction of the current trend.

  ## Parameters

    * `bars` - List of bars to analyze
    * `swings` - Previously identified swings
    * `trend` - Current trend direction (:bullish or :bearish)

  ## Returns

  Map with ChoCh details or nil if no ChoCh detected:
    * `:type` - :bullish or :bearish (the reversal direction)
    * `:price` - Price where ChoCh occurred
    * `:bar_time` - Timestamp of ChoCh
    * `:index` - Index in bars list
    * `:broken_swing` - The swing that was broken

  ## Examples

      iex> # In uptrend, breaking swing low = bearish ChoCh
      iex> StructureDetector.detect_choch(bars, swings, :bullish)
      %{
        type: :bearish,
        price: #Decimal<174.20>,
        bar_time: ~U[2024-11-23 10:35:00Z],
        index: 48,
        broken_swing: %{type: :low, price: #Decimal<174.50>, ...}
      }

      iex> StructureDetector.detect_choch(bars, swings, :ranging)
      nil
  """
  @spec detect_choch(list(Bar.t()), list(map()), atom()) :: map() | nil
  def detect_choch(bars, swings, trend) when trend in [:bullish, :bearish] do
    if Enum.empty?(bars) or Enum.empty?(swings) do
      nil
    else
      latest_bar = List.last(bars)

      case trend do
        :bullish ->
          # In uptrend, ChoCh = break below swing low (bearish reversal)
          swing_lows = Enum.filter(swings, &(&1.type == :low))

          if Enum.empty?(swing_lows) do
            nil
          else
            prev_swing = List.last(swing_lows)

            if Decimal.compare(latest_bar.close, prev_swing.price) == :lt do
              %{
                type: :bearish,
                price: latest_bar.close,
                bar_time: latest_bar.bar_time,
                index: length(bars) - 1,
                broken_swing: prev_swing
              }
            else
              nil
            end
          end

        :bearish ->
          # In downtrend, ChoCh = break above swing high (bullish reversal)
          swing_highs = Enum.filter(swings, &(&1.type == :high))

          if Enum.empty?(swing_highs) do
            nil
          else
            prev_swing = List.last(swing_highs)

            if Decimal.compare(latest_bar.close, prev_swing.price) == :gt do
              %{
                type: :bullish,
                price: latest_bar.close,
                bar_time: latest_bar.bar_time,
                index: length(bars) - 1,
                broken_swing: prev_swing
              }
            else
              nil
            end
          end
      end
    end
  end

  def detect_choch(_bars, _swings, :ranging), do: nil

  @doc """
  Determines market trend from swing pattern.

  ## Parameters

    * `swing_highs` - List of swing high maps
    * `swing_lows` - List of swing low maps

  ## Returns

    * `:bullish` - Higher highs AND higher lows
    * `:bearish` - Lower highs AND lower lows
    * `:ranging` - Mixed or insufficient data

  ## Examples

      iex> # Bullish trend: HH and HL
      iex> swing_highs = [%{price: 100}, %{price: 105}, %{price: 110}]
      iex> swing_lows = [%{price: 95}, %{price: 98}, %{price: 102}]
      iex> StructureDetector.determine_trend(swing_highs, swing_lows)
      :bullish

      iex> # Bearish trend: LH and LL
      iex> swing_highs = [%{price: 110}, %{price: 105}, %{price: 100}]
      iex> swing_lows = [%{price: 102}, %{price: 98}, %{price: 95}]
      iex> StructureDetector.determine_trend(swing_highs, swing_lows)
      :bearish
  """
  @spec determine_trend(list(map()), list(map())) ::
          :bullish | :bearish | :ranging
  def determine_trend(swing_highs, swing_lows) do
    cond do
      length(swing_highs) < 2 or length(swing_lows) < 2 ->
        :ranging

      higher_highs?(swing_highs) and higher_lows?(swing_lows) ->
        :bullish

      lower_highs?(swing_highs) and lower_lows?(swing_lows) ->
        :bearish

      true ->
        :ranging
    end
  end

  @doc """
  Classifies market structure strength.

  ## Parameters

    * `structure` - Structure map from analyze/1

  ## Returns

  One of:
    * `:strong_bullish` - Bullish trend with BOS, no ChoCh
    * `:weak_bullish` - Bullish trend with ChoCh
    * `:strong_bearish` - Bearish trend with BOS, no ChoCh
    * `:weak_bearish` - Bearish trend with ChoCh
    * `:ranging` - No clear trend

  ## Examples

      iex> structure = %{trend: :bullish, latest_bos: %{...}, latest_choch: nil}
      iex> StructureDetector.get_structure_state(structure)
      :strong_bullish

      iex> structure = %{trend: :bullish, latest_bos: nil, latest_choch: %{...}}
      iex> StructureDetector.get_structure_state(structure)
      :weak_bullish
  """
  @spec get_structure_state(map()) ::
          :strong_bullish
          | :weak_bullish
          | :strong_bearish
          | :weak_bearish
          | :ranging
  def get_structure_state(%{trend: trend, latest_bos: bos, latest_choch: choch}) do
    case trend do
      :bullish ->
        if bos && !choch, do: :strong_bullish, else: :weak_bullish

      :bearish ->
        if bos && !choch, do: :strong_bearish, else: :weak_bearish

      :ranging ->
        :ranging
    end
  end

  # Private Helper Functions

  defp higher_highs?(swing_highs) when length(swing_highs) >= 2 do
    swing_highs
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [prev, curr] ->
      Decimal.compare(curr.price, prev.price) == :gt
    end)
  end

  defp higher_highs?(_), do: false

  defp higher_lows?(swing_lows) when length(swing_lows) >= 2 do
    swing_lows
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [prev, curr] ->
      Decimal.compare(curr.price, prev.price) == :gt
    end)
  end

  defp higher_lows?(_), do: false

  defp lower_highs?(swing_highs) when length(swing_highs) >= 2 do
    swing_highs
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [prev, curr] ->
      Decimal.compare(curr.price, prev.price) == :lt
    end)
  end

  defp lower_highs?(_), do: false

  defp lower_lows?(swing_lows) when length(swing_lows) >= 2 do
    swing_lows
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [prev, curr] ->
      Decimal.compare(curr.price, prev.price) == :lt
    end)
  end

  defp lower_lows?(_), do: false

  defp detect_latest_bos(bars, swing_highs, swing_lows, trend) do
    all_swings = (swing_highs ++ swing_lows) |> Enum.sort_by(& &1.index)
    detect_bos(bars, all_swings, trend)
  end

  defp detect_latest_choch(bars, swing_highs, swing_lows, trend) do
    all_swings = (swing_highs ++ swing_lows) |> Enum.sort_by(& &1.index)
    detect_choch(bars, all_swings, trend)
  end
end
