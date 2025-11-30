defprotocol Signal.Instruments.Instrument do
  @moduledoc """
  Protocol for tradeable instruments.

  This protocol defines a common interface for different instrument types
  (equity, options) allowing strategies and the backtesting engine to work
  with instruments in a uniform way.

  ## Implementations

    * `Signal.Instruments.Equity` - Direct stock/ETF trades
    * `Signal.Instruments.OptionsContract` - Options contracts

  ## Protocol Functions

    * `symbol/1` - The tradeable symbol (OSI format for options)
    * `underlying_symbol/1` - The underlying stock symbol
    * `instrument_type/1` - Returns `:equity` or `:options`
    * `direction/1` - Trade direction (`:long` or `:short`)
    * `entry_value/1` - Entry price/premium
    * `multiplier/1` - Contract multiplier (1 for equity, 100 for options)

  ## Examples

      # Equity instrument
      equity = %Equity{symbol: "AAPL", direction: :long, entry_price: Decimal.new("150")}
      Instrument.symbol(equity)           # => "AAPL"
      Instrument.underlying_symbol(equity) # => "AAPL"
      Instrument.instrument_type(equity)   # => :equity
      Instrument.multiplier(equity)        # => 1

      # Options instrument
      option = %OptionsContract{
        contract_symbol: "AAPL250117C00150000",
        underlying_symbol: "AAPL",
        direction: :long,
        entry_premium: Decimal.new("5.25")
      }
      Instrument.symbol(option)           # => "AAPL250117C00150000"
      Instrument.underlying_symbol(option) # => "AAPL"
      Instrument.instrument_type(option)   # => :options
      Instrument.multiplier(option)        # => 100
  """

  @doc """
  Returns the tradeable symbol.

  For equity, this is the stock symbol (e.g., "AAPL").
  For options, this is the OSI format symbol (e.g., "AAPL250117C00150000").
  """
  @spec symbol(t) :: String.t()
  def symbol(instrument)

  @doc """
  Returns the underlying stock symbol.

  For equity, this is the same as `symbol/1`.
  For options, this is the underlying stock (e.g., "AAPL" for AAPL options).
  """
  @spec underlying_symbol(t) :: String.t()
  def underlying_symbol(instrument)

  @doc """
  Returns the instrument type.

  Returns `:equity` for stock/ETF trades, `:options` for options contracts.
  """
  @spec instrument_type(t) :: :equity | :options
  def instrument_type(instrument)

  @doc """
  Returns the trade direction.

  For equity: `:long` (buy) or `:short` (sell short).
  For options: `:long` (buy to open) - we only support buying options.
  """
  @spec direction(t) :: :long | :short
  def direction(instrument)

  @doc """
  Returns the entry value (price for equity, premium for options).
  """
  @spec entry_value(t) :: Decimal.t()
  def entry_value(instrument)

  @doc """
  Returns the contract multiplier.

  Equity returns 1 (1 share = 1 unit).
  Options returns 100 (1 contract = 100 shares).
  """
  @spec multiplier(t) :: pos_integer()
  def multiplier(instrument)
end
