defmodule Signal.Alpaca.MockStream do
  @moduledoc """
  Mock stream implementation for testing and development without Alpaca credentials.

  Generates fake market data (quotes, bars, trades) on a timer and delivers them
  to a callback module, simulating the real Alpaca stream behavior.

  Useful for:
  - UI development without API credentials
  - Testing dashboard functionality
  - Demos and presentations
  - Development when Alpaca is unavailable

  ## Configuration

  Enable mock stream in config/dev.exs:

      config :signal, use_mock_stream: true

  ## Examples

      # Start mock stream with same interface as real stream
      {:ok, pid} = Signal.Alpaca.MockStream.start_link(
        callback_module: MyHandler,
        callback_state: %{},
        initial_subscriptions: %{bars: ["AAPL"], quotes: ["AAPL"]}
      )

      # Mock stream will generate fake data every 1-5 seconds
  """

  use GenServer
  require Logger

  @doc """
  Starts the mock stream GenServer.

  Accepts same parameters as Signal.Alpaca.Stream for drop-in replacement.

  ## Parameters

    - `opts` - Keyword list with:
      - `:callback_module` (required) - Module implementing handle_message/2
      - `:callback_state` (optional) - Initial state for callback
      - `:initial_subscriptions` (optional) - Map with :bars, :quotes, :trades keys
      - `:name` (optional) - GenServer registration name

  ## Returns

    - `{:ok, pid}` - GenServer process
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc """
  Adds subscriptions (for compatibility, but mock generates all data anyway).
  """
  def subscribe(_pid_or_name, _subscriptions) do
    :ok
  end

  @doc """
  Removes subscriptions (no-op for mock).
  """
  def unsubscribe(_pid_or_name, _subscriptions) do
    :ok
  end

  @doc """
  Returns the connection status (always :subscribed for mock).
  """
  def status(_pid_or_name) do
    :subscribed
  end

  @doc """
  Returns active subscriptions.
  """
  def subscriptions(pid_or_name) do
    GenServer.call(pid_or_name, :get_subscriptions)
  end

  ## GenServer Callbacks

  @impl true
  def init(opts) do
    callback_module = Keyword.fetch!(opts, :callback_module)
    callback_state = Keyword.get(opts, :callback_state, %{})
    initial_subscriptions = Keyword.get(opts, :initial_subscriptions, %{})

    # Extract symbols from subscriptions
    bar_symbols = Map.get(initial_subscriptions, :bars, [])
    quote_symbols = Map.get(initial_subscriptions, :quotes, [])
    all_symbols = Enum.uniq(bar_symbols ++ quote_symbols)

    # Initialize price state for each symbol (starting prices)
    symbol_prices =
      all_symbols
      |> Enum.map(fn symbol ->
        {symbol, generate_initial_price()}
      end)
      |> Map.new()

    state = %{
      callback_module: callback_module,
      callback_state: callback_state,
      subscriptions: initial_subscriptions,
      symbols: all_symbols,
      symbol_prices: symbol_prices,
      status: :subscribed
    }

    Logger.info("MockStream started with symbols: #{inspect(all_symbols)}")

    # Send initial connection message
    send_connection_message(state, :connected)

    # Schedule first data generation
    schedule_quote_generation()
    schedule_bar_generation()

    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  @impl true
  def handle_call(:get_subscriptions, _from, state) do
    {:reply, state.subscriptions, state}
  end

  @impl true
  def handle_info(:generate_quotes, state) do
    # Generate quote for each symbol
    new_symbol_prices =
      Enum.reduce(state.symbols, state.symbol_prices, fn symbol, prices ->
        current_price = Map.get(prices, symbol, generate_initial_price())
        new_price = update_price(current_price)

        # Generate and send quote
        quote = generate_quote(symbol, new_price)
        send_to_callback(state, quote)

        Map.put(prices, symbol, new_price)
      end)

    # Schedule next quote generation (1-3 seconds)
    schedule_quote_generation()

    {:noreply, %{state | symbol_prices: new_symbol_prices}}
  end

  @impl true
  def handle_info(:generate_bars, state) do
    # Generate bar for each symbol
    Enum.each(state.symbols, fn symbol ->
      current_price = Map.get(state.symbol_prices, symbol, generate_initial_price())
      bar = generate_bar(symbol, current_price)
      send_to_callback(state, bar)
    end)

    # Schedule next bar generation (30-60 seconds)
    schedule_bar_generation()

    {:noreply, state}
  end

  ## Private Functions

  defp schedule_quote_generation do
    # Random interval between 1-3 seconds for quotes
    interval = :rand.uniform(2000) + 1000
    Process.send_after(self(), :generate_quotes, interval)
  end

  defp schedule_bar_generation do
    # Random interval between 30-60 seconds for bars
    interval = :rand.uniform(30_000) + 30_000
    Process.send_after(self(), :generate_bars, interval)
  end

  defp generate_initial_price do
    # Generate random starting price between 50 and 500
    base = :rand.uniform(450) + 50
    Decimal.new(Integer.to_string(base))
  end

  defp update_price(current_price) do
    # Random walk: +/- 0.01 to 0.50
    max_change = 0.50
    change = (:rand.uniform() * 2 - 1) * max_change
    change_decimal = Decimal.new(Float.to_string(change))

    new_price = Decimal.add(current_price, change_decimal)

    # Ensure price stays positive
    if Decimal.compare(new_price, Decimal.new("1")) == :lt do
      Decimal.new("1")
    else
      new_price
    end
  end

  defp generate_quote(symbol, price) do
    # Generate bid/ask spread (0.01 to 0.10)
    spread = (:rand.uniform(9) + 1) / 100.0
    half_spread = spread / 2.0

    bid_price = Decimal.sub(price, Decimal.new(Float.to_string(half_spread)))
    ask_price = Decimal.add(price, Decimal.new(Float.to_string(half_spread)))

    %{
      type: :quote,
      symbol: symbol,
      bid_price: Decimal.round(bid_price, 2),
      bid_size: :rand.uniform(500) + 100,
      ask_price: Decimal.round(ask_price, 2),
      ask_size: :rand.uniform(500) + 100,
      timestamp: DateTime.utc_now()
    }
  end

  defp generate_bar(symbol, close_price) do
    # Generate OHLC around the close price
    # High is close + 0 to 2%
    # Low is close - 0 to 2%
    # Open is random between low and high

    high_pct = :rand.uniform() * 0.02
    low_pct = :rand.uniform() * 0.02

    high = Decimal.mult(close_price, Decimal.add(Decimal.new("1"), Decimal.new(Float.to_string(high_pct))))
    low = Decimal.mult(close_price, Decimal.sub(Decimal.new("1"), Decimal.new(Float.to_string(low_pct))))

    # Open is random between low and high
    open_pct = :rand.uniform()
    open_val = Decimal.add(low, Decimal.mult(Decimal.sub(high, low), Decimal.new(Float.to_string(open_pct))))

    # Generate volume (100k to 2M)
    volume = :rand.uniform(1_900_000) + 100_000

    # Calculate VWAP (approximate as average of OHLC)
    vwap =
      [open_val, high, low, close_price]
      |> Enum.reduce(Decimal.new("0"), &Decimal.add/2)
      |> Decimal.div(Decimal.new("4"))

    %{
      type: :bar,
      symbol: symbol,
      open: Decimal.round(open_val, 2),
      high: Decimal.round(high, 2),
      low: Decimal.round(low, 2),
      close: Decimal.round(close_price, 2),
      volume: volume,
      vwap: Decimal.round(vwap, 2),
      trade_count: :rand.uniform(300) + 50,
      timestamp: DateTime.utc_now()
    }
  end

  defp send_to_callback(state, message) do
    # Call the callback module's handle_message/2
    case state.callback_module.handle_message(message, state.callback_state) do
      {:ok, new_callback_state} ->
        # Update callback state (though we don't store it in mock)
        new_callback_state

      {:error, reason} ->
        Logger.warning("MockStream callback error: #{inspect(reason)}")
        state.callback_state
    end
  end

  defp send_connection_message(state, status) do
    message = %{
      type: :connection,
      status: status,
      attempt: 0
    }

    send_to_callback(state, message)
  end
end
