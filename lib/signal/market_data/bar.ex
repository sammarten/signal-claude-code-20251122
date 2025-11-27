defmodule Signal.MarketData.Bar do
  @moduledoc """
  Ecto schema for 1-minute market bars stored in TimescaleDB hypertable.

  Represents OHLCV (Open, High, Low, Close, Volume) data for a given symbol
  at a specific timestamp. Uses a composite primary key of (symbol, bar_time)
  for efficient time-series queries.

  ## Fields

    * `:symbol` - Stock symbol (e.g., "AAPL")
    * `:bar_time` - Timestamp of the bar in UTC
    * `:open` - Opening price
    * `:high` - Highest price during the bar
    * `:low` - Lowest price during the bar
    * `:close` - Closing price
    * `:volume` - Total volume traded
    * `:vwap` - Volume-weighted average price (optional)
    * `:trade_count` - Number of trades (optional)
    * `:session` - Market session: :pre_market, :regular, or :after_hours
    * `:date` - Trading date in Eastern Time

  ## Market Sessions (Eastern Time)

    * `:pre_market` - 4:00 AM to 9:29 AM ET
    * `:regular` - 9:30 AM to 3:59 PM ET
    * `:after_hours` - 4:00 PM to 3:59 AM ET (next day)

  ## Examples

      iex> bar = %Signal.MarketData.Bar{
      ...>   symbol: "AAPL",
      ...>   bar_time: ~U[2024-11-15 14:30:00Z],
      ...>   open: Decimal.new("185.20"),
      ...>   high: Decimal.new("185.60"),
      ...>   low: Decimal.new("184.90"),
      ...>   close: Decimal.new("185.45"),
      ...>   volume: 2_300_000,
      ...>   session: :regular,
      ...>   date: ~D[2024-11-15]
      ...> }
      iex> Signal.Repo.insert(bar)
      {:ok, %Signal.MarketData.Bar{}}
  """

  use Ecto.Schema
  import Ecto.Changeset

  @timezone "America/New_York"

  # Market session boundaries (Eastern Time)
  @pre_market_start ~T[04:00:00]
  @regular_start ~T[09:30:00]
  @after_hours_start ~T[16:00:00]

  @primary_key false
  schema "market_bars" do
    field :symbol, :string, primary_key: true
    field :bar_time, :utc_datetime_usec, primary_key: true
    field :open, :decimal
    field :high, :decimal
    field :low, :decimal
    field :close, :decimal
    field :volume, :integer
    field :vwap, :decimal
    field :trade_count, :integer
    field :session, Ecto.Enum, values: [:pre_market, :regular, :after_hours]
    field :date, :date
  end

  @doc """
  Creates a changeset for a bar with validation.

  Validates:
  - Required fields: symbol, bar_time, open, high, low, close, volume, session, date
  - OHLC relationships: high >= open/close, low <= open/close
  - Volume and trade_count are non-negative

  ## Parameters

    * `bar` - The bar struct to validate
    * `attrs` - Map of attributes to apply

  ## Returns

  An Ecto.Changeset struct

  ## Examples

      iex> changeset = Signal.MarketData.Bar.changeset(%Signal.MarketData.Bar{}, %{
      ...>   symbol: "AAPL",
      ...>   bar_time: ~U[2024-11-15 14:30:00Z],
      ...>   open: Decimal.new("100.00"),
      ...>   high: Decimal.new("101.00"),
      ...>   low: Decimal.new("99.00"),
      ...>   close: Decimal.new("100.50"),
      ...>   volume: 1000,
      ...>   session: :regular,
      ...>   date: ~D[2024-11-15]
      ...> })
      iex> changeset.valid?
      true
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(bar, attrs) do
    bar
    |> cast(attrs, [
      :symbol,
      :bar_time,
      :open,
      :high,
      :low,
      :close,
      :volume,
      :vwap,
      :trade_count,
      :session,
      :date
    ])
    |> validate_required([
      :symbol,
      :bar_time,
      :open,
      :high,
      :low,
      :close,
      :volume,
      :session,
      :date
    ])
    |> validate_ohlc_relationships()
    |> validate_number(:volume, greater_than_or_equal_to: 0)
    |> validate_number(:trade_count, greater_than_or_equal_to: 0)
  end

  # Validates OHLC price relationships.
  # Ensures high >= open/close and low <= open/close
  defp validate_ohlc_relationships(changeset) do
    open = get_field(changeset, :open)
    high = get_field(changeset, :high)
    low = get_field(changeset, :low)
    close = get_field(changeset, :close)

    cond do
      is_nil(open) or is_nil(high) or is_nil(low) or is_nil(close) ->
        changeset

      Decimal.lt?(high, open) or Decimal.lt?(high, close) ->
        add_error(changeset, :high, "must be >= open and close")

      Decimal.gt?(low, open) or Decimal.gt?(low, close) ->
        add_error(changeset, :low, "must be <= open and close")

      true ->
        changeset
    end
  end

  @doc """
  Converts an Alpaca API bar response to a Bar struct.

  Maps Alpaca's field names to the schema fields and converts the data
  to appropriate types (Decimal for prices, DateTime for timestamps).
  Automatically computes the session and date fields from the timestamp.

  ## Parameters

    * `symbol` - The stock symbol as a string
    * `alpaca_bar` - Map containing bar data from Alpaca API with keys:
      - `:timestamp` - DateTime in UTC
      - `:open`, `:high`, `:low`, `:close` - Decimal prices
      - `:volume` - Integer volume
      - `:vwap` - Optional Decimal VWAP
      - `:trade_count` - Optional integer trade count

  ## Returns

  A Bar struct ready for insertion

  ## Examples

      iex> alpaca_bar = %{
      ...>   timestamp: ~U[2024-11-15 14:30:00Z],
      ...>   open: Decimal.new("185.20"),
      ...>   high: Decimal.new("185.60"),
      ...>   low: Decimal.new("184.90"),
      ...>   close: Decimal.new("185.45"),
      ...>   volume: 2_300_000,
      ...>   vwap: Decimal.new("185.32"),
      ...>   trade_count: 150
      ...> }
      iex> Signal.MarketData.Bar.from_alpaca("AAPL", alpaca_bar)
      %Signal.MarketData.Bar{symbol: "AAPL", session: :regular, ...}
  """
  @spec from_alpaca(String.t(), map()) :: t()
  def from_alpaca(symbol, alpaca_bar) do
    bar_time = ensure_usec_precision(alpaca_bar.timestamp)

    %__MODULE__{
      symbol: symbol,
      bar_time: bar_time,
      open: alpaca_bar.open,
      high: alpaca_bar.high,
      low: alpaca_bar.low,
      close: alpaca_bar.close,
      volume: alpaca_bar.volume,
      vwap: Map.get(alpaca_bar, :vwap),
      trade_count: Map.get(alpaca_bar, :trade_count),
      session: session_for_time(bar_time),
      date: date_for_time(bar_time)
    }
  end

  @doc """
  Determines the market session for a given UTC datetime.

  Sessions are based on Eastern Time:
  - `:pre_market` - 4:00 AM to 9:29 AM ET
  - `:regular` - 9:30 AM to 3:59 PM ET
  - `:after_hours` - 4:00 PM to 3:59 AM ET (next day)

  ## Examples

      iex> Signal.MarketData.Bar.session_for_time(~U[2024-11-15 14:30:00Z])
      :regular

      iex> Signal.MarketData.Bar.session_for_time(~U[2024-11-15 12:00:00Z])
      :pre_market
  """
  @spec session_for_time(DateTime.t()) :: :pre_market | :regular | :after_hours
  def session_for_time(utc_datetime) do
    et_time =
      utc_datetime
      |> DateTime.shift_zone!(@timezone)
      |> DateTime.to_time()

    cond do
      time_in_range?(et_time, @pre_market_start, @regular_start) -> :pre_market
      time_in_range?(et_time, @regular_start, @after_hours_start) -> :regular
      true -> :after_hours
    end
  end

  # Returns true if time is >= start and < end_time
  defp time_in_range?(time, start_time, end_time) do
    Time.compare(time, start_time) in [:eq, :gt] and Time.compare(time, end_time) == :lt
  end

  @doc """
  Extracts the trading date (in Eastern Time) from a UTC datetime.

  ## Examples

      iex> Signal.MarketData.Bar.date_for_time(~U[2024-11-15 14:30:00Z])
      ~D[2024-11-15]

      # Late night UTC is still same ET day
      iex> Signal.MarketData.Bar.date_for_time(~U[2024-11-16 03:00:00Z])
      ~D[2024-11-15]
  """
  @spec date_for_time(DateTime.t()) :: Date.t()
  def date_for_time(utc_datetime) do
    utc_datetime
    |> DateTime.shift_zone!(@timezone)
    |> DateTime.to_date()
  end

  # Ensures DateTime has microsecond precision (required by :utc_datetime_usec)
  defp ensure_usec_precision(%DateTime{microsecond: {usec, _}} = dt) do
    %{dt | microsecond: {usec, 6}}
  end

  @doc """
  Converts a Bar struct to a plain map.

  Useful for batch inserts or serialization.

  ## Parameters

    * `bar` - A Bar struct

  ## Returns

  A map with all bar fields

  ## Examples

      iex> bar = %Signal.MarketData.Bar{symbol: "AAPL", ...}
      iex> Signal.MarketData.Bar.to_map(bar)
      %{symbol: "AAPL", bar_time: ~U[...], ...}
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = bar) do
    bar
    |> Map.from_struct()
    |> Map.drop([:__meta__])
  end

  @typedoc """
  Type specification for a market bar
  """
  @type t :: %__MODULE__{
          symbol: String.t(),
          bar_time: DateTime.t(),
          open: Decimal.t(),
          high: Decimal.t(),
          low: Decimal.t(),
          close: Decimal.t(),
          volume: integer(),
          vwap: Decimal.t() | nil,
          trade_count: integer() | nil,
          session: :pre_market | :regular | :after_hours,
          date: Date.t()
        }
end
