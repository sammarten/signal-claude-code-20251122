defmodule Signal.BarCache do
  @moduledoc """
  In-memory ETS cache for latest bar and quote data per symbol with O(1) access.

  This GenServer manages a protected ETS table with read concurrency enabled
  for fast concurrent reads. It stores the latest bar and quote for each symbol.

  ## Examples

      iex> Signal.BarCache.get(:AAPL)
      {:ok, %{last_bar: %{...}, last_quote: %{...}}}

      iex> Signal.BarCache.current_price(:AAPL)
      #Decimal<185.50>
  """

  use GenServer
  require Logger

  @table_name :bar_cache

  # Client API

  @doc """
  Starts the BarCache GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get all cached data for a symbol.

  ## Parameters

    - `symbol` - Symbol as atom (e.g., :AAPL)

  ## Returns

    - `{:ok, data_map}` if symbol found
    - `{:error, :not_found}` if symbol not found
  """
  @spec get(atom()) :: {:ok, map()} | {:error, :not_found}
  def get(symbol) when is_atom(symbol) do
    case :ets.lookup(@table_name, symbol) do
      [{^symbol, data}] -> {:ok, data}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Get just the latest bar for a symbol.

  ## Parameters

    - `symbol` - Symbol as atom

  ## Returns

    - Bar map or nil if not found
  """
  @spec get_bar(atom()) :: map() | nil
  def get_bar(symbol) when is_atom(symbol) do
    case get(symbol) do
      {:ok, data} -> Map.get(data, :last_bar)
      {:error, :not_found} -> nil
    end
  end

  @doc """
  Get just the latest quote for a symbol.

  ## Parameters

    - `symbol` - Symbol as atom

  ## Returns

    - Quote map or nil if not found
  """
  @spec get_quote(atom()) :: map() | nil
  def get_quote(symbol) when is_atom(symbol) do
    case get(symbol) do
      {:ok, data} -> Map.get(data, :last_quote)
      {:error, :not_found} -> nil
    end
  end

  @doc """
  Calculate current mid-point price for a symbol.

  Logic:
  1. If has quote, return (bid_price + ask_price) / 2
  2. Else if has bar, return bar.close
  3. Else return nil

  ## Parameters

    - `symbol` - Symbol as atom

  ## Returns

    - Decimal price or nil if no data available
  """
  @spec current_price(atom()) :: Decimal.t() | nil
  def current_price(symbol) when is_atom(symbol) do
    case get(symbol) do
      {:ok, %{last_quote: quote}} when not is_nil(quote) ->
        # Calculate mid-point from bid/ask
        Decimal.div(
          Decimal.add(quote.bid_price, quote.ask_price),
          Decimal.new("2")
        )

      {:ok, %{last_bar: bar}} when not is_nil(bar) ->
        # Fall back to bar close
        bar.close

      _ ->
        nil
    end
  end

  @doc """
  Update the bar for a symbol.

  ## Parameters

    - `symbol` - Symbol as atom
    - `bar` - Bar map with OHLCV data

  ## Returns

    - `:ok`
  """
  @spec update_bar(atom(), map()) :: :ok
  def update_bar(symbol, bar) when is_atom(symbol) and is_map(bar) do
    GenServer.call(__MODULE__, {:update_bar, symbol, bar})
  end

  @doc """
  Update the quote for a symbol.

  ## Parameters

    - `symbol` - Symbol as atom
    - `quote` - Quote map with bid/ask data

  ## Returns

    - `:ok`
  """
  @spec update_quote(atom(), map()) :: :ok
  def update_quote(symbol, quote) when is_atom(symbol) and is_map(quote) do
    GenServer.call(__MODULE__, {:update_quote, symbol, quote})
  end

  @doc """
  Get list of all cached symbols.

  ## Returns

    - List of symbol atoms
  """
  @spec all_symbols() :: [atom()]
  def all_symbols do
    @table_name
    |> :ets.tab2list()
    |> Enum.map(fn {symbol, _data} -> symbol end)
  end

  @doc """
  Clear all cached data (for testing).

  ## Returns

    - `:ok`
  """
  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Create ETS table with options:
    # - :named_table - reference by name :bar_cache
    # - :protected - only this process can write, all can read
    # - read_concurrency: true - optimize for concurrent reads
    table =
      :ets.new(@table_name, [
        :named_table,
        :protected,
        :set,
        read_concurrency: true
      ])

    Logger.info("BarCache initialized with ETS table #{inspect(table)}")

    {:ok, %{table: @table_name}}
  end

  @impl true
  def handle_call({:update_bar, symbol, bar}, _from, state) do
    # Get existing data or initialize empty
    existing_data =
      case :ets.lookup(state.table, symbol) do
        [{^symbol, data}] -> data
        [] -> %{last_bar: nil, last_quote: nil}
      end

    # Update :last_bar field
    updated_data = Map.put(existing_data, :last_bar, bar)

    # Insert into ETS
    :ets.insert(state.table, {symbol, updated_data})

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:update_quote, symbol, quote}, _from, state) do
    # Get existing data or initialize empty
    existing_data =
      case :ets.lookup(state.table, symbol) do
        [{^symbol, data}] -> data
        [] -> %{last_bar: nil, last_quote: nil}
      end

    # Update :last_quote field
    updated_data = Map.put(existing_data, :last_quote, quote)

    # Insert into ETS
    :ets.insert(state.table, {symbol, updated_data})

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    # Delete all objects from ETS
    :ets.delete_all_objects(state.table)

    {:reply, :ok, state}
  end
end
