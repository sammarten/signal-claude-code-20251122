defmodule Signal.Instruments.Equity do
  @moduledoc """
  Represents an equity (stock/ETF) instrument for trading.

  This is a thin wrapper around the existing equity trading flow,
  maintaining backward compatibility while enabling the instrument
  abstraction for options integration.

  ## Fields

    * `:symbol` - The stock/ETF symbol (e.g., "AAPL")
    * `:direction` - Trade direction: `:long` or `:short`
    * `:entry_price` - Proposed entry price
    * `:stop_loss` - Stop loss price
    * `:take_profit` - Take profit target (optional)
    * `:quantity` - Number of shares (set by position sizer)

  ## Examples

      equity = %Equity{
        symbol: "AAPL",
        direction: :long,
        entry_price: Decimal.new("150.00"),
        stop_loss: Decimal.new("145.00"),
        take_profit: Decimal.new("160.00")
      }

      # Protocol usage
      Instrument.symbol(equity)           # => "AAPL"
      Instrument.instrument_type(equity)  # => :equity
      Instrument.multiplier(equity)       # => 1
  """

  alias Signal.Instruments.Instrument

  @type direction :: :long | :short

  @type t :: %__MODULE__{
          symbol: String.t(),
          direction: direction(),
          entry_price: Decimal.t(),
          stop_loss: Decimal.t(),
          take_profit: Decimal.t() | nil,
          quantity: non_neg_integer() | nil
        }

  @enforce_keys [:symbol, :direction, :entry_price, :stop_loss]
  defstruct [
    :symbol,
    :direction,
    :entry_price,
    :stop_loss,
    :take_profit,
    :quantity
  ]

  @doc """
  Creates a new Equity instrument from a trade signal.

  ## Parameters

    * `signal` - A trade signal map with `:symbol`, `:direction`, `:entry_price`,
      `:stop_loss`, and optionally `:take_profit`

  ## Returns

    * `{:ok, %Equity{}}` - The equity instrument
    * `{:error, reason}` - If required fields are missing

  ## Examples

      signal = %{
        symbol: "AAPL",
        direction: :long,
        entry_price: Decimal.new("150.00"),
        stop_loss: Decimal.new("145.00"),
        take_profit: Decimal.new("160.00")
      }

      {:ok, equity} = Equity.from_signal(signal)
  """
  @spec from_signal(map()) :: {:ok, t()} | {:error, atom()}
  def from_signal(signal) do
    with {:ok, symbol} <- fetch_field(signal, :symbol),
         {:ok, direction} <- fetch_direction(signal),
         {:ok, entry_price} <- fetch_decimal_field(signal, :entry_price),
         {:ok, stop_loss} <- fetch_decimal_field(signal, :stop_loss) do
      {:ok,
       %__MODULE__{
         symbol: symbol,
         direction: direction,
         entry_price: entry_price,
         stop_loss: stop_loss,
         take_profit: get_decimal_field(signal, :take_profit)
       }}
    end
  end

  @doc """
  Creates a new Equity instrument, raising on error.
  """
  @spec from_signal!(map()) :: t()
  def from_signal!(signal) do
    case from_signal(signal) do
      {:ok, equity} -> equity
      {:error, reason} -> raise ArgumentError, "Invalid signal: #{inspect(reason)}"
    end
  end

  @doc """
  Calculates the risk per share (distance from entry to stop).

  ## Examples

      equity = %Equity{entry_price: Decimal.new("150"), stop_loss: Decimal.new("145"), ...}
      Equity.risk_per_share(equity)  # => Decimal.new("5")
  """
  @spec risk_per_share(t()) :: Decimal.t()
  def risk_per_share(%__MODULE__{direction: :long, entry_price: entry, stop_loss: stop}) do
    Decimal.sub(entry, stop) |> Decimal.abs()
  end

  def risk_per_share(%__MODULE__{direction: :short, entry_price: entry, stop_loss: stop}) do
    Decimal.sub(stop, entry) |> Decimal.abs()
  end

  @doc """
  Calculates risk/reward ratio.

  ## Returns

    * `{:ok, ratio}` - The R:R ratio as a Decimal
    * `{:error, :no_target}` - If take_profit is not set
  """
  @spec risk_reward(t()) :: {:ok, Decimal.t()} | {:error, :no_target}
  def risk_reward(%__MODULE__{take_profit: nil}), do: {:error, :no_target}

  def risk_reward(%__MODULE__{direction: :long} = equity) do
    risk = risk_per_share(equity)
    reward = Decimal.sub(equity.take_profit, equity.entry_price)

    if Decimal.gt?(risk, Decimal.new(0)) do
      {:ok, Decimal.div(reward, risk)}
    else
      {:error, :invalid_risk}
    end
  end

  def risk_reward(%__MODULE__{direction: :short} = equity) do
    risk = risk_per_share(equity)
    reward = Decimal.sub(equity.entry_price, equity.take_profit)

    if Decimal.gt?(risk, Decimal.new(0)) do
      {:ok, Decimal.div(reward, risk)}
    else
      {:error, :invalid_risk}
    end
  end

  @doc """
  Sets the quantity (number of shares) on the instrument.
  """
  @spec with_quantity(t(), non_neg_integer()) :: t()
  def with_quantity(%__MODULE__{} = equity, quantity)
      when is_integer(quantity) and quantity >= 0 do
    %{equity | quantity: quantity}
  end

  # Private helpers

  defp fetch_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when not is_nil(value) -> {:ok, value}
      _ -> {:error, {:missing_field, key}}
    end
  end

  defp fetch_direction(map) do
    case Map.get(map, :direction) do
      :long -> {:ok, :long}
      :short -> {:ok, :short}
      "long" -> {:ok, :long}
      "short" -> {:ok, :short}
      nil -> {:error, {:missing_field, :direction}}
      other -> {:error, {:invalid_direction, other}}
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

  defp get_decimal_field(map, key) do
    case Map.get(map, key) do
      %Decimal{} = value -> value
      value when is_number(value) -> Decimal.new(to_string(value))
      value when is_binary(value) -> Decimal.new(value)
      _ -> nil
    end
  end

  # Protocol implementation
  defimpl Instrument do
    def symbol(%{symbol: symbol}), do: symbol
    def underlying_symbol(%{symbol: symbol}), do: symbol
    def instrument_type(_), do: :equity
    def direction(%{direction: dir}), do: dir
    def entry_value(%{entry_price: price}), do: price
    def multiplier(_), do: 1
  end
end
