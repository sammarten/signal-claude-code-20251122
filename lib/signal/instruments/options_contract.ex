defmodule Signal.Instruments.OptionsContract do
  @moduledoc """
  Represents an options contract instrument for trading.

  Options contracts are derived from underlying stock signals. When a signal
  indicates a bullish setup, we buy calls; for bearish setups, we buy puts.

  ## Fields

    * `:underlying_symbol` - The underlying stock symbol (e.g., "AAPL")
    * `:contract_symbol` - OSI format symbol (e.g., "AAPL250117C00150000")
    * `:contract_type` - `:call` or `:put`
    * `:strike` - Strike price
    * `:expiration` - Expiration date
    * `:direction` - Always `:long` (we only buy options)
    * `:entry_premium` - Premium per share at entry
    * `:quantity` - Number of contracts (set by position sizer)

  ## Examples

      option = %OptionsContract{
        underlying_symbol: "AAPL",
        contract_symbol: "AAPL250117C00150000",
        contract_type: :call,
        strike: Decimal.new("150.00"),
        expiration: ~D[2025-01-17],
        direction: :long,
        entry_premium: Decimal.new("5.25")
      }

      # Protocol usage
      Instrument.symbol(option)           # => "AAPL250117C00150000"
      Instrument.underlying_symbol(option) # => "AAPL"
      Instrument.instrument_type(option)  # => :options
      Instrument.multiplier(option)       # => 100
  """

  alias Signal.Instruments.Instrument

  @contract_multiplier 100

  @type contract_type :: :call | :put

  @type t :: %__MODULE__{
          underlying_symbol: String.t(),
          contract_symbol: String.t(),
          contract_type: contract_type(),
          strike: Decimal.t(),
          expiration: Date.t(),
          direction: :long,
          entry_premium: Decimal.t(),
          quantity: non_neg_integer() | nil
        }

  @enforce_keys [
    :underlying_symbol,
    :contract_symbol,
    :contract_type,
    :strike,
    :expiration,
    :entry_premium
  ]
  defstruct [
    :underlying_symbol,
    :contract_symbol,
    :contract_type,
    :strike,
    :expiration,
    :entry_premium,
    direction: :long,
    quantity: nil
  ]

  @doc """
  Creates a new OptionsContract instrument.

  ## Parameters

    * `attrs` - Map with required fields:
      - `:underlying_symbol` - Underlying stock symbol
      - `:contract_symbol` - OSI format contract symbol
      - `:contract_type` - `:call` or `:put`
      - `:strike` - Strike price
      - `:expiration` - Expiration date
      - `:entry_premium` - Premium per share

  ## Returns

    * `{:ok, %OptionsContract{}}` - The options instrument
    * `{:error, reason}` - If required fields are missing

  ## Examples

      {:ok, option} = OptionsContract.new(%{
        underlying_symbol: "AAPL",
        contract_symbol: "AAPL250117C00150000",
        contract_type: :call,
        strike: Decimal.new("150"),
        expiration: ~D[2025-01-17],
        entry_premium: Decimal.new("5.25")
      })
  """
  @spec new(map()) :: {:ok, t()} | {:error, atom()}
  def new(attrs) do
    with {:ok, underlying} <- fetch_field(attrs, :underlying_symbol),
         {:ok, contract_symbol} <- fetch_field(attrs, :contract_symbol),
         {:ok, contract_type} <- fetch_contract_type(attrs),
         {:ok, strike} <- fetch_decimal_field(attrs, :strike),
         {:ok, expiration} <- fetch_date_field(attrs, :expiration),
         {:ok, entry_premium} <- fetch_decimal_field(attrs, :entry_premium) do
      {:ok,
       %__MODULE__{
         underlying_symbol: underlying,
         contract_symbol: contract_symbol,
         contract_type: contract_type,
         strike: strike,
         expiration: expiration,
         entry_premium: entry_premium,
         direction: :long
       }}
    end
  end

  @doc """
  Creates a new OptionsContract, raising on error.
  """
  @spec new!(map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, option} -> option
      {:error, reason} -> raise ArgumentError, "Invalid options contract: #{inspect(reason)}"
    end
  end

  @doc """
  Calculates the total entry cost for the position.

  Entry cost = premium * 100 * quantity

  ## Examples

      option = %OptionsContract{entry_premium: Decimal.new("5.25"), quantity: 2, ...}
      OptionsContract.entry_cost(option)  # => Decimal.new("1050")
  """
  @spec entry_cost(t()) :: Decimal.t()
  def entry_cost(%__MODULE__{entry_premium: premium, quantity: nil}) do
    Decimal.mult(premium, @contract_multiplier)
  end

  def entry_cost(%__MODULE__{entry_premium: premium, quantity: qty}) do
    premium
    |> Decimal.mult(@contract_multiplier)
    |> Decimal.mult(qty)
  end

  @doc """
  Returns true if this is a call option.
  """
  @spec call?(t()) :: boolean()
  def call?(%__MODULE__{contract_type: :call}), do: true
  def call?(_), do: false

  @doc """
  Returns true if this is a put option.
  """
  @spec put?(t()) :: boolean()
  def put?(%__MODULE__{contract_type: :put}), do: true
  def put?(_), do: false

  @doc """
  Returns the number of days until expiration.
  """
  @spec days_to_expiration(t()) :: non_neg_integer()
  def days_to_expiration(%__MODULE__{expiration: exp}) do
    days = Date.diff(exp, Date.utc_today())
    max(days, 0)
  end

  @doc """
  Returns true if the contract has expired.
  """
  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{} = option) do
    days_to_expiration(option) == 0 and Date.compare(option.expiration, Date.utc_today()) == :lt
  end

  @doc """
  Calculates if the option is in-the-money, at-the-money, or out-of-the-money
  relative to a given underlying price.

  ## Returns

    * `:itm` - In the money
    * `:atm` - At the money (within 1% of strike)
    * `:otm` - Out of the money
  """
  @spec moneyness(t(), Decimal.t()) :: :itm | :atm | :otm
  def moneyness(%__MODULE__{contract_type: :call, strike: strike}, underlying_price) do
    diff_pct =
      underlying_price
      |> Decimal.sub(strike)
      |> Decimal.div(strike)
      |> Decimal.abs()

    cond do
      Decimal.lt?(diff_pct, Decimal.new("0.01")) -> :atm
      Decimal.gt?(underlying_price, strike) -> :itm
      true -> :otm
    end
  end

  def moneyness(%__MODULE__{contract_type: :put, strike: strike}, underlying_price) do
    diff_pct =
      underlying_price
      |> Decimal.sub(strike)
      |> Decimal.div(strike)
      |> Decimal.abs()

    cond do
      Decimal.lt?(diff_pct, Decimal.new("0.01")) -> :atm
      Decimal.lt?(underlying_price, strike) -> :itm
      true -> :otm
    end
  end

  @doc """
  Sets the quantity (number of contracts) on the instrument.
  """
  @spec with_quantity(t(), non_neg_integer()) :: t()
  def with_quantity(%__MODULE__{} = option, quantity)
      when is_integer(quantity) and quantity >= 0 do
    %{option | quantity: quantity}
  end

  @doc """
  Returns the contract multiplier (100 for standard equity options).
  """
  @spec contract_multiplier() :: pos_integer()
  def contract_multiplier, do: @contract_multiplier

  # Private helpers

  defp fetch_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when not is_nil(value) -> {:ok, value}
      _ -> {:error, {:missing_field, key}}
    end
  end

  defp fetch_contract_type(map) do
    case Map.get(map, :contract_type) do
      :call -> {:ok, :call}
      :put -> {:ok, :put}
      "call" -> {:ok, :call}
      "put" -> {:ok, :put}
      nil -> {:error, {:missing_field, :contract_type}}
      other -> {:error, {:invalid_contract_type, other}}
    end
  end

  defp fetch_decimal_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, %Decimal{} = value} -> {:ok, value}
      {:ok, value} when is_number(value) -> {:ok, Decimal.new(to_string(value))}
      {:ok, value} when is_binary(value) -> {:ok, Decimal.new(value)}
      _ -> {:error, {:missing_field, key}}
    end
  end

  defp fetch_date_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, %Date{} = value} -> {:ok, value}
      {:ok, value} when is_binary(value) -> Date.from_iso8601(value)
      _ -> {:error, {:missing_field, key}}
    end
  end

  # Protocol implementation
  defimpl Instrument do
    def symbol(%{contract_symbol: symbol}), do: symbol
    def underlying_symbol(%{underlying_symbol: symbol}), do: symbol
    def instrument_type(_), do: :options
    def direction(%{direction: dir}), do: dir
    def entry_value(%{entry_premium: premium}), do: premium
    def multiplier(_), do: 100
  end
end
