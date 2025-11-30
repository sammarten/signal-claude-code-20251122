defmodule Signal.Options.ContractDiscovery do
  @moduledoc """
  Service for discovering and syncing options contracts from Alpaca.

  This module handles fetching available options contracts from the Alpaca API
  and storing them in the local database for efficient querying during backtesting.

  ## Key Functions

    * `sync_contracts/2` - Fetch and store contracts for an underlying symbol
    * `sync_all/1` - Sync contracts for all configured watchlist symbols
    * `get_available_expirations/2` - Get unique expiration dates for a symbol
    * `find_nearest_weekly/2` - Find the nearest weekly expiration
    * `find_0dte/2` - Find same-day (0DTE) expiration if available
    * `find_contract/4` - Find a specific contract by underlying, expiration, type, strike

  ## Usage

      # Sync contracts for AAPL with 60-day lookahead
      {:ok, count} = ContractDiscovery.sync_contracts("AAPL", days_ahead: 60)

      # Get available expirations for calls
      expirations = ContractDiscovery.get_available_expirations("AAPL", :call)

      # Find nearest weekly expiration
      {:ok, date} = ContractDiscovery.find_nearest_weekly("AAPL", ~D[2024-06-15])

      # Find a specific contract
      {:ok, contract} = ContractDiscovery.find_contract("AAPL", ~D[2024-06-21], :call, Decimal.new("150"))
  """

  require Logger

  alias Signal.Alpaca.Client
  alias Signal.Options.Contract
  alias Signal.Repo

  import Ecto.Query

  @default_days_ahead 60
  @watchlist_symbols ["SPY", "QQQ", "AAPL", "TSLA", "NVDA", "MSFT", "META", "AMZN", "GOOG"]

  # Days of week that typically have 0DTE options for major ETFs
  @zero_dte_days [:monday, :wednesday, :friday]

  @doc """
  Sync options contracts for an underlying symbol from Alpaca.

  Fetches all active contracts within the specified date range and upserts
  them into the local database. Existing contracts are updated, new contracts
  are inserted.

  ## Parameters

    * `underlying_symbol` - The underlying stock symbol (e.g., "AAPL")
    * `opts` - Keyword options:
      - `:days_ahead` - Number of days into the future to fetch (default: 60)
      - `:type` - Filter by contract type: "call", "put", or nil for both

  ## Returns

    * `{:ok, count}` - Number of contracts synced
    * `{:error, reason}` - Error details

  ## Examples

      iex> ContractDiscovery.sync_contracts("AAPL")
      {:ok, 450}

      iex> ContractDiscovery.sync_contracts("SPY", days_ahead: 30, type: "call")
      {:ok, 125}
  """
  @spec sync_contracts(String.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, any()}
  def sync_contracts(underlying_symbol, opts \\ []) do
    days_ahead = Keyword.get(opts, :days_ahead, @default_days_ahead)
    contract_type = Keyword.get(opts, :type)

    today = Date.utc_today()
    end_date = Date.add(today, days_ahead)

    Logger.info(
      "[ContractDiscovery] Syncing #{underlying_symbol} contracts from #{today} to #{end_date}"
    )

    api_opts =
      [
        expiration_date_gte: today,
        expiration_date_lte: end_date,
        status: "active",
        limit: 1000
      ]
      |> maybe_add_type(contract_type)

    case Client.get_options_contracts(underlying_symbol, api_opts) do
      {:ok, contracts} ->
        count = upsert_contracts(contracts)
        Logger.info("[ContractDiscovery] Synced #{count} contracts for #{underlying_symbol}")
        {:ok, count}

      {:error, reason} = error ->
        Logger.error(
          "[ContractDiscovery] Failed to sync #{underlying_symbol}: #{inspect(reason)}"
        )

        error
    end
  end

  @doc """
  Sync contracts for all configured watchlist symbols.

  ## Parameters

    * `opts` - Options passed to `sync_contracts/2`

  ## Returns

    * `{:ok, %{symbol => count}}` - Map of symbols to contract counts
    * `{:error, reason}` - Error details (partial success returns ok with partial counts)

  ## Examples

      iex> ContractDiscovery.sync_all()
      {:ok, %{"AAPL" => 450, "SPY" => 800, ...}}
  """
  @spec sync_all(keyword()) :: {:ok, map()} | {:error, any()}
  def sync_all(opts \\ []) do
    symbols = Keyword.get(opts, :symbols, @watchlist_symbols)

    results =
      Enum.reduce(symbols, %{}, fn symbol, acc ->
        case sync_contracts(symbol, opts) do
          {:ok, count} -> Map.put(acc, symbol, count)
          {:error, _} -> Map.put(acc, symbol, 0)
        end
      end)

    {:ok, results}
  end

  @doc """
  Get available expiration dates for a symbol and contract type.

  Returns a sorted list of unique expiration dates that have contracts
  stored in the database.

  ## Parameters

    * `underlying_symbol` - The underlying stock symbol
    * `contract_type` - Either `:call` or `:put`

  ## Returns

    * List of Date structs, sorted ascending

  ## Examples

      iex> ContractDiscovery.get_available_expirations("AAPL", :call)
      [~D[2024-06-21], ~D[2024-06-28], ~D[2024-07-05], ...]
  """
  @spec get_available_expirations(String.t(), :call | :put) :: [Date.t()]
  def get_available_expirations(underlying_symbol, contract_type) do
    type_string = Atom.to_string(contract_type)

    from(c in Contract,
      where:
        c.underlying_symbol == ^underlying_symbol and
          c.contract_type == ^type_string and
          c.status == "active",
      select: c.expiration_date,
      distinct: true,
      order_by: [asc: c.expiration_date]
    )
    |> Repo.all()
  end

  @doc """
  Find the nearest weekly expiration on or after the given date.

  Weekly options typically expire on Fridays. This function finds the
  nearest Friday expiration that has contracts available.

  ## Parameters

    * `underlying_symbol` - The underlying stock symbol
    * `from_date` - Date to search from

  ## Returns

    * `{:ok, date}` - The nearest weekly expiration date
    * `{:error, :no_expiration_found}` - No suitable expiration found

  ## Examples

      iex> ContractDiscovery.find_nearest_weekly("AAPL", ~D[2024-06-15])
      {:ok, ~D[2024-06-21]}
  """
  @spec find_nearest_weekly(String.t(), Date.t()) :: {:ok, Date.t()} | {:error, atom()}
  def find_nearest_weekly(underlying_symbol, from_date) do
    # Find the next Friday on or after from_date
    days_until_friday = days_until_next_day(from_date, :friday)
    target_friday = Date.add(from_date, days_until_friday)

    # Look for expirations on the next few Fridays
    fridays =
      0..8
      |> Enum.map(fn week -> Date.add(target_friday, week * 7) end)

    find_first_available_expiration(underlying_symbol, fridays)
  end

  @doc """
  Find same-day (0DTE) expiration for the given date.

  0DTE options are available for major ETFs (SPY, QQQ) on Monday, Wednesday,
  and Friday. For individual stocks, 0DTE is typically only available on Fridays.

  ## Parameters

    * `underlying_symbol` - The underlying stock symbol
    * `date` - The date to check for 0DTE

  ## Returns

    * `{:ok, date}` - The date if 0DTE is available
    * `{:error, :no_0dte_available}` - No 0DTE expiration for this symbol/date

  ## Examples

      iex> ContractDiscovery.find_0dte("SPY", ~D[2024-06-17])  # Monday
      {:ok, ~D[2024-06-17]}

      iex> ContractDiscovery.find_0dte("AAPL", ~D[2024-06-17])  # Monday
      {:error, :no_0dte_available}
  """
  @spec find_0dte(String.t(), Date.t()) :: {:ok, Date.t()} | {:error, atom()}
  def find_0dte(underlying_symbol, date) do
    # Check if the symbol supports 0DTE on this day
    day_of_week = Date.day_of_week(date) |> day_of_week_to_atom()

    cond do
      # Major ETFs support 0DTE on Mon/Wed/Fri
      underlying_symbol in ["SPY", "QQQ"] and day_of_week in @zero_dte_days ->
        check_expiration_exists(underlying_symbol, date)

      # Other symbols typically only have 0DTE on Fridays
      day_of_week == :friday ->
        check_expiration_exists(underlying_symbol, date)

      true ->
        {:error, :no_0dte_available}
    end
  end

  @doc """
  Find a specific contract by underlying, expiration, type, and strike.

  ## Parameters

    * `underlying_symbol` - The underlying stock symbol
    * `expiration_date` - The expiration date
    * `contract_type` - Either `:call` or `:put`
    * `strike` - The strike price

  ## Returns

    * `{:ok, contract}` - The matching contract
    * `{:error, :not_found}` - No matching contract found

  ## Examples

      iex> ContractDiscovery.find_contract("AAPL", ~D[2024-06-21], :call, Decimal.new("150"))
      {:ok, %Contract{symbol: "AAPL240621C00150000", ...}}
  """
  @spec find_contract(String.t(), Date.t(), :call | :put, Decimal.t()) ::
          {:ok, Contract.t()} | {:error, atom()}
  def find_contract(underlying_symbol, expiration_date, contract_type, strike) do
    type_string = Atom.to_string(contract_type)

    query =
      from(c in Contract,
        where:
          c.underlying_symbol == ^underlying_symbol and
            c.expiration_date == ^expiration_date and
            c.contract_type == ^type_string and
            c.strike_price == ^strike and
            c.status == "active"
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      contract -> {:ok, contract}
    end
  end

  @doc """
  Find contracts near a target strike price.

  Returns contracts within a specified range of the target strike,
  useful for ATM and OTM strike selection.

  ## Parameters

    * `underlying_symbol` - The underlying stock symbol
    * `expiration_date` - The expiration date
    * `contract_type` - Either `:call` or `:put`
    * `target_strike` - The target strike price
    * `opts` - Options:
      - `:range` - Price range around target (default: 10)
      - `:limit` - Max contracts to return (default: 10)

  ## Returns

    * List of contracts sorted by distance from target strike
  """
  @spec find_contracts_near_strike(String.t(), Date.t(), :call | :put, Decimal.t(), keyword()) ::
          [Contract.t()]
  def find_contracts_near_strike(
        underlying_symbol,
        expiration_date,
        contract_type,
        target_strike,
        opts \\ []
      ) do
    type_string = Atom.to_string(contract_type)
    range = Keyword.get(opts, :range, Decimal.new(10))
    limit = Keyword.get(opts, :limit, 10)

    lower_bound = Decimal.sub(target_strike, range)
    upper_bound = Decimal.add(target_strike, range)

    from(c in Contract,
      where:
        c.underlying_symbol == ^underlying_symbol and
          c.expiration_date == ^expiration_date and
          c.contract_type == ^type_string and
          c.strike_price >= ^lower_bound and
          c.strike_price <= ^upper_bound and
          c.status == "active",
      order_by: fragment("ABS(? - ?)", c.strike_price, ^target_strike),
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Get the count of contracts by underlying symbol.

  ## Returns

    * Map of underlying symbols to contract counts
  """
  @spec contract_counts() :: map()
  def contract_counts do
    from(c in Contract,
      where: c.status == "active",
      group_by: c.underlying_symbol,
      select: {c.underlying_symbol, count(c.symbol)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Delete expired contracts from the database.

  Contracts with expiration dates before today are marked as expired
  or deleted depending on the `:delete` option.

  ## Parameters

    * `opts` - Options:
      - `:delete` - If true, delete expired contracts; if false, mark as "expired"

  ## Returns

    * `{:ok, count}` - Number of contracts affected
  """
  @spec cleanup_expired(keyword()) :: {:ok, non_neg_integer()}
  def cleanup_expired(opts \\ []) do
    today = Date.utc_today()
    delete? = Keyword.get(opts, :delete, false)

    if delete? do
      {count, _} =
        from(c in Contract, where: c.expiration_date < ^today)
        |> Repo.delete_all()

      {:ok, count}
    else
      {count, _} =
        from(c in Contract,
          where: c.expiration_date < ^today and c.status == "active"
        )
        |> Repo.update_all(set: [status: "expired"])

      {:ok, count}
    end
  end

  # Private Functions

  defp upsert_contracts(contracts) when is_list(contracts) do
    contracts
    |> Enum.map(&Contract.from_alpaca/1)
    |> Enum.map(fn contract ->
      attrs = Map.from_struct(contract) |> Map.drop([:__meta__, :inserted_at, :updated_at])

      %Contract{}
      |> Contract.changeset(attrs)
      |> Repo.insert(
        on_conflict: {:replace, [:status, :updated_at]},
        conflict_target: :symbol
      )
    end)
    |> Enum.count(fn
      {:ok, _} -> true
      _ -> false
    end)
  end

  defp maybe_add_type(opts, nil), do: opts
  defp maybe_add_type(opts, type), do: Keyword.put(opts, :type, type)

  defp days_until_next_day(date, target_day) do
    current_day = Date.day_of_week(date)
    target_num = day_to_number(target_day)

    diff = target_num - current_day

    if diff < 0 do
      diff + 7
    else
      diff
    end
  end

  defp day_to_number(:monday), do: 1
  defp day_to_number(:tuesday), do: 2
  defp day_to_number(:wednesday), do: 3
  defp day_to_number(:thursday), do: 4
  defp day_to_number(:friday), do: 5
  defp day_to_number(:saturday), do: 6
  defp day_to_number(:sunday), do: 7

  defp day_of_week_to_atom(1), do: :monday
  defp day_of_week_to_atom(2), do: :tuesday
  defp day_of_week_to_atom(3), do: :wednesday
  defp day_of_week_to_atom(4), do: :thursday
  defp day_of_week_to_atom(5), do: :friday
  defp day_of_week_to_atom(6), do: :saturday
  defp day_of_week_to_atom(7), do: :sunday

  defp find_first_available_expiration(_underlying, []), do: {:error, :no_expiration_found}

  defp find_first_available_expiration(underlying_symbol, [date | rest]) do
    case check_expiration_exists(underlying_symbol, date) do
      {:ok, _} = success -> success
      {:error, _} -> find_first_available_expiration(underlying_symbol, rest)
    end
  end

  defp check_expiration_exists(underlying_symbol, date) do
    query =
      from(c in Contract,
        where:
          c.underlying_symbol == ^underlying_symbol and
            c.expiration_date == ^date and
            c.status == "active",
        limit: 1
      )

    case Repo.one(query) do
      nil -> {:error, :no_0dte_available}
      _contract -> {:ok, date}
    end
  end
end
