defmodule Signal.Preview.PremarketAnalyzer do
  @moduledoc """
  Analyzes premarket position and gap for symbols.

  Determines:
  - Gap direction and magnitude
  - Current position relative to previous day's range
  - Premarket high/low

  ## Usage

      {:ok, snapshot} = PremarketAnalyzer.analyze(:AAPL)
      # => %PremarketSnapshot{
      #   gap_percent: #Decimal<1.5>,
      #   gap_direction: :up,
      #   position_in_range: :above_prev_day_high
      # }
  """

  alias Signal.BarCache
  alias Signal.Technicals.Levels
  alias Signal.Preview.PremarketSnapshot

  @gap_threshold Decimal.new("0.5")

  @doc """
  Analyzes premarket position for a symbol.

  Uses BarCache for current price and KeyLevels for previous day data.

  ## Parameters

    * `symbol` - Symbol atom (e.g., :AAPL)

  ## Returns

    * `{:ok, %PremarketSnapshot{}}` - Premarket analysis
    * `{:error, atom()}` - Error during analysis
  """
  @spec analyze(atom()) :: {:ok, PremarketSnapshot.t()} | {:error, atom()}
  def analyze(symbol) do
    with {:ok, current_price} <- get_current_price(symbol),
         {:ok, levels} <- Levels.get_current_levels(symbol) do
      snapshot = build_snapshot(symbol, current_price, levels)
      {:ok, snapshot}
    end
  end

  @doc """
  Analyzes premarket position using provided price and levels.

  Useful when you already have the data and don't need to fetch it.

  ## Parameters

    * `symbol` - Symbol atom
    * `current_price` - Current market price
    * `levels` - KeyLevels struct with previous day data

  ## Returns

    * `%PremarketSnapshot{}` - Premarket analysis
  """
  @spec analyze_with_data(atom(), Decimal.t(), map()) :: PremarketSnapshot.t()
  def analyze_with_data(symbol, current_price, levels) do
    build_snapshot(symbol, current_price, levels)
  end

  @doc """
  Analyzes premarket for multiple symbols.

  ## Parameters

    * `symbols` - List of symbol atoms

  ## Returns

    * `{:ok, [%PremarketSnapshot{}]}` - List of premarket analyses
  """
  @spec analyze_all([atom()]) :: {:ok, [PremarketSnapshot.t()]}
  def analyze_all(symbols) do
    results =
      symbols
      |> Enum.map(fn symbol ->
        case analyze(symbol) do
          {:ok, snapshot} -> snapshot
          {:error, _} -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    {:ok, results}
  end

  # Private Functions

  defp get_current_price(symbol) do
    case BarCache.current_price(symbol) do
      {:ok, price} -> {:ok, price}
      :error -> {:error, :no_price_data}
    end
  end

  defp build_snapshot(symbol, current_price, levels) do
    previous_close = levels.previous_day_close || levels.previous_day_low
    previous_high = levels.previous_day_high
    previous_low = levels.previous_day_low

    gap_percent = calculate_gap_percent(current_price, previous_close)
    gap_direction = determine_gap_direction(gap_percent)
    position_in_range = determine_position(current_price, previous_high, previous_low)

    %PremarketSnapshot{
      symbol: to_string(symbol),
      timestamp: DateTime.utc_now(),
      current_price: current_price,
      previous_close: previous_close,
      gap_percent: gap_percent,
      gap_direction: gap_direction,
      premarket_high: levels.premarket_high,
      premarket_low: levels.premarket_low,
      premarket_volume: nil,
      position_in_range: position_in_range
    }
  end

  defp calculate_gap_percent(current, previous) when not is_nil(previous) do
    Decimal.mult(
      Decimal.div(Decimal.sub(current, previous), previous),
      Decimal.new("100")
    )
  end

  defp calculate_gap_percent(_, _), do: Decimal.new("0")

  defp determine_gap_direction(gap_percent) do
    cond do
      Decimal.compare(gap_percent, @gap_threshold) == :gt -> :up
      Decimal.compare(gap_percent, Decimal.negate(@gap_threshold)) == :lt -> :down
      true -> :flat
    end
  end

  defp determine_position(current, high, low) when not is_nil(high) and not is_nil(low) do
    range_size = Decimal.sub(high, low)
    ten_percent = Decimal.mult(range_size, Decimal.new("0.1"))

    near_high_threshold = Decimal.sub(high, ten_percent)
    near_low_threshold = Decimal.add(low, ten_percent)

    cond do
      Decimal.compare(current, high) == :gt ->
        :above_prev_day_high

      Decimal.compare(current, near_high_threshold) != :lt ->
        :near_prev_day_high

      Decimal.compare(current, low) == :lt ->
        :below_prev_day_low

      Decimal.compare(current, near_low_threshold) != :gt ->
        :near_prev_day_low

      true ->
        :middle_of_range
    end
  end

  defp determine_position(_, _, _), do: :middle_of_range
end
