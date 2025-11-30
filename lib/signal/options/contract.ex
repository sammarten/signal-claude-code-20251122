defmodule Signal.Options.Contract do
  @moduledoc """
  Ecto schema for options contracts stored in the options_contracts table.

  Represents metadata about an options contract including underlying symbol,
  expiration date, strike price, and contract type (call/put).

  ## Fields

    * `:symbol` - OSI format contract symbol (e.g., "AAPL251017C00150000")
    * `:underlying_symbol` - The underlying stock symbol (e.g., "AAPL")
    * `:expiration_date` - The contract expiration date
    * `:strike_price` - The strike price
    * `:contract_type` - Either "call" or "put"
    * `:status` - Contract status: "active" or "expired"

  ## Examples

      iex> contract = %Signal.Options.Contract{
      ...>   symbol: "AAPL251017C00150000",
      ...>   underlying_symbol: "AAPL",
      ...>   expiration_date: ~D[2025-10-17],
      ...>   strike_price: Decimal.new("150.00"),
      ...>   contract_type: "call",
      ...>   status: "active"
      ...> }
      iex> Signal.Repo.insert(contract)
      {:ok, %Signal.Options.Contract{}}
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Signal.Options.OSI

  @type contract_type :: :call | :put
  @type status :: :active | :expired

  @primary_key {:symbol, :string, autogenerate: false}
  @foreign_key_type :string

  schema "options_contracts" do
    field :underlying_symbol, :string
    field :expiration_date, :date
    field :strike_price, :decimal
    field :contract_type, :string
    field :status, :string, default: "active"

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:symbol, :underlying_symbol, :expiration_date, :strike_price, :contract_type]
  @optional_fields [:status]
  @valid_contract_types ["call", "put"]
  @valid_statuses ["active", "expired"]

  @doc """
  Creates a changeset for a contract with validation.

  Validates:
  - Required fields: symbol, underlying_symbol, expiration_date, strike_price, contract_type
  - Contract type must be "call" or "put"
  - Status must be "active" or "expired"
  - Strike price must be positive

  ## Parameters

    * `contract` - The contract struct to validate
    * `attrs` - Map of attributes to apply

  ## Returns

  An Ecto.Changeset struct

  ## Examples

      iex> changeset = Signal.Options.Contract.changeset(%Signal.Options.Contract{}, %{
      ...>   symbol: "AAPL251017C00150000",
      ...>   underlying_symbol: "AAPL",
      ...>   expiration_date: ~D[2025-10-17],
      ...>   strike_price: Decimal.new("150.00"),
      ...>   contract_type: "call"
      ...> })
      iex> changeset.valid?
      true
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(contract, attrs) do
    contract
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:contract_type, @valid_contract_types)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_number(:strike_price, greater_than: 0)
    |> unique_constraint(:symbol, name: :options_contracts_pkey)
  end

  @doc """
  Creates a Contract struct from Alpaca API response.

  ## Parameters

    * `alpaca_contract` - Map containing contract data from Alpaca API with keys:
      - `"symbol"` - OSI format symbol
      - `"underlying_symbol"` - Underlying stock symbol
      - `"expiration_date"` - Expiration date string (YYYY-MM-DD)
      - `"strike_price"` - Strike price as string or number
      - `"type"` - "call" or "put"
      - `"status"` - Optional, defaults to "active"

  ## Returns

  A Contract struct ready for insertion

  ## Examples

      iex> alpaca_contract = %{
      ...>   "symbol" => "AAPL251017C00150000",
      ...>   "underlying_symbol" => "AAPL",
      ...>   "expiration_date" => "2025-10-17",
      ...>   "strike_price" => "150.00",
      ...>   "type" => "call"
      ...> }
      iex> Signal.Options.Contract.from_alpaca(alpaca_contract)
      %Signal.Options.Contract{symbol: "AAPL251017C00150000", ...}
  """
  @spec from_alpaca(map()) :: t()
  def from_alpaca(alpaca_contract) do
    %__MODULE__{
      symbol: alpaca_contract["symbol"],
      underlying_symbol: alpaca_contract["underlying_symbol"],
      expiration_date: parse_date(alpaca_contract["expiration_date"]),
      strike_price: parse_decimal(alpaca_contract["strike_price"]),
      contract_type: alpaca_contract["type"],
      status: Map.get(alpaca_contract, "status", "active")
    }
  end

  @doc """
  Builds an OSI symbol for a contract.

  ## Parameters

    * `underlying` - The underlying symbol
    * `expiration` - The expiration date
    * `contract_type` - :call or :put
    * `strike` - The strike price

  ## Returns

  The OSI format symbol string
  """
  @spec build_symbol(String.t(), Date.t(), contract_type(), Decimal.t() | number()) :: String.t()
  def build_symbol(underlying, expiration, contract_type, strike) do
    OSI.build(underlying, expiration, contract_type, strike)
  end

  @doc """
  Returns the contract type as an atom.

  ## Examples

      iex> contract = %Signal.Options.Contract{contract_type: "call"}
      iex> Signal.Options.Contract.contract_type_atom(contract)
      :call
  """
  @spec contract_type_atom(t()) :: contract_type()
  def contract_type_atom(%__MODULE__{contract_type: "call"}), do: :call
  def contract_type_atom(%__MODULE__{contract_type: "put"}), do: :put

  @doc """
  Returns true if the contract is a call option.
  """
  @spec call?(t()) :: boolean()
  def call?(%__MODULE__{contract_type: "call"}), do: true
  def call?(_), do: false

  @doc """
  Returns true if the contract is a put option.
  """
  @spec put?(t()) :: boolean()
  def put?(%__MODULE__{contract_type: "put"}), do: true
  def put?(_), do: false

  @doc """
  Returns true if the contract has expired.
  """
  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{status: "expired"}), do: true

  def expired?(%__MODULE__{expiration_date: exp_date}) do
    Date.compare(exp_date, Date.utc_today()) == :lt
  end

  @doc """
  Returns the number of days until expiration.

  Returns 0 for expired contracts.
  """
  @spec days_to_expiration(t()) :: non_neg_integer()
  def days_to_expiration(%__MODULE__{expiration_date: exp_date}) do
    days = Date.diff(exp_date, Date.utc_today())
    max(days, 0)
  end

  # Private helpers

  defp parse_date(date) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, d} -> d
      _ -> nil
    end
  end

  defp parse_date(%Date{} = date), do: date
  defp parse_date(_), do: nil

  defp parse_decimal(value) when is_binary(value), do: Decimal.new(value)
  defp parse_decimal(value) when is_number(value), do: Decimal.new(to_string(value))
  defp parse_decimal(%Decimal{} = value), do: value
  defp parse_decimal(_), do: nil

  @typedoc """
  Type specification for an options contract
  """
  @type t :: %__MODULE__{
          symbol: String.t(),
          underlying_symbol: String.t(),
          expiration_date: Date.t(),
          strike_price: Decimal.t(),
          contract_type: String.t(),
          status: String.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }
end
