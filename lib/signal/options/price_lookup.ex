defmodule Signal.Options.PriceLookup do
  @moduledoc """
  Looks up historical options prices from stored bar data.

  This module provides functions to retrieve options prices at specific times
  for backtesting purposes. Instead of simulating prices with theoretical models,
  we use actual historical market data.

  ## Usage

      # Get entry price for a contract at a specific time
      {:ok, premium} = PriceLookup.get_entry_price(contract_symbol, entry_time)

      # Get exit price for a contract at a specific time
      {:ok, premium} = PriceLookup.get_exit_price(contract_symbol, exit_time)

      # Get bar at or near a specific time
      {:ok, bar} = PriceLookup.get_bar_at(contract_symbol, datetime)

  ## Price Selection

  For entry prices, we use the bar open (simulating market entry).
  For exit prices, we use the bar close (simulating market exit).
  This can be configured via options.
  """

  alias Signal.Options.Bar
  alias Signal.Repo

  import Ecto.Query

  @doc """
  Gets the entry price (premium) for an options contract at the given time.

  By default, uses the bar open price to simulate a market entry.

  ## Parameters

    * `contract_symbol` - OSI format contract symbol
    * `datetime` - DateTime for the entry
    * `opts` - Options:
      - `:price_field` - Which field to use (:open, :close, :high, :low, :vwap)
        Default: :open

  ## Returns

    * `{:ok, premium}` - The premium per share as a Decimal
    * `{:error, :no_data}` - No bar data available for this time
  """
  @spec get_entry_price(String.t(), DateTime.t(), keyword()) ::
          {:ok, Decimal.t()} | {:error, atom()}
  def get_entry_price(contract_symbol, datetime, opts \\ []) do
    price_field = Keyword.get(opts, :price_field, :open)
    get_price_at(contract_symbol, datetime, price_field)
  end

  @doc """
  Gets the exit price (premium) for an options contract at the given time.

  By default, uses the bar close price to simulate a market exit.

  ## Parameters

    * `contract_symbol` - OSI format contract symbol
    * `datetime` - DateTime for the exit
    * `opts` - Options:
      - `:price_field` - Which field to use (:open, :close, :high, :low, :vwap)
        Default: :close

  ## Returns

    * `{:ok, premium}` - The premium per share as a Decimal
    * `{:error, :no_data}` - No bar data available for this time
  """
  @spec get_exit_price(String.t(), DateTime.t(), keyword()) ::
          {:ok, Decimal.t()} | {:error, atom()}
  def get_exit_price(contract_symbol, datetime, opts \\ []) do
    price_field = Keyword.get(opts, :price_field, :close)
    get_price_at(contract_symbol, datetime, price_field)
  end

  @doc """
  Gets the bar at or nearest to the specified time.

  First tries to find an exact match, then falls back to the nearest bar
  within a reasonable window (default: 5 minutes).

  ## Parameters

    * `contract_symbol` - OSI format contract symbol
    * `datetime` - Target DateTime
    * `opts` - Options:
      - `:window_minutes` - How many minutes to search before/after (default: 5)

  ## Returns

    * `{:ok, bar}` - The matching or nearest bar
    * `{:error, :no_data}` - No bar data available within the window
  """
  @spec get_bar_at(String.t(), DateTime.t(), keyword()) ::
          {:ok, Bar.t()} | {:error, atom()}
  def get_bar_at(contract_symbol, datetime, opts \\ []) do
    window_minutes = Keyword.get(opts, :window_minutes, 5)

    # First try exact match (truncated to minute)
    bar_time = DateTime.truncate(datetime, :second)
    bar_time = %{bar_time | second: 0, microsecond: {0, 0}}

    case get_exact_bar(contract_symbol, bar_time) do
      {:ok, _bar} = success ->
        success

      {:error, :no_data} ->
        # Fall back to nearest bar within window
        get_nearest_bar(contract_symbol, datetime, window_minutes)
    end
  end

  @doc """
  Gets bars for a contract within a time range.

  Useful for analyzing price action during a trade.

  ## Parameters

    * `contract_symbol` - OSI format contract symbol
    * `start_time` - Start DateTime
    * `end_time` - End DateTime

  ## Returns

    * List of bars, ordered by time ascending
  """
  @spec get_bars_in_range(String.t(), DateTime.t(), DateTime.t()) :: [Bar.t()]
  def get_bars_in_range(contract_symbol, start_time, end_time) do
    from(b in Bar,
      where:
        b.symbol == ^contract_symbol and
          b.bar_time >= ^start_time and
          b.bar_time <= ^end_time,
      order_by: [asc: b.bar_time]
    )
    |> Repo.all()
  end

  @doc """
  Checks if price data is available for a contract at a specific time.

  ## Parameters

    * `contract_symbol` - OSI format contract symbol
    * `datetime` - Target DateTime

  ## Returns

    * `true` if data is available
    * `false` if no data
  """
  @spec data_available?(String.t(), DateTime.t()) :: boolean()
  def data_available?(contract_symbol, datetime) do
    case get_bar_at(contract_symbol, datetime) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  @doc """
  Gets the high and low prices for a contract on a specific day.

  Useful for checking if stop or target prices were hit.

  ## Parameters

    * `contract_symbol` - OSI format contract symbol
    * `date` - The Date to query

  ## Returns

    * `{:ok, %{high: high, low: low}}` - The day's high and low
    * `{:error, :no_data}` - No data for this day
  """
  @spec get_day_range(String.t(), Date.t()) ::
          {:ok, %{high: Decimal.t(), low: Decimal.t()}} | {:error, atom()}
  def get_day_range(contract_symbol, date) do
    start_of_day = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    end_of_day = DateTime.new!(date, ~T[23:59:59], "Etc/UTC")

    query =
      from(b in Bar,
        where:
          b.symbol == ^contract_symbol and
            b.bar_time >= ^start_of_day and
            b.bar_time <= ^end_of_day,
        select: %{
          high: max(b.high),
          low: min(b.low)
        }
      )

    case Repo.one(query) do
      %{high: nil, low: nil} -> {:error, :no_data}
      %{high: high, low: low} -> {:ok, %{high: high, low: low}}
    end
  end

  # Private Functions

  defp get_price_at(contract_symbol, datetime, price_field) do
    case get_bar_at(contract_symbol, datetime) do
      {:ok, bar} ->
        price = Map.get(bar, price_field)
        {:ok, price}

      {:error, _} = error ->
        error
    end
  end

  defp get_exact_bar(contract_symbol, bar_time) do
    query =
      from(b in Bar,
        where: b.symbol == ^contract_symbol and b.bar_time == ^bar_time
      )

    case Repo.one(query) do
      nil -> {:error, :no_data}
      bar -> {:ok, bar}
    end
  end

  defp get_nearest_bar(contract_symbol, datetime, window_minutes) do
    window_start = DateTime.add(datetime, -window_minutes * 60, :second)
    window_end = DateTime.add(datetime, window_minutes * 60, :second)

    # Get bars within window, ordered by distance from target time
    bars =
      from(b in Bar,
        where:
          b.symbol == ^contract_symbol and
            b.bar_time >= ^window_start and
            b.bar_time <= ^window_end,
        order_by: [asc: b.bar_time]
      )
      |> Repo.all()

    case bars do
      [] ->
        {:error, :no_data}

      bars ->
        # Find the bar nearest to the target time
        nearest =
          Enum.min_by(bars, fn bar ->
            abs(DateTime.diff(bar.bar_time, datetime, :second))
          end)

        {:ok, nearest}
    end
  end
end
