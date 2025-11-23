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

  ## Examples

      iex> bar = %Signal.MarketData.Bar{
      ...>   symbol: "AAPL",
      ...>   bar_time: ~U[2024-11-15 14:30:00Z],
      ...>   open: Decimal.new("185.20"),
      ...>   high: Decimal.new("185.60"),
      ...>   low: Decimal.new("184.90"),
      ...>   close: Decimal.new("185.45"),
      ...>   volume: 2_300_000
      ...> }
      iex> Signal.Repo.insert(bar)
      {:ok, %Signal.MarketData.Bar{}}
  """

  use Ecto.Schema
  import Ecto.Changeset

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
  end

  @doc """
  Creates a changeset for a bar with validation.

  Validates:
  - Required fields: symbol, bar_time, open, high, low, close, volume
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
      ...>   volume: 1000
      ...> })
      iex> changeset.valid?
      true
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(bar, attrs) do
    bar
    |> cast(attrs, [:symbol, :bar_time, :open, :high, :low, :close, :volume, :vwap, :trade_count])
    |> validate_required([:symbol, :bar_time, :open, :high, :low, :close, :volume])
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
      %Signal.MarketData.Bar{symbol: "AAPL", ...}
  """
  @spec from_alpaca(String.t(), map()) :: t()
  def from_alpaca(symbol, alpaca_bar) do
    %__MODULE__{
      symbol: symbol,
      bar_time: alpaca_bar.timestamp,
      open: alpaca_bar.open,
      high: alpaca_bar.high,
      low: alpaca_bar.low,
      close: alpaca_bar.close,
      volume: alpaca_bar.volume,
      vwap: Map.get(alpaca_bar, :vwap),
      trade_count: Map.get(alpaca_bar, :trade_count)
    }
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
    Map.from_struct(bar)
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
          trade_count: integer() | nil
        }
end
