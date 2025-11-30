defmodule Signal.Instruments.Resolver do
  @moduledoc """
  Resolves trade signals to tradeable instruments.

  The Resolver is the core of the instrument abstraction layer. It takes
  a trade signal (with direction, entry price, stop loss, etc.) and
  configuration, then returns the appropriate instrument to trade.

  For equity configuration, it returns an `Equity` struct.
  For options configuration, it selects the appropriate options contract
  based on expiration and strike preferences.

  ## Usage

      # Configure for equity trading
      config = Config.equity()
      {:ok, instrument} = Resolver.resolve(signal, config)
      # => %Equity{symbol: "AAPL", direction: :long, ...}

      # Configure for options trading
      config = Config.options()
      {:ok, instrument} = Resolver.resolve(signal, config)
      # => %OptionsContract{contract_symbol: "AAPL250117C00150000", ...}

  ## Error Handling

  The resolver can return errors in several cases:
    * `:missing_signal_field` - Signal is missing required fields
    * `:no_expiration_found` - No suitable expiration date available
    * `:no_contract_found` - No contract matches the criteria
    * `:options_data_unavailable` - Options price data not available
  """

  require Logger

  alias Signal.Instruments.Config
  alias Signal.Instruments.Equity
  alias Signal.Instruments.OptionsContract
  alias Signal.Options.ContractDiscovery

  @doc """
  Resolves a signal to a tradeable instrument based on configuration.

  ## Parameters

    * `signal` - A trade signal map with at minimum:
      - `:symbol` - The underlying symbol
      - `:direction` - `:long` or `:short`
      - `:entry_price` - Entry price level
      - `:stop_loss` - Stop loss price level
      - `:generated_at` - DateTime when signal was generated (for options)
    * `config` - An `%Config{}` struct

  ## Returns

    * `{:ok, instrument}` - An `Equity` or `OptionsContract` struct
    * `{:error, reason}` - Error details

  ## Examples

      signal = %{
        symbol: "AAPL",
        direction: :long,
        entry_price: Decimal.new("150.00"),
        stop_loss: Decimal.new("145.00"),
        take_profit: Decimal.new("160.00"),
        generated_at: ~U[2024-06-15 14:30:00Z]
      }

      # Resolve to equity
      {:ok, equity} = Resolver.resolve(signal, Config.equity())

      # Resolve to options
      {:ok, option} = Resolver.resolve(signal, Config.options())
  """
  @spec resolve(map(), Config.t()) :: {:ok, Equity.t() | OptionsContract.t()} | {:error, any()}
  def resolve(signal, %Config{instrument_type: :equity}) do
    resolve_equity(signal)
  end

  def resolve(signal, %Config{instrument_type: :options} = config) do
    resolve_options(signal, config)
  end

  @doc """
  Resolves a signal to an equity instrument.

  This is a simple wrapper around `Equity.from_signal/1`.
  """
  @spec resolve_equity(map()) :: {:ok, Equity.t()} | {:error, any()}
  def resolve_equity(signal) do
    Equity.from_signal(signal)
  end

  @doc """
  Resolves a signal to an options instrument.

  This involves:
  1. Determining call vs put from signal direction
  2. Finding the appropriate expiration date
  3. Selecting the strike price
  4. Looking up the contract in the database
  5. Building the `OptionsContract` struct

  Note: This function requires contracts to be synced via `ContractDiscovery`
  and does NOT fetch options price data. Price simulation should be done
  separately after resolution.
  """
  @spec resolve_options(map(), Config.t()) :: {:ok, OptionsContract.t()} | {:error, any()}
  def resolve_options(signal, config) do
    with {:ok, symbol} <- fetch_field(signal, :symbol),
         {:ok, direction} <- fetch_direction(signal),
         {:ok, entry_price} <- fetch_decimal(signal, :entry_price),
         {:ok, signal_date} <- get_signal_date(signal),
         contract_type <- direction_to_contract_type(direction),
         {:ok, expiration} <- find_expiration(symbol, signal_date, config),
         {:ok, strike} <- select_strike(entry_price, contract_type, config),
         {:ok, contract} <- find_contract(symbol, expiration, contract_type, strike) do
      build_options_instrument(contract)
    end
  end

  @doc """
  Determines the appropriate contract type based on signal direction.

  * `:long` signals → buy calls (bullish)
  * `:short` signals → buy puts (bearish)
  """
  @spec direction_to_contract_type(:long | :short) :: :call | :put
  def direction_to_contract_type(:long), do: :call
  def direction_to_contract_type(:short), do: :put

  @doc """
  Calculates the strike selection based on configuration.

  Returns the appropriate strike price based on the underlying price
  and strike selection preference (ATM, 1 OTM, 2 OTM).
  """
  @spec select_strike(Decimal.t(), :call | :put, Config.t()) :: {:ok, Decimal.t()}
  def select_strike(underlying_price, contract_type, config) do
    atm_strike = round_to_nearest_strike(underlying_price)
    increment = strike_increment(underlying_price)

    strike =
      case {config.strike_selection, contract_type} do
        {:atm, _} ->
          atm_strike

        {:one_otm, :call} ->
          Decimal.add(atm_strike, increment)

        {:one_otm, :put} ->
          Decimal.sub(atm_strike, increment)

        {:two_otm, :call} ->
          Decimal.add(atm_strike, Decimal.mult(increment, 2))

        {:two_otm, :put} ->
          Decimal.sub(atm_strike, Decimal.mult(increment, 2))
      end

    {:ok, strike}
  end

  @doc """
  Rounds a price to the nearest standard strike price.

  Strike prices follow standard intervals:
  - Under $50: $1 increments
  - $50-$200: $5 increments
  - Over $200: $10 increments
  """
  @spec round_to_nearest_strike(Decimal.t()) :: Decimal.t()
  def round_to_nearest_strike(price) do
    increment = strike_increment(price)

    price
    |> Decimal.div(increment)
    |> Decimal.round(0)
    |> Decimal.mult(increment)
  end

  @doc """
  Returns the standard strike increment for a given price level.
  """
  @spec strike_increment(Decimal.t()) :: Decimal.t()
  def strike_increment(price) do
    cond do
      Decimal.lt?(price, Decimal.new(50)) -> Decimal.new(1)
      Decimal.lt?(price, Decimal.new(200)) -> Decimal.new(5)
      true -> Decimal.new(10)
    end
  end

  # Private Functions

  defp fetch_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when not is_nil(value) -> {:ok, value}
      _ -> {:error, {:missing_signal_field, key}}
    end
  end

  defp fetch_direction(map) do
    case Map.get(map, :direction) do
      :long -> {:ok, :long}
      :short -> {:ok, :short}
      "long" -> {:ok, :long}
      "short" -> {:ok, :short}
      nil -> {:error, {:missing_signal_field, :direction}}
      other -> {:error, {:invalid_direction, other}}
    end
  end

  defp fetch_decimal(map, key) do
    case Map.fetch(map, key) do
      {:ok, %Decimal{} = value} -> {:ok, value}
      {:ok, value} when is_number(value) -> {:ok, Decimal.new(to_string(value))}
      {:ok, value} when is_binary(value) -> {:ok, Decimal.new(value)}
      _ -> {:error, {:missing_signal_field, key}}
    end
  end

  defp get_signal_date(signal) do
    case Map.get(signal, :generated_at) do
      %DateTime{} = dt -> {:ok, DateTime.to_date(dt)}
      %Date{} = d -> {:ok, d}
      nil -> {:ok, Date.utc_today()}
    end
  end

  defp find_expiration(symbol, signal_date, config) do
    case config.expiration_preference do
      :weekly ->
        ContractDiscovery.find_nearest_weekly(symbol, signal_date)

      :zero_dte ->
        case ContractDiscovery.find_0dte(symbol, signal_date) do
          {:ok, _} = success ->
            success

          {:error, :no_0dte_available} ->
            Logger.debug(
              "[Resolver] No 0DTE for #{symbol} on #{signal_date}, falling back to weekly"
            )

            ContractDiscovery.find_nearest_weekly(symbol, signal_date)
        end
    end
  end

  defp find_contract(symbol, expiration, contract_type, target_strike) do
    # First try exact match
    case ContractDiscovery.find_contract(symbol, expiration, contract_type, target_strike) do
      {:ok, _} = success ->
        success

      {:error, :not_found} ->
        # Fall back to nearest available strike
        find_nearest_contract(symbol, expiration, contract_type, target_strike)
    end
  end

  defp find_nearest_contract(symbol, expiration, contract_type, target_strike) do
    contracts =
      ContractDiscovery.find_contracts_near_strike(
        symbol,
        expiration,
        contract_type,
        target_strike,
        range: Decimal.new(20),
        limit: 1
      )

    case contracts do
      [contract | _] -> {:ok, contract}
      [] -> {:error, :no_contract_found}
    end
  end

  defp build_options_instrument(contract) do
    OptionsContract.new(%{
      underlying_symbol: contract.underlying_symbol,
      contract_symbol: contract.symbol,
      contract_type: String.to_existing_atom(contract.contract_type),
      strike: contract.strike_price,
      expiration: contract.expiration_date,
      # Placeholder - actual premium should be set by price simulator
      entry_premium: Decimal.new(0)
    })
  end
end
