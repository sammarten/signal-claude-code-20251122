defmodule Signal.Data.MarketCalendar do
  @moduledoc """
  US stock market calendar fetched from Alpaca API.

  Provides functions to sync calendar data from Alpaca and query
  trading days, market hours, and early close information.

  Calendar data is stored in the `market_calendar` table and should
  be synced periodically or before backtesting to ensure accuracy.

  ## Usage

      # Sync calendar data (run once or periodically)
      Signal.Data.MarketCalendar.sync_calendar()

      # Check if a date is a trading day
      Signal.Data.MarketCalendar.trading_day?(~D[2024-01-02])
      #=> true

      # Get market hours for a date
      Signal.Data.MarketCalendar.get_hours(~D[2024-01-02])
      #=> {:ok, {~T[09:30:00], ~T[16:00:00]}}

      # Check if market is open at a given UTC datetime
      Signal.Data.MarketCalendar.market_open?(~U[2024-01-02 14:30:00Z])
      #=> true
  """

  import Ecto.Query
  require Logger

  alias Signal.Alpaca.Client
  alias Signal.Data.MarketCalendarDay
  alias Signal.Repo

  @timezone "America/New_York"

  # Alpaca provides calendar data through 2029
  @default_start_date ~D[2019-01-01]
  @default_end_date ~D[2029-12-31]

  @doc """
  Syncs market calendar data from Alpaca API.

  Fetches trading days for the given date range and upserts them
  into the database. By default, syncs from 2019-01-01 through 2029-12-31
  (the full range available from Alpaca).

  ## Options

    - `:start_date` - Start of date range (default: ~D[2019-01-01])
    - `:end_date` - End of date range (default: ~D[2029-12-31])

  ## Returns

    - `{:ok, count}` - Number of days synced
    - `{:error, reason}` - Error details
  """
  @spec sync_calendar(keyword()) :: {:ok, non_neg_integer()} | {:error, any()}
  def sync_calendar(opts \\ []) do
    start_date = Keyword.get(opts, :start_date, @default_start_date)
    end_date = Keyword.get(opts, :end_date, @default_end_date)

    Logger.info("Syncing market calendar from #{start_date} to #{end_date}")

    case Client.get_calendar(start: start_date, end: end_date) do
      {:ok, calendar_days} ->
        count = upsert_calendar_days(calendar_days)
        Logger.info("Synced #{count} trading days to market calendar")
        {:ok, count}

      {:error, reason} = error ->
        Logger.error("Failed to sync market calendar: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Returns true if the given date is a trading day.

  A date is a trading day if it exists in the market_calendar table.
  Non-trading days (weekends, holidays) are not stored.
  """
  @spec trading_day?(Date.t()) :: boolean()
  def trading_day?(date) do
    query = from(c in MarketCalendarDay, where: c.date == ^date)
    Repo.exists?(query)
  end

  @doc """
  Gets market hours for a specific date.

  ## Returns

    - `{:ok, {open_time, close_time}}` - Market hours
    - `{:error, :not_trading_day}` - Date is not a trading day
  """
  @spec get_hours(Date.t()) :: {:ok, {Time.t(), Time.t()}} | {:error, :not_trading_day}
  def get_hours(date) do
    case Repo.get(MarketCalendarDay, date) do
      nil -> {:error, :not_trading_day}
      day -> {:ok, {day.open, day.close}}
    end
  end

  @doc """
  Returns true if the given date is an early close day.

  Early close days have a market close time before 16:00.
  """
  @spec early_close?(Date.t()) :: boolean()
  def early_close?(date) do
    case Repo.get(MarketCalendarDay, date) do
      nil -> false
      day -> MarketCalendarDay.early_close?(day)
    end
  end

  @doc """
  Returns true if the market is open at the given UTC datetime.

  Converts the UTC datetime to Eastern Time and checks if it falls
  within market hours for that date.
  """
  @spec market_open?(DateTime.t()) :: boolean()
  def market_open?(datetime) do
    # Convert to Eastern Time
    et_datetime = DateTime.shift_zone!(datetime, @timezone)
    date = DateTime.to_date(et_datetime)
    time = DateTime.to_time(et_datetime)

    case get_hours(date) do
      {:ok, {open, close}} ->
        Time.compare(time, open) in [:gt, :eq] and Time.compare(time, close) == :lt

      {:error, :not_trading_day} ->
        false
    end
  end

  @doc """
  Returns the next market open datetime in UTC.

  If the market is currently open, returns the current market open time.
  Otherwise, returns the open time of the next trading day.
  """
  @spec next_market_open(DateTime.t()) :: {:ok, DateTime.t()} | {:error, :no_calendar_data}
  def next_market_open(datetime) do
    et_datetime = DateTime.shift_zone!(datetime, @timezone)
    date = DateTime.to_date(et_datetime)
    time = DateTime.to_time(et_datetime)

    case find_next_trading_day(date, time) do
      {:ok, trading_date, open_time} ->
        # Combine date and time in ET, then convert to UTC
        {:ok, naive} = NaiveDateTime.new(trading_date, open_time)

        case DateTime.from_naive(naive, @timezone) do
          {:ok, et_dt} ->
            {:ok, DateTime.shift_zone!(et_dt, "Etc/UTC")}

          {:ambiguous, dt1, _dt2} ->
            {:ok, DateTime.shift_zone!(dt1, "Etc/UTC")}

          {:gap, _dt1, dt2} ->
            {:ok, DateTime.shift_zone!(dt2, "Etc/UTC")}
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Returns the count of trading days between two dates (inclusive).
  """
  @spec trading_days_count(Date.t(), Date.t()) :: non_neg_integer()
  def trading_days_count(start_date, end_date) do
    query =
      from(c in MarketCalendarDay,
        where: c.date >= ^start_date and c.date <= ^end_date,
        select: count(c.date)
      )

    Repo.one(query) || 0
  end

  @doc """
  Returns all trading days between two dates (inclusive).
  """
  @spec trading_days_between(Date.t(), Date.t()) :: [Date.t()]
  def trading_days_between(start_date, end_date) do
    query =
      from(c in MarketCalendarDay,
        where: c.date >= ^start_date and c.date <= ^end_date,
        order_by: [asc: c.date],
        select: c.date
      )

    Repo.all(query)
  end

  @doc """
  Returns the expected number of market minutes for a date.

  Returns 0 if the date is not a trading day.
  """
  @spec expected_minutes(Date.t()) :: non_neg_integer()
  def expected_minutes(date) do
    case get_hours(date) do
      {:ok, {open, close}} ->
        Time.diff(close, open, :minute)

      {:error, :not_trading_day} ->
        0
    end
  end

  @doc """
  Returns the total expected minutes for a date range.
  """
  @spec total_expected_minutes(Date.t(), Date.t()) :: non_neg_integer()
  def total_expected_minutes(start_date, end_date) do
    query =
      from(c in MarketCalendarDay,
        where: c.date >= ^start_date and c.date <= ^end_date
      )

    Repo.all(query)
    |> Enum.reduce(0, fn day, acc ->
      acc + Time.diff(day.close, day.open, :minute)
    end)
  end

  @doc """
  Checks if calendar data exists for a date range.

  Returns true if at least one trading day exists in the range.
  """
  @spec has_calendar_data?(Date.t(), Date.t()) :: boolean()
  def has_calendar_data?(start_date, end_date) do
    query =
      from(c in MarketCalendarDay,
        where: c.date >= ^start_date and c.date <= ^end_date
      )

    Repo.exists?(query)
  end

  # Private functions

  defp upsert_calendar_days(calendar_days) do
    entries =
      Enum.map(calendar_days, fn day ->
        %{
          date: day.date,
          open: day.open,
          close: day.close
        }
      end)

    # Batch upsert
    {count, _} =
      Repo.insert_all(
        MarketCalendarDay,
        entries,
        on_conflict: {:replace, [:open, :close]},
        conflict_target: [:date]
      )

    count
  end

  defp find_next_trading_day(date, time) do
    # Check if today is a trading day and market hasn't closed yet
    case get_hours(date) do
      {:ok, {open, close}} ->
        if Time.compare(time, close) == :lt do
          # Market hasn't closed yet today
          if Time.compare(time, open) == :lt do
            # Market hasn't opened yet
            {:ok, date, open}
          else
            # Market is currently open
            {:ok, date, open}
          end
        else
          # Market closed, find next trading day
          find_next_trading_day_after(date)
        end

      {:error, :not_trading_day} ->
        # Not a trading day, find next one
        find_next_trading_day_after(date)
    end
  end

  defp find_next_trading_day_after(date) do
    # Look for the next trading day within the next 10 days
    query =
      from(c in MarketCalendarDay,
        where: c.date > ^date,
        order_by: [asc: c.date],
        limit: 1
      )

    case Repo.one(query) do
      nil -> {:error, :no_calendar_data}
      day -> {:ok, day.date, day.open}
    end
  end
end
