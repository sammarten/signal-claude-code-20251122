defmodule Signal.Technicals.Levels do
  @moduledoc """
  Calculates and manages daily reference levels for trading strategies.

  ## Key Levels Tracked

  - **Previous Day High/Low (PDH/PDL)** - Calculated from previous trading day
  - **Premarket High/Low (PMH/PML)** - Calculated from 4:00 AM - 9:30 AM ET
  - **Opening Range High/Low - 5 minute (OR5H/OR5L)** - First 5 mins (9:30-9:35 AM)
  - **Opening Range High/Low - 15 minute (OR15H/OR15L)** - First 15 mins (9:30-9:45 AM)
  - **Psychological levels** - Whole, half, and quarter numbers

  ## Usage

      # Calculate all daily levels for a symbol
      {:ok, levels} = Levels.calculate_daily_levels(:AAPL, ~D[2024-11-23])

      # Get current levels for trading
      {:ok, levels} = Levels.get_current_levels(:AAPL)

      # Check if a level was broken
      broken? = Levels.level_broken?(Decimal.new("175.50"), Decimal.new("175.60"), Decimal.new("175.45"))

      # Find nearest psychological levels
      psych_levels = Levels.find_nearest_psychological(Decimal.new("175.23"))
      # => %{whole: #Decimal<175>, half: #Decimal<175.50>, quarter: #Decimal<175.25>}

      # Get price position relative to key levels
      {:ok, {position, level_name, level_price}} = Levels.get_level_status(:AAPL, Decimal.new("175.60"))
      # => {:ok, {:above, :pdl, #Decimal<175.50>}}
  """

  import Ecto.Query
  alias Signal.Repo
  alias Signal.MarketData.Bar
  alias Signal.Technicals.KeyLevels

  @doc """
  Calculates all daily reference levels for a symbol on a specific date.

  Computes PDH/PDL from previous trading day and PMH/PML from premarket session.
  Opening ranges are calculated separately via `update_opening_range/3`.

  ## Parameters

    * `symbol` - Symbol atom (e.g., :AAPL)
    * `date` - Date to calculate levels for

  ## Returns

    * `{:ok, %KeyLevels{}}` - Calculated levels
    * `{:error, :no_previous_day_data}` - No bars found for previous day
    * `{:error, :not_a_trading_day}` - Date is weekend/holiday
    * `{:error, :database_error}` - Database operation failed

  ## Examples

      iex> Levels.calculate_daily_levels(:AAPL, ~D[2024-11-23])
      {:ok, %KeyLevels{
        symbol: "AAPL",
        date: ~D[2024-11-23],
        previous_day_high: #Decimal<175.50>,
        previous_day_low: #Decimal<173.20>,
        premarket_high: #Decimal<174.80>,
        premarket_low: #Decimal<174.10>,
        ...
      }}
  """
  @spec calculate_daily_levels(atom(), Date.t()) ::
          {:ok, KeyLevels.t()} | {:error, atom()}
  def calculate_daily_levels(symbol, date) do
    with {:ok, :trading_day} <- validate_trading_day(date),
         {:ok, prev_bars} <- get_previous_day_bars(symbol, date),
         {:ok, pm_bars} <- get_premarket_bars(symbol, date) do
      {pdh, pdl} = calculate_high_low(prev_bars)
      {pmh, pml} = calculate_high_low(pm_bars)

      levels = %KeyLevels{
        symbol: to_string(symbol),
        date: date,
        previous_day_high: pdh,
        previous_day_low: pdl,
        premarket_high: pmh,
        premarket_low: pml
        # OR fields remain nil until 9:35/9:45
      }

      with {:ok, stored} <- store_levels(levels),
           :ok <- broadcast_levels_update(symbol, stored) do
        {:ok, stored}
      else
        {:error, _} -> {:error, :database_error}
      end
    end
  end

  @doc """
  Retrieves today's calculated levels for a symbol.

  ## Parameters

    * `symbol` - Symbol atom (e.g., :AAPL)

  ## Returns

    * `{:ok, %KeyLevels{}}` - Today's levels
    * `{:error, :not_found}` - No levels calculated for today

  ## Examples

      iex> Levels.get_current_levels(:AAPL)
      {:ok, %KeyLevels{symbol: "AAPL", date: ~D[2024-11-23], ...}}

      iex> Levels.get_current_levels(:INVALID)
      {:error, :not_found}
  """
  @spec get_current_levels(atom()) :: {:ok, KeyLevels.t()} | {:error, :not_found}
  def get_current_levels(symbol) do
    today = get_current_trading_date()

    query =
      from l in KeyLevels,
        where: l.symbol == ^to_string(symbol) and l.date == ^today

    case Repo.one(query) do
      nil -> {:error, :not_found}
      levels -> {:ok, levels}
    end
  end

  @doc """
  Calculates and updates opening range after market opens.

  Should be called at 9:35 AM ET for 5-minute range and 9:45 AM ET for 15-minute range.

  ## Parameters

    * `symbol` - Symbol atom
    * `date` - Trading date
    * `range_type` - :five_min or :fifteen_min

  ## Returns

    * `{:ok, %KeyLevels{}}` - Updated levels
    * `{:error, :insufficient_bars}` - Not enough bars for range
    * `{:error, :not_found}` - Levels not found for date

  ## Examples

      iex> Levels.update_opening_range(:AAPL, ~D[2024-11-23], :five_min)
      {:ok, %KeyLevels{opening_range_5m_high: #Decimal<175.10>, ...}}
  """
  @spec update_opening_range(atom(), Date.t(), :five_min | :fifteen_min) ::
          {:ok, KeyLevels.t()} | {:error, atom()}
  def update_opening_range(symbol, date, range_type) do
    minutes =
      case range_type do
        :five_min -> 5
        :fifteen_min -> 15
      end

    with {:ok, or_bars} <- get_opening_range_bars(symbol, date, minutes),
         {high, low} <- calculate_high_low(or_bars),
         {:ok, levels} <- get_levels_for_date(symbol, date) do
      updated =
        case range_type do
          :five_min ->
            %{levels | opening_range_5m_high: high, opening_range_5m_low: low}

          :fifteen_min ->
            %{levels | opening_range_15m_high: high, opening_range_15m_low: low}
        end

      case update_levels(updated) do
        {:ok, stored} ->
          broadcast_levels_update(symbol, stored)
          {:ok, stored}

        {:error, _} ->
          {:error, :database_error}
      end
    end
  end

  @doc """
  Determines if price broke through a level.

  A level is considered broken if price crosses it from one side to the other.

  ## Parameters

    * `level` - The level price to check
    * `current_price` - Current price
    * `previous_price` - Previous price

  ## Returns

  Boolean indicating if the level was broken.

  ## Examples

      iex> # Bullish break: price went from below to above level
      iex> Levels.level_broken?(Decimal.new("175.00"), Decimal.new("175.10"), Decimal.new("174.90"))
      true

      iex> # Bearish break: price went from above to below level
      iex> Levels.level_broken?(Decimal.new("175.00"), Decimal.new("174.90"), Decimal.new("175.10"))
      true

      iex> # No break: price stayed on same side
      iex> Levels.level_broken?(Decimal.new("175.00"), Decimal.new("175.20"), Decimal.new("175.10"))
      false
  """
  @spec level_broken?(Decimal.t(), Decimal.t(), Decimal.t()) :: boolean()
  def level_broken?(level, current_price, previous_price) do
    bullish_break =
      Decimal.compare(previous_price, level) != :gt and
        Decimal.compare(current_price, level) == :gt

    bearish_break =
      Decimal.compare(previous_price, level) != :lt and
        Decimal.compare(current_price, level) == :lt

    bullish_break or bearish_break
  end

  @doc """
  Finds nearest psychological price levels (whole, half, quarter numbers).

  ## Parameters

    * `price` - The price to find psychological levels for

  ## Returns

  Map with nearest whole, half, and quarter levels.

  ## Examples

      iex> Levels.find_nearest_psychological(Decimal.new("175.23"))
      %{
        whole: #Decimal<175>,
        half: #Decimal<175.50>,
        quarter: #Decimal<175.25>
      }

      iex> Levels.find_nearest_psychological(Decimal.new("175.50"))
      %{
        whole: #Decimal<176>,
        half: #Decimal<175.50>,
        quarter: #Decimal<175.50>
      }
  """
  @spec find_nearest_psychological(Decimal.t()) :: %{
          whole: Decimal.t(),
          half: Decimal.t(),
          quarter: Decimal.t()
        }
  def find_nearest_psychological(price) do
    # Whole number
    whole_down = Decimal.round(price, 0, :down)
    whole_up = Decimal.add(whole_down, Decimal.new(1))

    whole =
      if Decimal.compare(
           Decimal.sub(price, whole_down),
           Decimal.sub(whole_up, price)
         ) == :lt do
        whole_down
      else
        whole_up
      end

    # Half number
    half_down =
      Decimal.mult(
        Decimal.round(Decimal.div(price, Decimal.new("0.5")), 0, :down),
        Decimal.new("0.5")
      )

    half_up = Decimal.add(half_down, Decimal.new("0.5"))

    half =
      if Decimal.compare(
           Decimal.sub(price, half_down),
           Decimal.sub(half_up, price)
         ) == :lt do
        half_down
      else
        half_up
      end

    # Quarter number
    quarter_down =
      Decimal.mult(
        Decimal.round(Decimal.div(price, Decimal.new("0.25")), 0, :down),
        Decimal.new("0.25")
      )

    quarter_up = Decimal.add(quarter_down, Decimal.new("0.25"))

    quarter =
      if Decimal.compare(
           Decimal.sub(price, quarter_down),
           Decimal.sub(quarter_up, price)
         ) == :lt do
        quarter_down
      else
        quarter_up
      end

    %{whole: whole, half: half, quarter: quarter}
  end

  @doc """
  Determines price position relative to key levels.

  Finds the closest key level and returns whether price is above, below, or at it.

  ## Parameters

    * `symbol` - Symbol atom
    * `current_price` - Current price to check

  ## Returns

    * `{:ok, {position, level_name, level_value}}` - Position relative to nearest level
    * `{:error, :not_found}` - No levels found for symbol

  Where position is :above, :below, or :at, and level_name is one of:
  :pdh, :pdl, :pmh, :pml, :or5h, :or5l, :or15h, :or15l

  ## Examples

      iex> Levels.get_level_status(:AAPL, Decimal.new("175.60"))
      {:ok, {:above, :pdl, #Decimal<175.50>}}
  """
  @spec get_level_status(atom(), Decimal.t()) ::
          {:ok, {:above | :below | :at, atom(), Decimal.t()}}
          | {:error, :not_found}
  def get_level_status(symbol, current_price) do
    with {:ok, levels} <- get_current_levels(symbol) do
      all_levels =
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
        |> Enum.reject(fn {_name, value} -> is_nil(value) end)

      if Enum.empty?(all_levels) do
        {:error, :not_found}
      else
        # Find closest level
        {level_name, level_value} =
          Enum.min_by(all_levels, fn {_name, value} ->
            Decimal.abs(Decimal.sub(current_price, value))
          end)

        position =
          cond do
            Decimal.compare(current_price, level_value) == :gt -> :above
            Decimal.compare(current_price, level_value) == :lt -> :below
            true -> :at
          end

        {:ok, {position, level_name, level_value}}
      end
    end
  end

  # Private Helper Functions

  defp get_previous_day_bars(symbol, date) do
    prev_date = get_previous_trading_day(date)

    query =
      from b in Bar,
        where: b.symbol == ^to_string(symbol),
        where: fragment("?::date = ?", b.bar_time, ^prev_date),
        order_by: [asc: b.bar_time]

    bars = Repo.all(query)

    if Enum.empty?(bars) do
      {:error, :no_previous_day_data}
    else
      {:ok, bars}
    end
  end

  defp get_premarket_bars(symbol, date) do
    timezone = Application.get_env(:signal, :timezone, "America/New_York")

    premarket_start = DateTime.new!(date, ~T[04:00:00], timezone)
    premarket_end = DateTime.new!(date, ~T[09:30:00], timezone)

    query =
      from b in Bar,
        where: b.symbol == ^to_string(symbol),
        where: b.bar_time >= ^premarket_start,
        where: b.bar_time < ^premarket_end,
        order_by: [asc: b.bar_time]

    bars = Repo.all(query)

    # Premarket data is optional
    {:ok, bars}
  end

  defp get_opening_range_bars(symbol, date, minutes) do
    timezone = Application.get_env(:signal, :timezone, "America/New_York")

    range_start = DateTime.new!(date, ~T[09:30:00], timezone)
    range_end = DateTime.add(range_start, minutes * 60, :second)

    query =
      from b in Bar,
        where: b.symbol == ^to_string(symbol),
        where: b.bar_time >= ^range_start,
        where: b.bar_time < ^range_end,
        order_by: [asc: b.bar_time]

    bars = Repo.all(query)

    if length(bars) < minutes do
      {:error, :insufficient_bars}
    else
      {:ok, bars}
    end
  end

  defp calculate_high_low(bars) when is_list(bars) and length(bars) > 0 do
    high = Enum.max_by(bars, & &1.high).high
    low = Enum.min_by(bars, & &1.low).low
    {high, low}
  end

  defp calculate_high_low([]), do: {nil, nil}

  defp store_levels(%KeyLevels{} = levels) do
    Repo.insert(
      levels,
      on_conflict: {:replace_all_except, [:symbol, :date]},
      conflict_target: [:symbol, :date]
    )
  end

  defp update_levels(%KeyLevels{} = levels) do
    Repo.update(KeyLevels.changeset(levels, %{}))
  end

  defp get_levels_for_date(symbol, date) do
    query =
      from l in KeyLevels,
        where: l.symbol == ^to_string(symbol) and l.date == ^date

    case Repo.one(query) do
      nil -> {:error, :not_found}
      levels -> {:ok, levels}
    end
  end

  defp broadcast_levels_update(symbol, levels) do
    Phoenix.PubSub.broadcast(
      Signal.PubSub,
      "levels:#{symbol}",
      {:levels_updated, symbol, levels}
    )
  end

  defp get_current_trading_date do
    timezone = Application.get_env(:signal, :timezone, "America/New_York")
    DateTime.now!(timezone) |> DateTime.to_date()
  end

  defp get_previous_trading_day(date) do
    case Date.day_of_week(date) do
      # Monday → Friday
      1 -> Date.add(date, -3)
      # Other days → previous day
      _ -> Date.add(date, -1)
    end
  end

  defp validate_trading_day(date) do
    case Date.day_of_week(date) do
      day when day in [6, 7] -> {:error, :not_a_trading_day}
      _ -> {:ok, :trading_day}
    end
  end
end
