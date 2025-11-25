defmodule SignalWeb.MarketLive do
  use SignalWeb, :live_view
  import Ecto.Query
  alias SignalWeb.Live.Components.SystemStats
  alias Signal.Technicals.Levels

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
      # Subscribe to quotes, bars, and levels for each symbol
      Enum.each(symbols, fn symbol ->
        Phoenix.PubSub.subscribe(Signal.PubSub, "quotes:#{symbol}")
        Phoenix.PubSub.subscribe(Signal.PubSub, "bars:#{symbol}")
        Phoenix.PubSub.subscribe(Signal.PubSub, "levels:#{symbol}")
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

    # Load chart data once (only for the first 4 symbols shown in charts)
    # This prevents expensive DB queries on every render
    chart_data =
      if connected?(socket) do
        symbols
        |> Enum.take(4)
        |> Enum.map(fn symbol -> {symbol, get_recent_bars_for_chart(symbol)} end)
        |> Map.new()
      else
        %{}
      end

    # Load key levels for chart symbols
    key_levels =
      if connected?(socket) do
        symbols
        |> Enum.take(4)
        |> Enum.map(fn symbol -> {symbol, load_key_levels(symbol)} end)
        |> Map.new()
      else
        %{}
      end

    {:ok,
     assign(socket,
       symbols: symbols,
       symbol_data: symbol_data,
       chart_data: chart_data,
       key_levels: key_levels,
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

    # Push price update to chart (for real-time candle updates)
    # Only push if this symbol is in the first 4 (shown in charts)
    socket =
      if symbol in Enum.take(socket.assigns.symbols, 4) do
        # Truncate timestamp to current minute for candle time
        bar_time = DateTime.truncate(quote.timestamp, :second)
        bar_time_unix = DateTime.to_unix(bar_time) - rem(DateTime.to_unix(bar_time), 60)

        price_data = %{
          time: bar_time_unix,
          price: Decimal.to_string(new_price)
        }

        push_event(socket, "price-update-#{symbol}", %{data: price_data})
      else
        socket
      end

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

    # Push bar update to the chart hook
    bar_data = %{
      time: DateTime.to_unix(bar.timestamp),
      open: Decimal.to_string(bar.open),
      high: Decimal.to_string(bar.high),
      low: Decimal.to_string(bar.low),
      close: Decimal.to_string(bar.close),
      volume: bar.volume
    }

    socket =
      socket
      |> assign(:symbol_data, symbol_data)
      |> push_event("bar-update-#{symbol}", %{bar: bar_data})

    {:noreply, socket}
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
  def handle_info({:levels_updated, symbol, levels}, socket) do
    # Update key levels for this symbol
    key_levels = Map.put(socket.assigns.key_levels, symbol, format_levels_for_chart(levels))

    # Push level updates to the chart if this symbol is in the first 4
    socket =
      if symbol in Enum.take(socket.assigns.symbols, 4) do
        push_event(socket, "levels-update-#{symbol}", %{levels: format_levels_for_chart(levels)})
      else
        socket
      end

    {:noreply, assign(socket, :key_levels, key_levels)}
  end

  @impl true
  def handle_info(stats_map, socket) when is_map(stats_map) do
    # Handle system stats from PubSub
    if Map.has_key?(stats_map, :quotes_per_sec) do
      # Normalize the stats structure to match what SystemStats component expects
      # Monitor sends last_message as nested map, we flatten to last_quote/last_bar
      last_message = Map.get(stats_map, :last_message, %{})

      normalized_stats = %{
        quotes_per_sec: stats_map.quotes_per_sec,
        bars_per_min: stats_map.bars_per_min,
        trades_per_sec: stats_map.trades_per_sec,
        uptime_seconds: stats_map.uptime_seconds,
        db_healthy: stats_map.db_healthy,
        last_quote: Map.get(last_message, :quote),
        last_bar: Map.get(last_message, :bar)
      }

      {:noreply, assign(socket, :system_stats, normalized_stats)}
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

  defp price_change_class_dark(price_change) do
    case price_change do
      :up -> "text-green-400"
      :down -> "text-red-400"
      :unchanged -> "text-zinc-400"
      :no_data -> "text-zinc-600"
    end
  end

  defp connection_badge_class_dark(status) do
    case status do
      :connected -> "bg-green-500/10 text-green-400 border border-green-500/20"
      :disconnected -> "bg-red-500/10 text-red-400 border border-red-500/20"
      :reconnecting -> "bg-yellow-500/10 text-yellow-400 border border-yellow-500/20"
      _ -> "bg-zinc-800/50 text-zinc-400 border border-zinc-700"
    end
  end

  defp get_recent_bars_for_chart(symbol) do
    # Get the most recent 390 bars (full trading day) for initial chart display
    # Using limit instead of time cutoff ensures data shows even after hours
    query =
      from(b in Signal.MarketData.Bar,
        where: b.symbol == ^symbol,
        order_by: [desc: b.bar_time],
        limit: 390
      )

    try do
      Signal.Repo.all(query)
      |> Enum.reverse()
      |> Enum.map(fn bar ->
        %{
          time: DateTime.to_unix(bar.bar_time),
          open: Decimal.to_string(bar.open),
          high: Decimal.to_string(bar.high),
          low: Decimal.to_string(bar.low),
          close: Decimal.to_string(bar.close),
          volume: bar.volume
        }
      end)
    rescue
      _ -> []
    end
  end

  defp load_key_levels(symbol) do
    case Levels.get_current_levels(String.to_atom(symbol)) do
      {:ok, levels} -> format_levels_for_chart(levels)
      {:error, _} -> %{}
    end
  end

  defp format_levels_for_chart(nil), do: %{}

  defp format_levels_for_chart(levels) do
    %{
      pdh: decimal_to_float(levels.previous_day_high),
      pdl: decimal_to_float(levels.previous_day_low),
      pmh: decimal_to_float(levels.premarket_high),
      pml: decimal_to_float(levels.premarket_low),
      or5h: decimal_to_float(levels.opening_range_5m_high),
      or5l: decimal_to_float(levels.opening_range_5m_low),
      or15h: decimal_to_float(levels.opening_range_15m_high),
      or15l: decimal_to_float(levels.opening_range_15m_low)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp decimal_to_float(nil), do: nil

  defp decimal_to_float(decimal) do
    Decimal.to_float(decimal)
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
    <div class="min-h-screen bg-zinc-950">
      <!-- Header with gradient -->
      <div class="bg-gradient-to-r from-zinc-900 via-zinc-800 to-zinc-900 border-b border-zinc-800">
        <div class="max-w-[1920px] mx-auto px-4 sm:px-6 lg:px-8 py-6">
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-4">
              <div class="bg-gradient-to-br from-green-500 to-emerald-600 p-2 rounded-lg shadow-lg shadow-green-500/20">
                <svg class="w-8 h-8 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M13 7h8m0 0v8m0-8l-8 8-4-4-6 6"
                  />
                </svg>
              </div>
              <div>
                <h1 class="text-3xl font-bold text-white tracking-tight">Signal</h1>
                <p class="text-zinc-400 text-sm">Real-time Market Intelligence</p>
              </div>
            </div>
            
    <!-- Connection Status Badge -->
            <div class={[
              "px-5 py-2.5 rounded-xl text-sm font-semibold backdrop-blur-sm transition-all duration-300 shadow-lg",
              connection_badge_class_dark(@connection_status)
            ]}>
              <div class="flex items-center gap-2.5">
                <div class={[
                  "w-2.5 h-2.5 rounded-full animate-pulse",
                  if(@connection_status == :connected,
                    do: "bg-green-400 shadow-lg shadow-green-400/50",
                    else: "bg-red-400 shadow-lg shadow-red-400/50"
                  )
                ]} />
                {connection_status_text(@connection_status, @connection_details)}
              </div>
            </div>
          </div>
        </div>
      </div>
      
    <!-- Main Content -->
      <div class="max-w-[1920px] mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <!-- System Stats Component -->
        <div class="mb-8 animate-fade-in">
          <SystemStats.system_stats
            connection_status={@connection_status}
            connection_details={@connection_details}
            stats={@system_stats}
          />
        </div>
        
    <!-- Charts Grid -->
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6 mb-8">
          <%= for symbol <- Enum.take(@symbols, 4) do %>
            <% data = Map.get(@symbol_data, symbol, initial_symbol_data(symbol)) %>
            <div class="bg-zinc-900/50 backdrop-blur-sm rounded-2xl border border-zinc-800 overflow-hidden shadow-2xl hover:shadow-green-500/10 transition-all duration-300 hover:border-zinc-700">
              <!-- Chart Header -->
              <div class="px-6 py-4 border-b border-zinc-800 bg-zinc-900/80">
                <div class="flex items-center justify-between">
                  <div class="flex items-center gap-3">
                    <h3 class="text-2xl font-bold text-white">{symbol}</h3>
                    <div class={[
                      "text-3xl font-bold font-mono transition-colors duration-300",
                      price_change_class_dark(data.price_change)
                    ]}>
                      ${format_price(data.current_price)}
                    </div>
                  </div>
                  <div class="text-right">
                    <div class="text-xs text-zinc-500 mb-1">BID • ASK</div>
                    <div class="text-sm font-mono text-zinc-400">
                      ${format_price(data.bid)} • ${format_price(data.ask)}
                    </div>
                  </div>
                </div>
              </div>
              
    <!-- Chart Container -->
              <div
                id={"chart-#{symbol}"}
                phx-hook="TradingChart"
                phx-update="ignore"
                data-symbol={symbol}
                data-initial-bars={Jason.encode!(Map.get(@chart_data, symbol, []))}
                data-key-levels={Jason.encode!(Map.get(@key_levels, symbol, %{}))}
                class="w-full min-h-[500px]"
              >
              </div>
              
    <!-- Chart Footer with Stats -->
              <div class="px-6 py-4 bg-zinc-900/80 border-t border-zinc-800">
                <div class="grid grid-cols-4 gap-4 text-center">
                  <div>
                    <div class="text-xs text-zinc-500 mb-1">OPEN</div>
                    <div class="text-sm font-mono font-semibold text-zinc-300">
                      {if data.last_bar, do: "$#{format_price(data.last_bar.open)}", else: "-"}
                    </div>
                  </div>
                  <div>
                    <div class="text-xs text-zinc-500 mb-1">HIGH</div>
                    <div class="text-sm font-mono font-semibold text-green-400">
                      {if data.last_bar, do: "$#{format_price(data.last_bar.high)}", else: "-"}
                    </div>
                  </div>
                  <div>
                    <div class="text-xs text-zinc-500 mb-1">LOW</div>
                    <div class="text-sm font-mono font-semibold text-red-400">
                      {if data.last_bar, do: "$#{format_price(data.last_bar.low)}", else: "-"}
                    </div>
                  </div>
                  <div>
                    <div class="text-xs text-zinc-500 mb-1">VOLUME</div>
                    <div class="text-sm font-mono font-semibold text-zinc-300">
                      {if data.last_bar, do: format_volume(data.last_bar.volume), else: "-"}
                    </div>
                  </div>
                </div>
              </div>
            </div>
          <% end %>
        </div>
        
    <!-- Full Symbol Table -->
        <div class="bg-zinc-900/50 backdrop-blur-sm rounded-2xl border border-zinc-800 overflow-hidden shadow-2xl">
          <div class="px-6 py-4 border-b border-zinc-800 bg-zinc-900/80">
            <h2 class="text-xl font-bold text-white">All Symbols</h2>
          </div>
          <div class="overflow-x-auto">
            <table class="min-w-full divide-y divide-zinc-800">
              <thead class="bg-zinc-900/50 sticky top-0">
                <tr>
                  <th class="px-6 py-3 text-left text-xs font-medium text-zinc-400 uppercase tracking-wider">
                    Symbol
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-zinc-400 uppercase tracking-wider">
                    Price
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-zinc-400 uppercase tracking-wider">
                    Bid
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-zinc-400 uppercase tracking-wider">
                    Ask
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-zinc-400 uppercase tracking-wider">
                    Spread
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-zinc-400 uppercase tracking-wider">
                    Open
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-zinc-400 uppercase tracking-wider">
                    High
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-zinc-400 uppercase tracking-wider">
                    Low
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-zinc-400 uppercase tracking-wider">
                    Close
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-zinc-400 uppercase tracking-wider">
                    Volume
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-zinc-400 uppercase tracking-wider">
                    Updated
                  </th>
                </tr>
              </thead>
              <tbody class="bg-zinc-900/30 divide-y divide-zinc-800">
                <%= for symbol <- @symbols do %>
                  <% data = Map.get(@symbol_data, symbol, initial_symbol_data(symbol)) %>
                  <tr class="hover:bg-zinc-800/50 transition-colors duration-150">
                    <td class="px-6 py-4 whitespace-nowrap text-sm font-bold text-white">
                      {symbol}
                    </td>
                    <td class={[
                      "px-6 py-4 whitespace-nowrap text-sm font-mono text-right font-bold",
                      price_change_class_dark(data.price_change)
                    ]}>
                      ${format_price(data.current_price)}
                    </td>
                    <td class="px-6 py-4 whitespace-nowrap text-sm font-mono text-right text-zinc-400">
                      ${format_price(data.bid)}
                    </td>
                    <td class="px-6 py-4 whitespace-nowrap text-sm font-mono text-right text-zinc-400">
                      ${format_price(data.ask)}
                    </td>
                    <td class="px-6 py-4 whitespace-nowrap text-sm font-mono text-right text-zinc-400">
                      ${format_price(data.spread)}
                    </td>
                    <td class="px-6 py-4 whitespace-nowrap text-sm font-mono text-right text-zinc-400">
                      {if data.last_bar, do: "$#{format_price(data.last_bar.open)}", else: "-"}
                    </td>
                    <td class="px-6 py-4 whitespace-nowrap text-sm font-mono text-right text-green-400">
                      {if data.last_bar, do: "$#{format_price(data.last_bar.high)}", else: "-"}
                    </td>
                    <td class="px-6 py-4 whitespace-nowrap text-sm font-mono text-right text-red-400">
                      {if data.last_bar, do: "$#{format_price(data.last_bar.low)}", else: "-"}
                    </td>
                    <td class="px-6 py-4 whitespace-nowrap text-sm font-mono text-right text-zinc-400">
                      {if data.last_bar, do: "$#{format_price(data.last_bar.close)}", else: "-"}
                    </td>
                    <td class="px-6 py-4 whitespace-nowrap text-sm font-mono text-right text-zinc-400">
                      {if data.last_bar, do: format_volume(data.last_bar.volume), else: "-"}
                    </td>
                    <td class="px-6 py-4 whitespace-nowrap text-sm text-right text-zinc-500">
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
