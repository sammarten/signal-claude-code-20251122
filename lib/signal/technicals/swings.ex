defmodule Signal.Technicals.Swings do
  @moduledoc """
  Detects swing highs and swing lows in bar data.

  A swing high is a bar whose high is higher than N bars before and after it.
  A swing low is a bar whose low is lower than N bars before and after it.

  ## Algorithm

  Default lookback period is 2 bars (configurable).

  ## Usage

      # Identify all swings in a bar series
      swings = Swings.identify_swings(bars)
      # => [
      #   %{type: :high, index: 5, price: 175.50, bar_time: ~U[...]},
      #   %{type: :low, index: 12, price: 174.20, bar_time: ~U[...]},
      #   ...
      # ]

      # Check if specific bar is a swing
      is_swing? = Swings.swing_high?(bars, 10, 2)

      # Get the most recent swing high
      latest_high = Swings.get_latest_swing(bars, :high)
  """

  alias Signal.MarketData.Bar

  @doc """
  Identifies all swing highs and lows in a bar series.

  ## Options

    * `:lookback` - Number of bars before/after to compare (default: 2)
    * `:min_bars` - Minimum bars required to detect swings (default: 5)

  ## Returns

  List of swing maps with keys:
    * `:type` - :high or :low
    * `:index` - Index in the bars list
    * `:price` - The swing price (high or low)
    * `:bar_time` - DateTime of the swing bar
    * `:bar` - The full bar struct

  ## Examples

      iex> bars = [...]  # List of bars
      iex> Swings.identify_swings(bars)
      [
        %{type: :high, index: 5, price: #Decimal<175.50>, bar_time: ~U[...], bar: %Bar{}},
        %{type: :low, index: 12, price: #Decimal<174.20>, bar_time: ~U[...], bar: %Bar{}}
      ]

      iex> Swings.identify_swings(bars, lookback: 3)
      [...]  # Swings with 3-bar lookback
  """
  @spec identify_swings(list(Bar.t()), keyword()) :: list(map())
  def identify_swings(bars, opts \\ []) when is_list(bars) do
    lookback = Keyword.get(opts, :lookback, 2)
    min_bars = Keyword.get(opts, :min_bars, lookback * 2 + 1)

    if length(bars) < min_bars do
      []
    else
      # Start from lookback index, end at length - lookback - 1
      start_idx = lookback
      end_idx = length(bars) - lookback - 1

      start_idx..end_idx
      |> Enum.reduce([], fn idx, acc ->
        bar = Enum.at(bars, idx)

        cond do
          swing_high?(bars, idx, lookback) ->
            [
              %{
                type: :high,
                index: idx,
                price: bar.high,
                bar_time: bar.bar_time,
                bar: bar
              }
              | acc
            ]

          swing_low?(bars, idx, lookback) ->
            [
              %{
                type: :low,
                index: idx,
                price: bar.low,
                bar_time: bar.bar_time,
                bar: bar
              }
              | acc
            ]

          true ->
            acc
        end
      end)
      |> Enum.reverse()
    end
  end

  @doc """
  Determines if the bar at the given index is a swing high.

  A swing high occurs when the bar's high is greater than the highs of
  N bars before and N bars after it.

  ## Parameters

    * `bars` - List of bars to analyze
    * `index` - Index of the bar to check
    * `lookback` - Number of bars before/after to compare (default: 2)

  ## Returns

  Boolean indicating if the bar is a swing high.

  ## Examples

      iex> bars = [...]
      iex> Swings.swing_high?(bars, 10, 2)
      true

      iex> Swings.swing_high?(bars, 10, 3)
      false
  """
  @spec swing_high?(list(Bar.t()), integer(), integer()) :: boolean()
  def swing_high?(bars, index, lookback \\ 2) do
    if index < lookback or index >= length(bars) - lookback do
      false
    else
      current_bar = Enum.at(bars, index)
      current_high = current_bar.high

      before_bars = Enum.slice(bars, index - lookback, lookback)
      after_bars = Enum.slice(bars, index + 1, lookback)

      all_before_lower =
        Enum.all?(before_bars, fn bar ->
          Decimal.compare(current_high, bar.high) == :gt
        end)

      all_after_lower =
        Enum.all?(after_bars, fn bar ->
          Decimal.compare(current_high, bar.high) == :gt
        end)

      all_before_lower and all_after_lower
    end
  end

  @doc """
  Determines if the bar at the given index is a swing low.

  A swing low occurs when the bar's low is less than the lows of
  N bars before and N bars after it.

  ## Parameters

    * `bars` - List of bars to analyze
    * `index` - Index of the bar to check
    * `lookback` - Number of bars before/after to compare (default: 2)

  ## Returns

  Boolean indicating if the bar is a swing low.

  ## Examples

      iex> bars = [...]
      iex> Swings.swing_low?(bars, 10, 2)
      true

      iex> Swings.swing_low?(bars, 10, 3)
      false
  """
  @spec swing_low?(list(Bar.t()), integer(), integer()) :: boolean()
  def swing_low?(bars, index, lookback \\ 2) do
    if index < lookback or index >= length(bars) - lookback do
      false
    else
      current_bar = Enum.at(bars, index)
      current_low = current_bar.low

      before_bars = Enum.slice(bars, index - lookback, lookback)
      after_bars = Enum.slice(bars, index + 1, lookback)

      all_before_higher =
        Enum.all?(before_bars, fn bar ->
          Decimal.compare(current_low, bar.low) == :lt
        end)

      all_after_higher =
        Enum.all?(after_bars, fn bar ->
          Decimal.compare(current_low, bar.low) == :lt
        end)

      all_before_higher and all_after_higher
    end
  end

  @doc """
  Gets the most recent swing high or swing low from a bar series.

  ## Parameters

    * `bars` - List of bars to analyze
    * `type` - Type of swing to find (:high or :low)

  ## Returns

  The most recent swing map, or nil if no swings of that type exist.

  ## Examples

      iex> bars = [...]
      iex> Swings.get_latest_swing(bars, :high)
      %{type: :high, index: 45, price: #Decimal<175.50>, bar_time: ~U[...], bar: %Bar{}}

      iex> Swings.get_latest_swing(bars, :low)
      %{type: :low, index: 50, price: #Decimal<174.20>, bar_time: ~U[...], bar: %Bar{}}

      iex> Swings.get_latest_swing([], :high)
      nil
  """
  @spec get_latest_swing(list(Bar.t()), :high | :low) :: map() | nil
  def get_latest_swing(bars, type) when type in [:high, :low] do
    bars
    |> identify_swings()
    |> Enum.filter(&(&1.type == type))
    |> List.last()
  end
end
