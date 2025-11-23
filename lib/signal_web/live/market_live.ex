defmodule SignalWeb.MarketLive do
  use SignalWeb, :live_view
  alias SignalWeb.Live.Components.SystemStats

  @moduledoc """
  Real-time market data dashboard displaying live quotes, bars, and system health.

  Subscribes to PubSub topics for real-time updates and displays:
  - Current prices with bid/ask spreads
  - Latest bar data (OHLC + volume)
  - Connection status
  - System health metrics
  """

  @impl true
  def mount(_params, _session, socket) do
    # Get configured symbols
    symbols = Application.get_env(:signal, :symbols, [])

    # Subscribe to PubSub topics for real-time updates
    if connected?(socket) do
      # Subscribe to quotes and bars for each symbol
      Enum.each(symbols, fn symbol ->
        Phoenix.PubSub.subscribe(Signal.PubSub, "quotes:#{symbol}")
        Phoenix.PubSub.subscribe(Signal.PubSub, "bars:#{symbol}")
      end)

      # Subscribe to connection and system stats
      Phoenix.PubSub.subscribe(Signal.PubSub, "alpaca:connection")
      Phoenix.PubSub.subscribe(Signal.PubSub, "system:stats")
    end

    # Load initial data from BarCache
    symbol_data = load_initial_data(symbols)

    # Get current system stats and connection status from Monitor
    # This ensures we show the correct status even if the stream connected before LiveView mounted
    {connection_status, db_healthy, last_message} = get_initial_monitor_stats()

    {:ok,
     assign(socket,
       symbols: symbols,
       symbol_data: symbol_data,
       connection_status: connection_status,
       connection_details: %{},
       system_stats: %{
         quotes_per_sec: 0,
         bars_per_min: 0,
         trades_per_sec: 0,
         uptime_seconds: 0,
         db_healthy: db_healthy,
         last_quote: last_message.quote,
         last_bar: last_message.bar
       }
     )}
  end

  @impl true
  def handle_info({:quote, symbol_string, quote}, socket) do
    symbol = symbol_string

    # Get current data for this symbol
    current_data = Map.get(socket.assigns.symbol_data, symbol, initial_symbol_data(symbol))

    # Calculate new price from bid/ask midpoint
    new_price = calculate_midpoint(quote.bid_price, quote.ask_price)

    # Determine price change direction
    previous_price = current_data.current_price
    price_change = determine_price_change(new_price, previous_price)

    # Calculate spread
    spread = Decimal.sub(quote.ask_price, quote.bid_price)

    # Update symbol data
    updated_data = %{
      current_data
      | current_price: new_price,
        previous_price: current_data.current_price,
        bid: quote.bid_price,
        ask: quote.ask_price,
        spread: spread,
        last_update: quote.timestamp,
        price_change: price_change
    }

    # Update assigns
    symbol_data = Map.put(socket.assigns.symbol_data, symbol, updated_data)

    {:noreply, assign(socket, :symbol_data, symbol_data)}
  end

  @impl true
  def handle_info({:bar, symbol_string, bar}, socket) do
    symbol = symbol_string

    # Get current data for this symbol
    current_data = Map.get(socket.assigns.symbol_data, symbol, initial_symbol_data(symbol))

    # Update bar data
    updated_data = %{
      current_data
      | last_bar: %{
          open: bar.open,
          high: bar.high,
          low: bar.low,
          close: bar.close,
          volume: bar.volume,
          timestamp: bar.timestamp
        },
        last_update: bar.timestamp
    }

    # If no quote data yet, use bar close as current price
    updated_data =
      if is_nil(updated_data.current_price) do
        %{updated_data | current_price: bar.close, previous_price: bar.close}
      else
        updated_data
      end

    # Update assigns
    symbol_data = Map.put(socket.assigns.symbol_data, symbol, updated_data)

    {:noreply, assign(socket, :symbol_data, symbol_data)}
  end

  @impl true
  def handle_info({:connection, status, details}, socket) do
    {:noreply,
     assign(socket,
       connection_status: status,
       connection_details: details
     )}
  end

  @impl true
  def handle_info(stats_map, socket) when is_map(stats_map) do
    # Handle system stats from PubSub
    if Map.has_key?(stats_map, :quotes_per_sec) do
      {:noreply, assign(socket, :system_stats, stats_map)}
    else
      {:noreply, socket}
    end
  end

  # Private helper functions

  defp get_initial_monitor_stats do
    try do
      stats = Signal.Monitor.get_stats()
      {stats.connection_status, stats.db_healthy, stats.last_message}
    catch
      # Monitor not available (e.g., in tests) or process exited
      :exit, _ -> {:disconnected, true, %{quote: nil, bar: nil, trade: nil}}
    end
  end

  defp load_initial_data(symbols) do
    symbols
    |> Enum.map(fn symbol ->
      case Signal.BarCache.get(String.to_atom(symbol)) do
        {:ok, data} ->
          {symbol, symbol_data_from_cache(symbol, data)}

        {:error, :not_found} ->
          {symbol, initial_symbol_data(symbol)}
      end
    end)
    |> Map.new()
  end

  defp symbol_data_from_cache(symbol, cache_data) do
    base_data = initial_symbol_data(symbol)

    # Update with quote data if available
    base_data =
      if cache_data.last_quote do
        quote = cache_data.last_quote
        price = calculate_midpoint(quote.bid_price, quote.ask_price)
        spread = Decimal.sub(quote.ask_price, quote.bid_price)

        %{
          base_data
          | current_price: price,
            previous_price: price,
            bid: quote.bid_price,
            ask: quote.ask_price,
            spread: spread,
            last_update: quote.timestamp,
            price_change: :unchanged
        }
      else
        base_data
      end

    # Update with bar data if available
    if cache_data.last_bar do
      bar = cache_data.last_bar

      %{
        base_data
        | last_bar: %{
            open: bar.open,
            high: bar.high,
            low: bar.low,
            close: bar.close,
            volume: bar.volume,
            timestamp: bar.timestamp
          },
          last_update: bar.timestamp
      }
    else
      base_data
    end
  end

  defp initial_symbol_data(symbol) do
    %{
      symbol: symbol,
      current_price: nil,
      previous_price: nil,
      bid: nil,
      ask: nil,
      spread: nil,
      last_bar: nil,
      last_update: nil,
      price_change: :no_data
    }
  end

  defp calculate_midpoint(bid_price, ask_price) do
    bid_price
    |> Decimal.add(ask_price)
    |> Decimal.div(Decimal.new("2"))
  end

  defp determine_price_change(_new_price, previous_price) when is_nil(previous_price) do
    :no_data
  end

  defp determine_price_change(new_price, previous_price) do
    cond do
      Decimal.gt?(new_price, previous_price) -> :up
      Decimal.lt?(new_price, previous_price) -> :down
      true -> :unchanged
    end
  end

  defp format_price(nil), do: "-"

  defp format_price(decimal) do
    decimal
    |> Decimal.round(2)
    |> Decimal.to_string(:normal)
  end

  defp format_volume(nil), do: "-"

  defp format_volume(volume) when is_integer(volume) do
    cond do
      volume >= 1_000_000 -> "#{Float.round(volume / 1_000_000, 1)}M"
      volume >= 1_000 -> "#{Float.round(volume / 1_000, 1)}K"
      true -> Integer.to_string(volume)
    end
  end

  defp time_ago(nil), do: "-"

  defp time_ago(timestamp) do
    now = DateTime.utc_now()
    diff_seconds = DateTime.diff(now, timestamp, :second)

    cond do
      diff_seconds < 60 -> "#{diff_seconds}s ago"
      diff_seconds < 3600 -> "#{div(diff_seconds, 60)}m ago"
      diff_seconds < 86400 -> "#{div(diff_seconds, 3600)}h ago"
      true -> "#{div(diff_seconds, 86400)}d ago"
    end
  end

  defp price_change_class(price_change) do
    case price_change do
      :up -> "text-green-600"
      :down -> "text-red-600"
      :unchanged -> "text-gray-600"
      :no_data -> "text-gray-400"
    end
  end

  defp connection_badge_class(status) do
    case status do
      :connected -> "bg-green-100 text-green-800"
      :disconnected -> "bg-red-100 text-red-800"
      :reconnecting -> "bg-yellow-100 text-yellow-800"
      _ -> "bg-gray-100 text-gray-800"
    end
  end

  defp connection_status_text(status, details) do
    case status do
      :connected -> "Connected"
      :disconnected -> "Disconnected"
      :reconnecting -> "Reconnecting (attempt #{Map.get(details, :attempt, 0)})"
      _ -> "Unknown"
    end
  end

  # Template
  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-50">
      <!-- Header -->
      <div class="bg-white shadow">
        <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-4">
          <div class="flex items-center justify-between">
            <h1 class="text-3xl font-bold text-gray-900">Signal Market Data</h1>
            
    <!-- Connection Status Badge -->
            <div class={[
              "px-4 py-2 rounded-full text-sm font-medium",
              connection_badge_class(@connection_status)
            ]}>
              <div class="flex items-center gap-2">
                <div class={[
                  "w-2 h-2 rounded-full",
                  if(@connection_status == :connected, do: "bg-green-600", else: "bg-red-600")
                ]} />
                {connection_status_text(@connection_status, @connection_details)}
              </div>
            </div>
          </div>
        </div>
      </div>
      
    <!-- Main Content -->
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <!-- System Stats Component -->
        <div class="mb-8">
          <SystemStats.system_stats
            connection_status={@connection_status}
            connection_details={@connection_details}
            stats={@system_stats}
          />
        </div>
        
    <!-- Symbol Table -->
        <div class="bg-white shadow rounded-lg overflow-hidden">
          <div class="overflow-x-auto">
            <table class="min-w-full divide-y divide-gray-200">
              <thead class="bg-gray-50 sticky top-0">
                <tr>
                  <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                    Symbol
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
                    Price
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
                    Bid
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
                    Ask
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
                    Spread
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
                    Open
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
                    High
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
                    Low
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
                    Close
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
                    Volume
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
                    Updated
                  </th>
                </tr>
              </thead>
              <tbody class="bg-white divide-y divide-gray-200">
                <%= for symbol <- @symbols do %>
                  <% data = Map.get(@symbol_data, symbol, initial_symbol_data(symbol)) %>
                  <tr class="hover:bg-gray-50 even:bg-gray-50">
                    <td class="px-6 py-4 whitespace-nowrap text-sm font-medium text-gray-900">
                      {symbol}
                    </td>
                    <td class={[
                      "px-6 py-4 whitespace-nowrap text-sm font-mono text-right font-semibold",
                      price_change_class(data.price_change)
                    ]}>
                      ${format_price(data.current_price)}
                    </td>
                    <td class="px-6 py-4 whitespace-nowrap text-sm font-mono text-right text-gray-600">
                      ${format_price(data.bid)}
                    </td>
                    <td class="px-6 py-4 whitespace-nowrap text-sm font-mono text-right text-gray-600">
                      ${format_price(data.ask)}
                    </td>
                    <td class="px-6 py-4 whitespace-nowrap text-sm font-mono text-right text-gray-600">
                      ${format_price(data.spread)}
                    </td>
                    <td class="px-6 py-4 whitespace-nowrap text-sm font-mono text-right text-gray-600">
                      {if data.last_bar, do: "$#{format_price(data.last_bar.open)}", else: "-"}
                    </td>
                    <td class="px-6 py-4 whitespace-nowrap text-sm font-mono text-right text-gray-600">
                      {if data.last_bar, do: "$#{format_price(data.last_bar.high)}", else: "-"}
                    </td>
                    <td class="px-6 py-4 whitespace-nowrap text-sm font-mono text-right text-gray-600">
                      {if data.last_bar, do: "$#{format_price(data.last_bar.low)}", else: "-"}
                    </td>
                    <td class="px-6 py-4 whitespace-nowrap text-sm font-mono text-right text-gray-600">
                      {if data.last_bar, do: "$#{format_price(data.last_bar.close)}", else: "-"}
                    </td>
                    <td class="px-6 py-4 whitespace-nowrap text-sm font-mono text-right text-gray-600">
                      {if data.last_bar, do: format_volume(data.last_bar.volume), else: "-"}
                    </td>
                    <td class="px-6 py-4 whitespace-nowrap text-sm text-right text-gray-500">
                      {time_ago(data.last_update)}
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
