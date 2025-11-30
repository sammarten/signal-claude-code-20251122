defmodule Signal.Options.Bar do
  @moduledoc """
  Ecto schema for options 1-minute bars stored in TimescaleDB hypertable.

  Represents OHLCV (Open, High, Low, Close, Volume) data for an options contract
  at a specific timestamp. Uses a composite primary key of (symbol, bar_time)
  for efficient time-series queries.

  ## Fields

    * `:symbol` - OSI format contract symbol (e.g., "AAPL251017C00150000")
    * `:bar_time` - Timestamp of the bar in UTC
    * `:open` - Opening premium price
    * `:high` - Highest premium during the bar
    * `:low` - Lowest premium during the bar
    * `:close` - Closing premium price
    * `:volume` - Total contracts traded
    * `:vwap` - Volume-weighted average price (optional)
    * `:trade_count` - Number of trades (optional)

  ## Important Notes

  - Options data is only available from February 2024 onward
  - Prices are per-share premium (multiply by 100 for contract value)
  - Volume represents number of contracts, not shares

  ## Examples

      iex> bar = %Signal.Options.Bar{
      ...>   symbol: "AAPL251017C00150000",
      ...>   bar_time: ~U[2024-11-15 14:30:00Z],
      ...>   open: Decimal.new("5.20"),
      ...>   high: Decimal.new("5.60"),
      ...>   low: Decimal.new("4.90"),
      ...>   close: Decimal.new("5.45"),
      ...>   volume: 2300
      ...> }
      iex> Signal.Repo.insert(bar)
      {:ok, %Signal.Options.Bar{}}
  """

  use Ecto.Schema
  import Ecto.Changeset

  @options_data_start_date ~D[2024-02-01]

  @primary_key false
  schema "options_bars" do
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

  @required_fields [:symbol, :bar_time]
  @optional_fields [:open, :high, :low, :close, :volume, :vwap, :trade_count]

  @doc """
  Creates a changeset for an options bar with validation.

  Validates:
  - Required fields: symbol, bar_time
  - OHLC relationships if prices present: high >= open/close, low <= open/close
  - Volume and trade_count are non-negative if present

  ## Parameters

    * `bar` - The bar struct to validate
    * `attrs` - Map of attributes to apply

  ## Returns

  An Ecto.Changeset struct
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(bar, attrs) do
    bar
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_ohlc_relationships()
    |> validate_number(:volume, greater_than_or_equal_to: 0)
    |> validate_number(:trade_count, greater_than_or_equal_to: 0)
  end

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
  Converts an Alpaca API options bar response to a Bar struct.

  Maps Alpaca's field names to the schema fields and converts the data
  to appropriate types (Decimal for prices, DateTime for timestamps).

  ## Parameters

    * `symbol` - The OSI format contract symbol
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
      ...>   open: Decimal.new("5.20"),
      ...>   high: Decimal.new("5.60"),
      ...>   low: Decimal.new("4.90"),
      ...>   close: Decimal.new("5.45"),
      ...>   volume: 2300
      ...> }
      iex> Signal.Options.Bar.from_alpaca("AAPL251017C00150000", alpaca_bar)
      %Signal.Options.Bar{symbol: "AAPL251017C00150000", ...}
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
      trade_count: Map.get(alpaca_bar, :trade_count)
    }
  end

  @doc """
  Returns the earliest date that options data is available.

  Alpaca options bar data is only available from February 2024 onward.
  """
  @spec data_start_date() :: Date.t()
  def data_start_date, do: @options_data_start_date

  @doc """
  Checks if a given date has options data available.

  ## Examples

      iex> Signal.Options.Bar.data_available?(~D[2024-06-15])
      true

      iex> Signal.Options.Bar.data_available?(~D[2023-12-01])
      false
  """
  @spec data_available?(Date.t()) :: boolean()
  def data_available?(date) do
    Date.compare(date, @options_data_start_date) != :lt
  end

  @doc """
  Checks if a given datetime has options data available.
  """
  @spec data_available_at?(DateTime.t()) :: boolean()
  def data_available_at?(datetime) do
    data_available?(DateTime.to_date(datetime))
  end

  @doc """
  Calculates the contract value from a premium price.

  Options contracts are for 100 shares, so the contract value
  is premium * 100.

  ## Examples

      iex> Signal.Options.Bar.contract_value(Decimal.new("5.25"))
      Decimal.new("525")
  """
  @spec contract_value(Decimal.t()) :: Decimal.t()
  def contract_value(premium) do
    Decimal.mult(premium, Decimal.new(100))
  end

  @doc """
  Converts a Bar struct to a plain map.

  Useful for batch inserts or serialization.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = bar) do
    bar
    |> Map.from_struct()
    |> Map.drop([:__meta__])
  end

  # Ensures DateTime has microsecond precision (required by :utc_datetime_usec)
  defp ensure_usec_precision(%DateTime{microsecond: {usec, _}} = dt) do
    %{dt | microsecond: {usec, 6}}
  end

  @typedoc """
  Type specification for an options bar
  """
  @type t :: %__MODULE__{
          symbol: String.t(),
          bar_time: DateTime.t(),
          open: Decimal.t() | nil,
          high: Decimal.t() | nil,
          low: Decimal.t() | nil,
          close: Decimal.t() | nil,
          volume: integer() | nil,
          vwap: Decimal.t() | nil,
          trade_count: integer() | nil
        }
end
