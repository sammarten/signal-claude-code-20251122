defmodule SignalWeb.SignalsLive do
  use SignalWeb, :live_view

  alias Signal.Signals.TradeSignal
  alias Signal.MarketData.Bar

  @moduledoc """
  Real-time signals dashboard displaying trade signals with filtering and details.

  Subscribes to PubSub topics for real-time signal updates and displays:
  - Active signals with quality grades
  - Confluence factor breakdowns
  - Signal filtering by grade, direction, status
  - Signal history
  - Mini charts with price context
  """

  @bars_per_chart 30

  @impl true
  def mount(_params, _session, socket) do
    # Subscribe to signal events
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Signal.PubSub, "signals:all")
    end

    # Load initial signals
    signals = load_signals()

    # Load bar data for each unique symbol
    symbol_bars = load_bars_for_symbols(signals)

    {:ok,
     assign(socket,
       signals: signals,
       symbol_bars: symbol_bars,
       selected_signal: nil,
       filters: %{
         grade: "all",
         direction: "all",
         status: "active"
       },
       sort_by: :generated_at,
       sort_order: :desc
     )}
  end

  @impl true
  def handle_info({:signal_generated, signal}, socket) do
    # Add new signal to the list
    signals = [signal | socket.assigns.signals]

    # Load bars for new symbol if not already loaded
    symbol_bars =
      if Map.has_key?(socket.assigns.symbol_bars, signal.symbol) do
        socket.assigns.symbol_bars
      else
        Map.put(socket.assigns.symbol_bars, signal.symbol, load_bars_for_symbol(signal.symbol))
      end

    {:noreply, assign(socket, signals: signals, symbol_bars: symbol_bars)}
  end

  @impl true
  def handle_info({:signal_filled, signal}, socket) do
    signals = update_signal_in_list(socket.assigns.signals, signal)
    {:noreply, assign(socket, :signals, signals)}
  end

  @impl true
  def handle_info({:signal_expired, signal}, socket) do
    signals = update_signal_in_list(socket.assigns.signals, signal)
    {:noreply, assign(socket, :signals, signals)}
  end

  @impl true
  def handle_info({:signal_invalidated, signal}, socket) do
    signals = update_signal_in_list(socket.assigns.signals, signal)
    {:noreply, assign(socket, :signals, signals)}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("filter", %{"filter" => filter_params}, socket) do
    filters = %{
      grade: Map.get(filter_params, "grade", "all"),
      direction: Map.get(filter_params, "direction", "all"),
      status: Map.get(filter_params, "status", "active")
    }

    {:noreply, assign(socket, :filters, filters)}
  end

  @impl true
  def handle_event("select_signal", %{"id" => id}, socket) do
    signal = Enum.find(socket.assigns.signals, &(&1.id == id))
    {:noreply, assign(socket, :selected_signal, signal)}
  end

  @impl true
  def handle_event("close_details", _params, socket) do
    {:noreply, assign(socket, :selected_signal, nil)}
  end

  # Private helpers

  defp load_signals do
    # Load recent signals (last 24 hours)
    since = DateTime.add(DateTime.utc_now(), -24 * 60 * 60, :second)

    import Ecto.Query

    TradeSignal
    |> where([s], s.generated_at >= ^since)
    |> order_by([s], desc: s.generated_at)
    |> limit(100)
    |> Signal.Repo.all()
  end

  defp load_bars_for_symbols(signals) do
    signals
    |> Enum.map(& &1.symbol)
    |> Enum.uniq()
    |> Enum.map(fn symbol -> {symbol, load_bars_for_symbol(symbol)} end)
    |> Enum.into(%{})
  end

  defp load_bars_for_symbol(symbol) do
    import Ecto.Query

    Bar
    |> where([b], b.symbol == ^symbol)
    |> order_by([b], desc: b.bar_time)
    |> limit(@bars_per_chart)
    |> Signal.Repo.all()
    |> Enum.reverse()
    |> Enum.map(fn bar ->
      %{
        time: DateTime.to_unix(bar.bar_time),
        open: Decimal.to_string(bar.open),
        high: Decimal.to_string(bar.high),
        low: Decimal.to_string(bar.low),
        close: Decimal.to_string(bar.close)
      }
    end)
  end

  defp bars_json(symbol_bars, symbol) do
    bars = Map.get(symbol_bars, symbol, [])
    Jason.encode!(bars)
  end

  defp update_signal_in_list(signals, updated_signal) do
    Enum.map(signals, fn signal ->
      if signal.id == updated_signal.id, do: updated_signal, else: signal
    end)
  end

  defp filtered_signals(signals, filters) do
    signals
    |> filter_by_grade(filters.grade)
    |> filter_by_direction(filters.direction)
    |> filter_by_status(filters.status)
  end

  defp filter_by_grade(signals, "all"), do: signals

  defp filter_by_grade(signals, grade) do
    Enum.filter(signals, &(&1.quality_grade == grade))
  end

  defp filter_by_direction(signals, "all"), do: signals

  defp filter_by_direction(signals, direction) do
    Enum.filter(signals, &(&1.direction == direction))
  end

  defp filter_by_status(signals, "all"), do: signals

  defp filter_by_status(signals, status) do
    Enum.filter(signals, &(&1.status == status))
  end

  defp grade_badge_class(grade) do
    case grade do
      "A" -> "bg-green-500/20 text-green-400 border-green-500/30"
      "B" -> "bg-blue-500/20 text-blue-400 border-blue-500/30"
      "C" -> "bg-yellow-500/20 text-yellow-400 border-yellow-500/30"
      "D" -> "bg-orange-500/20 text-orange-400 border-orange-500/30"
      "F" -> "bg-red-500/20 text-red-400 border-red-500/30"
      _ -> "bg-zinc-500/20 text-zinc-400 border-zinc-500/30"
    end
  end

  defp direction_class(direction) do
    case direction do
      "long" -> "text-green-400"
      "short" -> "text-red-400"
      _ -> "text-zinc-400"
    end
  end

  defp direction_icon(direction) do
    case direction do
      "long" -> "hero-arrow-trending-up"
      "short" -> "hero-arrow-trending-down"
      _ -> "hero-minus"
    end
  end

  defp status_badge_class(status) do
    case status do
      "active" -> "bg-green-500/10 text-green-400"
      "filled" -> "bg-blue-500/10 text-blue-400"
      "expired" -> "bg-zinc-500/10 text-zinc-400"
      "invalidated" -> "bg-red-500/10 text-red-400"
      _ -> "bg-zinc-500/10 text-zinc-400"
    end
  end

  defp format_price(nil), do: "-"

  defp format_price(decimal) do
    decimal
    |> Decimal.round(2)
    |> Decimal.to_string(:normal)
  end

  defp format_rr(nil), do: "-"

  defp format_rr(decimal) do
    "#{Decimal.round(decimal, 1)}:1"
  end

  defp time_ago(nil), do: "-"

  defp time_ago(datetime) do
    now = DateTime.utc_now()
    diff_seconds = DateTime.diff(now, datetime, :second)

    cond do
      diff_seconds < 60 -> "#{diff_seconds}s ago"
      diff_seconds < 3600 -> "#{div(diff_seconds, 60)}m ago"
      diff_seconds < 86400 -> "#{div(diff_seconds, 3600)}h ago"
      true -> "#{div(diff_seconds, 86400)}d ago"
    end
  end

  defp time_until_expiry(expires_at) do
    now = DateTime.utc_now()
    diff_seconds = DateTime.diff(expires_at, now, :second)

    cond do
      diff_seconds <= 0 -> "Expired"
      diff_seconds < 60 -> "#{diff_seconds}s"
      diff_seconds < 3600 -> "#{div(diff_seconds, 60)}m"
      true -> "#{div(diff_seconds, 3600)}h"
    end
  end

  defp strategy_display_name(strategy) do
    case strategy do
      "break_and_retest" -> "Break & Retest"
      "opening_range_breakout" -> "Opening Range"
      "one_candle_rule" -> "One Candle Rule"
      "premarket_breakout" -> "Premarket Breakout"
      _ -> strategy
    end
  end

  defp count_by_status(signals, status) do
    Enum.count(signals, &(&1.status == status))
  end

  defp count_by_grade(signals, grade) do
    Enum.count(signals, &(&1.quality_grade == grade))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-zinc-950">
      <!-- Header -->
      <div class="bg-gradient-to-r from-zinc-900 via-zinc-800 to-zinc-900 border-b border-zinc-800">
        <div class="max-w-[1920px] mx-auto px-4 sm:px-6 lg:px-8 py-6">
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-4">
              <div class="bg-gradient-to-br from-amber-500 to-orange-600 p-2 rounded-lg shadow-lg shadow-amber-500/20">
                <.icon name="hero-bolt" class="w-8 h-8 text-white" />
              </div>
              <div>
                <h1 class="text-3xl font-bold text-white tracking-tight">Trade Signals</h1>
                <p class="text-zinc-400 text-sm">Real-time signal detection and analysis</p>
              </div>
            </div>
            
    <!-- Navigation -->
            <div class="flex items-center gap-4">
              <.link
                navigate={~p"/"}
                class="px-4 py-2 text-sm font-medium text-zinc-400 hover:text-white transition-colors"
              >
                <.icon name="hero-chart-bar" class="w-4 h-4 inline mr-1" /> Market
              </.link>
              <span class="px-4 py-2 text-sm font-medium text-white bg-zinc-800 rounded-lg">
                <.icon name="hero-bolt" class="w-4 h-4 inline mr-1" /> Signals
              </span>
            </div>
          </div>
        </div>
      </div>
      
    <!-- Main Content -->
      <div class="max-w-[1920px] mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <!-- Stats Summary -->
        <div class="grid grid-cols-2 md:grid-cols-4 lg:grid-cols-6 gap-4 mb-8">
          <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-4">
            <div class="text-xs text-zinc-500 mb-1">Active</div>
            <div class="text-2xl font-bold text-green-400">
              {count_by_status(@signals, "active")}
            </div>
          </div>
          <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-4">
            <div class="text-xs text-zinc-500 mb-1">Filled</div>
            <div class="text-2xl font-bold text-blue-400">
              {count_by_status(@signals, "filled")}
            </div>
          </div>
          <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-4">
            <div class="text-xs text-zinc-500 mb-1">Grade A</div>
            <div class="text-2xl font-bold text-green-400">{count_by_grade(@signals, "A")}</div>
          </div>
          <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-4">
            <div class="text-xs text-zinc-500 mb-1">Grade B</div>
            <div class="text-2xl font-bold text-blue-400">{count_by_grade(@signals, "B")}</div>
          </div>
          <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-4">
            <div class="text-xs text-zinc-500 mb-1">Grade C</div>
            <div class="text-2xl font-bold text-yellow-400">{count_by_grade(@signals, "C")}</div>
          </div>
          <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-4">
            <div class="text-xs text-zinc-500 mb-1">Total (24h)</div>
            <div class="text-2xl font-bold text-white">{length(@signals)}</div>
          </div>
        </div>
        
    <!-- Filters -->
        <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-4 mb-6">
          <form phx-change="filter" class="flex flex-wrap items-center gap-4">
            <div class="flex items-center gap-2">
              <label class="text-sm text-zinc-400">Grade:</label>
              <select
                name="filter[grade]"
                class="bg-zinc-800 border border-zinc-700 rounded-lg px-3 py-1.5 text-sm text-white focus:ring-amber-500 focus:border-amber-500"
              >
                <option value="all" selected={@filters.grade == "all"}>All</option>
                <option value="A" selected={@filters.grade == "A"}>A</option>
                <option value="B" selected={@filters.grade == "B"}>B</option>
                <option value="C" selected={@filters.grade == "C"}>C</option>
                <option value="D" selected={@filters.grade == "D"}>D</option>
                <option value="F" selected={@filters.grade == "F"}>F</option>
              </select>
            </div>

            <div class="flex items-center gap-2">
              <label class="text-sm text-zinc-400">Direction:</label>
              <select
                name="filter[direction]"
                class="bg-zinc-800 border border-zinc-700 rounded-lg px-3 py-1.5 text-sm text-white focus:ring-amber-500 focus:border-amber-500"
              >
                <option value="all" selected={@filters.direction == "all"}>All</option>
                <option value="long" selected={@filters.direction == "long"}>Long</option>
                <option value="short" selected={@filters.direction == "short"}>Short</option>
              </select>
            </div>

            <div class="flex items-center gap-2">
              <label class="text-sm text-zinc-400">Status:</label>
              <select
                name="filter[status]"
                class="bg-zinc-800 border border-zinc-700 rounded-lg px-3 py-1.5 text-sm text-white focus:ring-amber-500 focus:border-amber-500"
              >
                <option value="all" selected={@filters.status == "all"}>All</option>
                <option value="active" selected={@filters.status == "active"}>Active</option>
                <option value="filled" selected={@filters.status == "filled"}>Filled</option>
                <option value="expired" selected={@filters.status == "expired"}>Expired</option>
                <option value="invalidated" selected={@filters.status == "invalidated"}>
                  Invalidated
                </option>
              </select>
            </div>
          </form>
        </div>
        
    <!-- Main Layout -->
        <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
          <!-- Signals List -->
          <div class="lg:col-span-2 space-y-4">
            <%= if Enum.empty?(filtered_signals(@signals, @filters)) do %>
              <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-12 text-center">
                <.icon name="hero-bolt" class="w-12 h-12 text-zinc-600 mx-auto mb-4" />
                <h3 class="text-lg font-medium text-zinc-400 mb-2">No Signals</h3>
                <p class="text-sm text-zinc-500">
                  No signals match your current filters. Try adjusting the filters or wait for new signals.
                </p>
              </div>
            <% else %>
              <%= for signal <- filtered_signals(@signals, @filters) do %>
                <div
                  class={"bg-zinc-900/50 rounded-xl border border-zinc-800 p-4 hover:border-zinc-700 transition-all cursor-pointer #{if @selected_signal && @selected_signal.id == signal.id, do: "ring-2 ring-amber-500/50", else: ""}"}
                  phx-click="select_signal"
                  phx-value-id={signal.id}
                >
                  <div class="flex gap-4">
                    <!-- Left side: Signal info -->
                    <div class="flex-1 min-w-0">
                      <!-- Header row -->
                      <div class="flex items-center justify-between mb-2">
                        <div class="flex items-center gap-3">
                          <div class={"p-1.5 rounded-lg #{if signal.direction == "long", do: "bg-green-500/10", else: "bg-red-500/10"}"}>
                            <.icon
                              name={direction_icon(signal.direction)}
                              class={"w-4 h-4 #{direction_class(signal.direction)}"}
                            />
                          </div>
                          <div>
                            <span class="text-lg font-bold text-white">{signal.symbol}</span>
                            <span class={"ml-2 text-xs font-medium uppercase #{direction_class(signal.direction)}"}>
                              {signal.direction}
                            </span>
                          </div>
                        </div>
                        <div class="flex items-center gap-2">
                          <span class={"px-1.5 py-0.5 text-xs font-bold rounded #{status_badge_class(signal.status)}"}>
                            {String.upcase(signal.status)}
                          </span>
                          <span class={"px-2 py-0.5 text-base font-bold rounded border #{grade_badge_class(signal.quality_grade)}"}>
                            {signal.quality_grade}
                          </span>
                        </div>
                      </div>
                      <!-- Price levels - compact inline format -->
                      <div class="flex items-center gap-3 text-xs mb-2">
                        <span class="text-zinc-500">{strategy_display_name(signal.strategy)}</span>
                        <span class="text-zinc-600">|</span>
                        <span>
                          <span class="text-zinc-500">Entry</span>
                          <span class="font-mono font-medium text-amber-400 ml-1">
                            ${format_price(signal.entry_price)}
                          </span>
                        </span>
                        <span>
                          <span class="text-zinc-500">Stop</span>
                          <span class="font-mono font-medium text-red-400 ml-1">
                            ${format_price(signal.stop_loss)}
                          </span>
                        </span>
                        <span>
                          <span class="text-zinc-500">Target</span>
                          <span class="font-mono font-medium text-green-400 ml-1">
                            ${format_price(signal.take_profit)}
                          </span>
                        </span>
                        <span>
                          <span class="text-zinc-500">R:R</span>
                          <span class="font-mono font-medium text-white ml-1">
                            {format_rr(signal.risk_reward)}
                          </span>
                        </span>
                      </div>
                      <!-- Footer -->
                      <div class="flex items-center justify-between text-xs text-zinc-500">
                        <div class="flex items-center gap-3">
                          <span>Score: {signal.confluence_score}/13</span>
                          <span>Generated {time_ago(signal.generated_at)}</span>
                        </div>
                        <%= if signal.status == "active" do %>
                          <span class="text-amber-400">
                            Expires {time_until_expiry(signal.expires_at)}
                          </span>
                        <% end %>
                      </div>
                    </div>
                    <!-- Right side: Spark Chart -->
                    <div class="flex-shrink-0">
                      <div
                        id={"spark-chart-#{signal.id}"}
                        phx-hook="SparkChart"
                        phx-update="ignore"
                        data-symbol={signal.symbol}
                        data-entry={format_price(signal.entry_price)}
                        data-stop={format_price(signal.stop_loss)}
                        data-target={format_price(signal.take_profit)}
                        data-direction={signal.direction}
                        data-bars={bars_json(@symbol_bars, signal.symbol)}
                        data-width="200"
                        data-height="140"
                        class="rounded-lg overflow-hidden bg-zinc-800/30"
                      >
                      </div>
                    </div>
                  </div>
                </div>
              <% end %>
            <% end %>
          </div>
          
    <!-- Signal Details Panel -->
          <div class="lg:col-span-1">
            <%= if @selected_signal do %>
              <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 overflow-hidden sticky top-8">
                <!-- Header -->
                <div class="px-4 py-3 border-b border-zinc-800 bg-zinc-900/80 flex items-center justify-between">
                  <h3 class="font-bold text-white">Signal Details</h3>
                  <button
                    phx-click="close_details"
                    class="text-zinc-400 hover:text-white transition-colors"
                  >
                    <.icon name="hero-x-mark" class="w-5 h-5" />
                  </button>
                </div>
                
    <!-- Content -->
                <div class="p-4 space-y-4">
                  <!-- Symbol Header -->
                  <div class="flex items-center justify-between">
                    <div class="flex items-center gap-2">
                      <span class="text-2xl font-bold text-white">{@selected_signal.symbol}</span>
                      <span class={"text-sm font-medium uppercase #{direction_class(@selected_signal.direction)}"}>
                        {@selected_signal.direction}
                      </span>
                    </div>
                    <span class={"px-3 py-1 text-xl font-bold rounded-lg border #{grade_badge_class(@selected_signal.quality_grade)}"}>
                      {@selected_signal.quality_grade}
                    </span>
                  </div>
                  
    <!-- Strategy -->
                  <div class="bg-zinc-800/50 rounded-lg p-3">
                    <div class="text-xs text-zinc-500 mb-1">Strategy</div>
                    <div class="text-sm font-medium text-white">
                      {strategy_display_name(@selected_signal.strategy)}
                    </div>
                  </div>
                  
    <!-- Price Levels -->
                  <div class="space-y-2">
                    <div class="flex justify-between items-center py-2 border-b border-zinc-800">
                      <span class="text-sm text-zinc-400">Entry Price</span>
                      <span class="font-mono font-medium text-white">
                        ${format_price(@selected_signal.entry_price)}
                      </span>
                    </div>
                    <div class="flex justify-between items-center py-2 border-b border-zinc-800">
                      <span class="text-sm text-zinc-400">Stop Loss</span>
                      <span class="font-mono font-medium text-red-400">
                        ${format_price(@selected_signal.stop_loss)}
                      </span>
                    </div>
                    <div class="flex justify-between items-center py-2 border-b border-zinc-800">
                      <span class="text-sm text-zinc-400">Take Profit</span>
                      <span class="font-mono font-medium text-green-400">
                        ${format_price(@selected_signal.take_profit)}
                      </span>
                    </div>
                    <div class="flex justify-between items-center py-2 border-b border-zinc-800">
                      <span class="text-sm text-zinc-400">Risk/Reward</span>
                      <span class="font-mono font-medium text-amber-400">
                        {format_rr(@selected_signal.risk_reward)}
                      </span>
                    </div>
                    <%= if @selected_signal.level_type do %>
                      <div class="flex justify-between items-center py-2 border-b border-zinc-800">
                        <span class="text-sm text-zinc-400">Level Type</span>
                        <span class="font-mono font-medium text-purple-400">
                          {String.upcase(@selected_signal.level_type || "")}
                        </span>
                      </div>
                    <% end %>
                  </div>
                  
    <!-- Confluence Factors -->
                  <div>
                    <div class="text-sm font-medium text-zinc-300 mb-2">
                      Confluence Factors ({@selected_signal.confluence_score}/13)
                    </div>
                    <div class="space-y-1">
                      <%= if @selected_signal.confluence_factors do %>
                        <%= for {factor, data} <- @selected_signal.confluence_factors do %>
                          <div class="flex items-center justify-between text-xs py-1">
                            <span class="text-zinc-400 capitalize">
                              {String.replace(factor, "_", " ")}
                            </span>
                            <div class="flex items-center gap-2">
                              <%= if data["present"] do %>
                                <.icon name="hero-check-circle" class="w-4 h-4 text-green-400" />
                              <% else %>
                                <.icon name="hero-x-circle" class="w-4 h-4 text-zinc-600" />
                              <% end %>
                              <span class={"font-mono #{if data["score"] > 0, do: "text-green-400", else: "text-zinc-600"}"}>
                                {data["score"]}/{data["max_score"]}
                              </span>
                            </div>
                          </div>
                        <% end %>
                      <% end %>
                    </div>
                  </div>
                  
    <!-- Timestamps -->
                  <div class="bg-zinc-800/50 rounded-lg p-3 space-y-2">
                    <div class="flex justify-between text-xs">
                      <span class="text-zinc-500">Generated</span>
                      <span class="text-zinc-300">{time_ago(@selected_signal.generated_at)}</span>
                    </div>
                    <%= if @selected_signal.status == "active" do %>
                      <div class="flex justify-between text-xs">
                        <span class="text-zinc-500">Expires</span>
                        <span class="text-amber-400">
                          {time_until_expiry(@selected_signal.expires_at)}
                        </span>
                      </div>
                    <% end %>
                    <%= if @selected_signal.filled_at do %>
                      <div class="flex justify-between text-xs">
                        <span class="text-zinc-500">Filled</span>
                        <span class="text-blue-400">{time_ago(@selected_signal.filled_at)}</span>
                      </div>
                    <% end %>
                  </div>
                </div>
              </div>
            <% else %>
              <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-8 text-center">
                <.icon name="hero-cursor-arrow-rays" class="w-12 h-12 text-zinc-600 mx-auto mb-4" />
                <h3 class="text-sm font-medium text-zinc-400 mb-2">Select a Signal</h3>
                <p class="text-xs text-zinc-500">
                  Click on a signal to view its details and confluence analysis.
                </p>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
