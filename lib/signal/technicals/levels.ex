defmodule Signal.Technicals.Levels do
  @moduledoc """
  Calculates and manages daily reference levels for trading strategies.

  ## Key Levels Tracked

  - **Previous Day High/Low (PDH/PDL)** - Calculated from previous trading day
  - **Previous Day Open/Close** - For gap analysis
  - **Premarket High/Low (PMH/PML)** - Calculated from 4:00 AM - 9:30 AM ET
  - **Opening Range High/Low - 5 minute (OR5H/OR5L)** - First 5 mins (9:30-9:35 AM)
  - **Opening Range High/Low - 15 minute (OR15H/OR15L)** - First 15 mins (9:30-9:45 AM)
  - **Weekly High/Low/Close** - Last 5 trading days
  - **Equilibrium** - Midpoint of weekly range
  - **All-Time High (ATH)** - Highest price in available history
  - **Psychological levels** - Whole, half, and quarter numbers

  ## Usage

      # Calculate all daily levels for a symbol
      {:ok, levels} = Levels.calculate_daily_levels(:AAPL, ~D[2024-11-23])

      # Calculate extended levels including weekly and ATH
      {:ok, levels} = Levels.calculate_extended_levels(:AAPL, ~D[2024-11-23])

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
      {pdo, pdc} = calculate_open_close(prev_bars)
      {pmh, pml} = calculate_high_low(pm_bars)

      levels = %KeyLevels{
        symbol: to_string(symbol),
        date: date,
        previous_day_high: pdh,
        previous_day_low: pdl,
        previous_day_open: pdo,
        previous_day_close: pdc,
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
  Calculates extended levels including weekly range and all-time high.

  Builds on daily levels by adding:
  - Last week high/low/close (5 trading days)
  - Equilibrium (midpoint of weekly range)
  - All-time high from available history

  ## Parameters

    * `symbol` - Symbol atom (e.g., :AAPL)
    * `date` - Date to calculate levels for

  ## Returns

    * `{:ok, %KeyLevels{}}` - Calculated levels including extended fields
    * `{:error, atom()}` - Error during calculation
  """
  @spec calculate_extended_levels(atom(), Date.t()) ::
          {:ok, KeyLevels.t()} | {:error, atom()}
  def calculate_extended_levels(symbol, date) do
    with {:ok, levels} <- calculate_daily_levels(symbol, date),
         {:ok, weekly} <- calculate_weekly_levels(symbol, date),
         {:ok, ath} <- calculate_all_time_high(symbol) do
      equilibrium = calculate_equilibrium(weekly.high, weekly.low)

      updated_levels = %{
        levels
        | last_week_high: weekly.high,
          last_week_low: weekly.low,
          last_week_close: weekly.close,
          equilibrium: equilibrium,
          all_time_high: ath
      }

      with {:ok, stored} <- store_levels(updated_levels),
           :ok <- broadcast_levels_update(symbol, stored) do
        {:ok, stored}
      else
        {:error, _} -> {:error, :database_error}
      end
    end
  end

  @doc """
  Calculates weekly levels (last 5 trading days high/low/close).

  ## Parameters

    * `symbol` - Symbol atom
    * `date` - Reference date (calculates from previous 5 trading days)

  ## Returns

    * `{:ok, %{high: Decimal, low: Decimal, close: Decimal}}` - Weekly metrics
    * `{:error, :insufficient_data}` - Not enough historical data
  """
  @spec calculate_weekly_levels(atom(), Date.t()) ::
          {:ok, %{high: Decimal.t(), low: Decimal.t(), close: Decimal.t()}}
          | {:error, atom()}
  def calculate_weekly_levels(symbol, date) do
    # Get bars for last 5 trading days (excluding today)
    start_date = get_trading_day_n_days_ago(date, 5)

    query =
      from b in Bar,
        where: b.symbol == ^to_string(symbol),
        where:
          fragment("?::date >= ? AND ?::date < ?", b.bar_time, ^start_date, b.bar_time, ^date),
        order_by: [asc: b.bar_time]

    bars = Repo.all(query)

    if length(bars) < 10 do
      {:error, :insufficient_data}
    else
      high = Enum.max_by(bars, & &1.high).high
      low = Enum.min_by(bars, & &1.low).low
      close = List.last(bars).close

      {:ok, %{high: high, low: low, close: close}}
    end
  end

  @doc """
  Calculates all-time high from available historical data.

  Uses up to 252 trading days (1 year) of data for efficiency.

  ## Parameters

    * `symbol` - Symbol atom

  ## Returns

    * `{:ok, Decimal.t()}` - All-time high price
    * `{:error, :no_data}` - No historical data found
  """
  @spec calculate_all_time_high(atom()) :: {:ok, Decimal.t()} | {:error, atom()}
  def calculate_all_time_high(symbol) do
    query =
      from b in Bar,
        where: b.symbol == ^to_string(symbol),
        select: max(b.high)

    case Repo.one(query) do
      nil -> {:error, :no_data}
      high -> {:ok, high}
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
    %{
      whole: find_nearest_level(price, Decimal.new("1")),
      half: find_nearest_level(price, Decimal.new("0.5")),
      quarter: find_nearest_level(price, Decimal.new("0.25"))
    }
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

  defp find_nearest_level(price, increment) do
    # Calculate the level below current price
    level_down =
      Decimal.mult(
        Decimal.round(Decimal.div(price, increment), 0, :down),
        increment
      )

    # Calculate the level above current price
    level_up = Decimal.add(level_down, increment)

    # Find which level is closer
    distance_to_down = Decimal.sub(price, level_down)
    distance_to_up = Decimal.sub(level_up, price)

    if Decimal.compare(distance_to_down, distance_to_up) == :lt do
      level_down
    else
      level_up
    end
  end

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

  defp calculate_open_close(bars) when is_list(bars) and length(bars) > 0 do
    open = List.first(bars).open
    close = List.last(bars).close
    {open, close}
  end

  defp calculate_open_close([]), do: {nil, nil}

  defp calculate_equilibrium(high, low) when not is_nil(high) and not is_nil(low) do
    Decimal.div(Decimal.add(high, low), 2)
  end

  defp calculate_equilibrium(_, _), do: nil

  defp get_trading_day_n_days_ago(date, n) do
    # Account for weekends: if we need 5 trading days, we might need up to 7 calendar days
    calendar_days = n + div(n, 5) * 2 + 2
    Date.add(date, -calendar_days)
  end

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
