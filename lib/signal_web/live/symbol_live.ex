defmodule SignalWeb.SymbolLive do
  use SignalWeb, :live_view
  import Ecto.Query

  alias SignalWeb.Live.Components.Navigation
  alias Signal.Backtest.SimulatedTrade
  alias Signal.Backtest.DaySimulator
  alias Signal.Data.MarketCalendar
  alias Signal.MarketData.Bar
  alias Signal.Technicals.KeyLevels
  alias Signal.Repo

  @moduledoc """
  Symbol-focused view for analyzing trades on a specific symbol.

  Features:
  - Calendar for date selection with trading days highlighted
  - Candlestick chart for the selected date
  - Trade markers displayed on the chart
  - Trade list with details
  """

  @impl true
  def mount(%{"symbol" => symbol}, _session, socket) do
    # Always uppercase the symbol
    symbol = String.upcase(symbol)

    # Default to today's date (in ET)
    today = Date.utc_today()

    # Get valid date range for this symbol
    {min_date, max_date} = get_date_range(symbol)

    # Use the most recent trading day with data, or the last trading day
    selected_date =
      cond do
        max_date && Date.compare(today, max_date) == :gt ->
          max_date

        MarketCalendar.trading_day?(today) ->
          today

        true ->
          # Find the most recent trading day
          find_previous_trading_day(today) || today
      end

    calendar_month = Date.beginning_of_month(selected_date)

    {:ok,
     socket
     |> assign(
       page_title: "#{symbol} Analysis",
       symbol: symbol,
       selected_date: selected_date,
       calendar_month: calendar_month,
       min_date: min_date,
       max_date: max_date,
       trading_days: load_trading_days_for_month(calendar_month),
       bars: [],
       trades: [],
       simulated_trades: [],
       simulation_ran: false,
       key_levels: nil,
       selected_trade: nil,
       show_simulated: true
     )
     |> load_data_for_date()}
  end

  @impl true
  def mount(_params, _session, socket) do
    # Default to AAPL if no symbol specified
    {:ok, push_navigate(socket, to: ~p"/symbols/AAPL")}
  end

  @impl true
  def handle_params(%{"symbol" => symbol}, _uri, socket) do
    symbol = String.upcase(symbol)

    if socket.assigns[:symbol] != symbol do
      {min_date, max_date} = get_date_range(symbol)

      selected_date =
        if max_date do
          max_date
        else
          Date.utc_today()
        end

      calendar_month = Date.beginning_of_month(selected_date)

      {:noreply,
       socket
       |> assign(
         page_title: "#{symbol} Analysis",
         symbol: symbol,
         selected_date: selected_date,
         calendar_month: calendar_month,
         min_date: min_date,
         max_date: max_date,
         trading_days: load_trading_days_for_month(calendar_month),
         bars: [],
         trades: [],
         simulated_trades: [],
         simulation_ran: false,
         key_levels: nil,
         selected_trade: nil
       )
       |> load_data_for_date()}
    else
      {:noreply, socket}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("select_date", %{"date" => date_string}, socket) do
    case Date.from_iso8601(date_string) do
      {:ok, date} ->
        updated_socket =
          socket
          |> assign(selected_date: date, simulated_trades: [], simulation_ran: false)
          |> load_data_for_date()

        formatted_bars = format_bars_for_chart(updated_socket.assigns.bars)

        formatted_trades =
          format_trades_for_chart(
            updated_socket.assigns.trades,
            updated_socket.assigns.simulated_trades
          )

        formatted_levels = format_levels_for_chart(updated_socket.assigns.key_levels)

        {:noreply,
         push_event(updated_socket, "chart-data-updated", %{
           bars: formatted_bars,
           trades: formatted_trades,
           levels: formatted_levels
         })}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("run_simulation", _params, socket) do
    symbol = socket.assigns.symbol
    date = socket.assigns.selected_date

    {:ok, trades} = DaySimulator.run(symbol, date, %{target_r: Decimal.new("2.0")})

    updated_socket = assign(socket, simulated_trades: trades, simulation_ran: true)
    formatted_bars = format_bars_for_chart(updated_socket.assigns.bars)
    formatted_trades = format_trades_for_chart(updated_socket.assigns.trades, trades)
    formatted_levels = format_levels_for_chart(updated_socket.assigns.key_levels)

    {:noreply,
     push_event(updated_socket, "chart-data-updated", %{
       bars: formatted_bars,
       trades: formatted_trades,
       levels: formatted_levels
     })}
  end

  @impl true
  def handle_event("clear_simulation", _params, socket) do
    updated_socket = assign(socket, simulated_trades: [], simulation_ran: false)
    formatted_bars = format_bars_for_chart(updated_socket.assigns.bars)
    formatted_trades = format_trades_for_chart(updated_socket.assigns.trades, [])
    formatted_levels = format_levels_for_chart(updated_socket.assigns.key_levels)

    {:noreply,
     push_event(updated_socket, "chart-data-updated", %{
       bars: formatted_bars,
       trades: formatted_trades,
       levels: formatted_levels
     })}
  end

  @impl true
  def handle_event("prev_month", _params, socket) do
    new_month = Date.add(socket.assigns.calendar_month, -30) |> Date.beginning_of_month()

    {:noreply,
     assign(socket,
       calendar_month: new_month,
       trading_days: load_trading_days_for_month(new_month)
     )}
  end

  @impl true
  def handle_event("next_month", _params, socket) do
    new_month = Date.add(socket.assigns.calendar_month, 32) |> Date.beginning_of_month()

    {:noreply,
     assign(socket,
       calendar_month: new_month,
       trading_days: load_trading_days_for_month(new_month)
     )}
  end

  @impl true
  def handle_event("prev_day", _params, socket) do
    current_date = socket.assigns.selected_date
    min_date = socket.assigns.min_date

    # Find previous trading day
    prev_date = find_previous_trading_day(current_date)

    if prev_date && (is_nil(min_date) || Date.compare(prev_date, min_date) != :lt) do
      navigate_to_date(socket, prev_date)
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("next_day", _params, socket) do
    current_date = socket.assigns.selected_date
    max_date = socket.assigns.max_date

    # Find next trading day
    next_date = find_next_trading_day(current_date)

    if next_date && (is_nil(max_date) || Date.compare(next_date, max_date) != :gt) do
      navigate_to_date(socket, next_date)
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("select_trade", %{"id" => trade_id}, socket) do
    # Look in both persisted trades and simulated trades
    trade =
      Enum.find(socket.assigns.trades, &(&1.id == trade_id)) ||
        Enum.find(socket.assigns.simulated_trades, &(&1.id == trade_id))

    socket = assign(socket, :selected_trade, trade)

    # Load and push chart data if trade exists
    socket =
      if trade do
        bars = load_trade_bars(trade)
        formatted_bars = format_trade_detail_bars(bars)
        formatted_trade = format_trade_for_detail_chart(trade)

        level_data =
          if Map.has_key?(trade, :level_type) and Map.has_key?(trade, :level_price) do
            %{
              type: to_string(trade.level_type),
              price: decimal_to_string(trade.level_price)
            }
          else
            nil
          end

        push_event(socket, "trade-chart-data", %{
          bars: formatted_bars,
          trade: formatted_trade,
          level: level_data
        })
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("close_trade_details", _params, socket) do
    {:noreply, assign(socket, :selected_trade, nil)}
  end

  # Private helpers

  defp get_date_range(symbol) do
    query =
      from(b in Bar,
        where: b.symbol == ^symbol,
        select: {min(b.bar_time), max(b.bar_time)}
      )

    case Repo.one(query) do
      {nil, nil} -> {nil, nil}
      {min_dt, max_dt} -> {DateTime.to_date(min_dt), DateTime.to_date(max_dt)}
    end
  end

  defp load_data_for_date(socket) do
    symbol = socket.assigns.symbol
    date = socket.assigns.selected_date

    # Load bars for the selected date
    bars = load_bars_for_date(symbol, date)

    # Load trades for the selected date
    trades = load_trades_for_date(symbol, date)

    # Load key levels for the selected date
    key_levels = load_key_levels_for_date(symbol, date)

    assign(socket, bars: bars, trades: trades, key_levels: key_levels)
  end

  defp load_trading_days_for_month(month) do
    start_date = Date.beginning_of_month(month)
    end_date = Date.end_of_month(month)
    MarketCalendar.trading_days_between(start_date, end_date) |> MapSet.new()
  end

  defp find_previous_trading_day(date) do
    # Look back up to 10 days to find a trading day
    Enum.find_value(1..10, fn days_back ->
      candidate = Date.add(date, -days_back)

      if MarketCalendar.trading_day?(candidate) do
        candidate
      else
        nil
      end
    end)
  end

  defp find_next_trading_day(date) do
    # Look forward up to 10 days to find a trading day
    Enum.find_value(1..10, fn days_forward ->
      candidate = Date.add(date, days_forward)

      if MarketCalendar.trading_day?(candidate) do
        candidate
      else
        nil
      end
    end)
  end

  defp navigate_to_date(socket, date) do
    calendar_month =
      if date.month != socket.assigns.calendar_month.month ||
           date.year != socket.assigns.calendar_month.year do
        Date.beginning_of_month(date)
      else
        socket.assigns.calendar_month
      end

    updated_socket =
      socket
      |> assign(
        selected_date: date,
        calendar_month: calendar_month,
        trading_days: load_trading_days_for_month(calendar_month),
        simulated_trades: [],
        simulation_ran: false
      )
      |> load_data_for_date()

    formatted_bars = format_bars_for_chart(updated_socket.assigns.bars)

    formatted_trades =
      format_trades_for_chart(
        updated_socket.assigns.trades,
        updated_socket.assigns.simulated_trades
      )

    formatted_levels = format_levels_for_chart(updated_socket.assigns.key_levels)

    {:noreply,
     push_event(updated_socket, "chart-data-updated", %{
       bars: formatted_bars,
       trades: formatted_trades,
       levels: formatted_levels
     })}
  end

  defp load_bars_for_date(symbol, date) do
    # Create datetime range for the trading day (4:00 AM to 8:00 PM ET)
    # Convert to UTC for database query
    start_dt = datetime_for_time(date, ~T[04:00:00], "America/New_York")
    end_dt = datetime_for_time(date, ~T[20:00:00], "America/New_York")

    query =
      from(b in Bar,
        where: b.symbol == ^symbol,
        where: b.bar_time >= ^start_dt,
        where: b.bar_time <= ^end_dt,
        order_by: [asc: b.bar_time]
      )

    Repo.all(query)
  end

  defp load_trades_for_date(symbol, date) do
    # Convert date to datetime range in UTC
    start_dt = datetime_for_time(date, ~T[04:00:00], "America/New_York")
    end_dt = datetime_for_time(date, ~T[20:00:00], "America/New_York")

    query =
      from(t in SimulatedTrade,
        where: t.symbol == ^symbol,
        where: t.entry_time >= ^start_dt,
        where: t.entry_time <= ^end_dt,
        order_by: [asc: t.entry_time]
      )

    Repo.all(query)
  end

  defp load_key_levels_for_date(symbol, date) do
    Repo.one(
      from(l in KeyLevels,
        where: l.symbol == ^symbol and l.date == ^date
      )
    )
  end

  defp datetime_for_time(date, time, timezone) do
    DateTime.new!(date, time, timezone)
    |> DateTime.shift_zone!("Etc/UTC")
  end

  defp format_levels_for_chart(nil), do: []

  defp format_levels_for_chart(%KeyLevels{} = levels) do
    [
      {"PDH", levels.previous_day_high, "#f59e0b"},
      {"PDL", levels.previous_day_low, "#f59e0b"},
      {"PMH", levels.premarket_high, "#8b5cf6"},
      {"PML", levels.premarket_low, "#8b5cf6"},
      {"OR5H", levels.opening_range_5m_high, "#06b6d4"},
      {"OR5L", levels.opening_range_5m_low, "#06b6d4"},
      {"OR15H", levels.opening_range_15m_high, "#10b981"},
      {"OR15L", levels.opening_range_15m_low, "#10b981"}
    ]
    |> Enum.reject(fn {_label, price, _color} -> is_nil(price) end)
    |> Enum.map(fn {label, price, color} ->
      %{
        label: label,
        price: Decimal.to_string(price),
        color: color
      }
    end)
  end

  defp format_bars_for_chart(bars) do
    Enum.map(bars, fn bar ->
      %{
        time: DateTime.to_unix(bar.bar_time),
        open: Decimal.to_string(bar.open),
        high: Decimal.to_string(bar.high),
        low: Decimal.to_string(bar.low),
        close: Decimal.to_string(bar.close),
        volume: bar.volume
      }
    end)
  end

  defp format_trades_for_chart(trades, simulated_trades \\ []) do
    all_trades = trades ++ simulated_trades

    # Return trade data for drawing horizontal lines and zones
    Enum.map(all_trades, fn trade ->
      # Calculate the target R from entry, stop, and take_profit
      target_r = calculate_target_r(trade)

      %{
        id: trade.id,
        direction: to_string(trade.direction),
        entry_price: format_price(trade.entry_price),
        entry_time: DateTime.to_unix(trade.entry_time),
        exit_time: trade.exit_time && DateTime.to_unix(trade.exit_time),
        stop_loss: format_price(trade.stop_loss),
        take_profit: trade.take_profit && format_price(trade.take_profit),
        exit_price: trade.exit_price && format_price(trade.exit_price),
        status: to_string(trade.status),
        r_multiple: trade.r_multiple && Decimal.to_string(trade.r_multiple),
        target_r: target_r
      }
    end)
  end

  defp calculate_target_r(trade) do
    with entry when not is_nil(entry) <- trade.entry_price,
         stop when not is_nil(stop) <- trade.stop_loss,
         target when not is_nil(target) <- trade.take_profit do
      risk = Decimal.abs(Decimal.sub(entry, stop))
      reward = Decimal.abs(Decimal.sub(target, entry))

      if Decimal.compare(risk, Decimal.new(0)) == :gt do
        Decimal.div(reward, risk) |> Decimal.round(1) |> Decimal.to_string()
      else
        "2.0"
      end
    else
      _ -> "2.0"
    end
  end

  # Load bars for trade detail chart (5 min before entry, 5 min after exit)
  defp load_trade_bars(trade) do
    if is_nil(trade.entry_time) do
      []
    else
      # 5 minutes before entry
      start_time = DateTime.add(trade.entry_time, -5 * 60, :second)

      # 5 minutes after exit, or 15 minutes after entry if no exit
      end_time =
        if trade.exit_time do
          DateTime.add(trade.exit_time, 5 * 60, :second)
        else
          DateTime.add(trade.entry_time, 15 * 60, :second)
        end

      symbol = to_string(trade.symbol)

      from(b in Bar,
        where: b.symbol == ^symbol,
        where: b.bar_time >= ^start_time,
        where: b.bar_time <= ^end_time,
        order_by: [asc: b.bar_time]
      )
      |> Repo.all()
    end
  end

  # Format bars for the trade detail chart
  defp format_trade_detail_bars(bars) do
    Enum.map(bars, fn bar ->
      %{
        time: DateTime.to_unix(bar.bar_time),
        open: Decimal.to_string(bar.open),
        high: Decimal.to_string(bar.high),
        low: Decimal.to_string(bar.low),
        close: Decimal.to_string(bar.close)
      }
    end)
  end

  # Format trade for the detail chart
  defp format_trade_for_detail_chart(trade) do
    %{
      direction: to_string(trade.direction),
      entry_price: decimal_to_string(trade.entry_price),
      entry_time: datetime_to_unix(trade.entry_time),
      stop_loss: decimal_to_string(trade.stop_loss),
      take_profit: decimal_to_string(trade.take_profit),
      exit_price: decimal_to_string(trade.exit_price),
      exit_time: datetime_to_unix(trade.exit_time),
      status: to_string(trade.status)
    }
  end

  defp decimal_to_string(nil), do: nil
  defp decimal_to_string(d), do: Decimal.to_string(d)

  defp datetime_to_unix(nil), do: nil
  defp datetime_to_unix(dt), do: DateTime.to_unix(dt)

  defp format_level_type(type) when is_atom(type) do
    case type do
      :pdh -> "Previous Day High"
      :pdl -> "Previous Day Low"
      :pmh -> "Premarket High"
      :pml -> "Premarket Low"
      :or5h -> "5min Opening Range High"
      :or5l -> "5min Opening Range Low"
      :or15h -> "15min Opening Range High"
      :or15l -> "15min Opening Range Low"
      _ -> to_string(type) |> String.upcase()
    end
  end

  defp format_level_type(type) when is_binary(type),
    do: format_level_type(String.to_existing_atom(type))

  defp format_level_type(_), do: "Unknown"

  defp format_price(nil), do: "-"

  defp format_price(decimal) do
    decimal |> Decimal.round(2) |> Decimal.to_string(:normal)
  end

  defp format_r(nil), do: "0.00"

  defp format_r(decimal) do
    sign = if Decimal.compare(decimal, Decimal.new(0)) == :lt, do: "", else: "+"
    "#{sign}#{Decimal.round(decimal, 2) |> Decimal.to_string(:normal)}"
  end

  defp pnl_color(nil), do: "text-zinc-400"

  defp pnl_color(decimal) do
    case Decimal.compare(decimal, Decimal.new(0)) do
      :gt -> "text-green-400"
      :lt -> "text-red-400"
      :eq -> "text-zinc-400"
    end
  end

  defp status_badge(status) do
    case status do
      :target_hit -> {"Target Hit", "bg-green-500/20 text-green-400 border-green-500/30"}
      :stopped_out -> {"Stopped Out", "bg-red-500/20 text-red-400 border-red-500/30"}
      :time_exit -> {"Time Exit", "bg-amber-500/20 text-amber-400 border-amber-500/30"}
      :manual_exit -> {"Manual Exit", "bg-blue-500/20 text-blue-400 border-blue-500/30"}
      :open -> {"Open", "bg-zinc-500/20 text-zinc-400 border-zinc-500/30"}
      _ -> {"Unknown", "bg-zinc-500/20 text-zinc-400 border-zinc-500/30"}
    end
  end

  defp calendar_weeks(month) do
    first_day = Date.beginning_of_month(month)
    last_day = Date.end_of_month(month)

    # Get the day of week for the first day (1 = Monday, 7 = Sunday)
    first_dow = Date.day_of_week(first_day)

    # Adjust to start week on Sunday (0 = Sunday)
    start_padding = rem(first_dow, 7)

    # Calculate start date (might be in previous month)
    start_date = Date.add(first_day, -start_padding)

    # Generate 6 weeks of dates
    Enum.chunk_every(
      Enum.map(0..41, fn offset -> Date.add(start_date, offset) end),
      7
    )
    |> Enum.take_while(fn week ->
      # Only include weeks that have at least one day in the current month
      Enum.any?(week, fn date ->
        Date.compare(date, first_day) != :lt and Date.compare(date, last_day) != :gt
      end)
    end)
  end

  defp date_in_range?(date, nil, _), do: Date.compare(date, Date.utc_today()) != :gt
  defp date_in_range?(date, _, nil), do: Date.compare(date, Date.utc_today()) != :gt

  defp date_in_range?(date, min_date, max_date) do
    Date.compare(date, min_date) != :lt and Date.compare(date, max_date) != :gt
  end

  defp format_time_et(datetime) do
    datetime
    |> DateTime.shift_zone!("America/New_York")
    |> Calendar.strftime("%I:%M %p")
  end

  defp is_trading_day?(date, trading_days) do
    MapSet.member?(trading_days, date)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-zinc-950">
      <Navigation.header
        current_path={"/symbols/#{@symbol}"}
        page_title={@symbol}
        page_subtitle="Symbol Analysis"
        page_icon_color="from-blue-500 to-indigo-600"
      />

      <div class="max-w-[1920px] mx-auto px-4 sm:px-6 lg:px-8 py-8 space-y-6">
        <!-- Calendar - Compact with hover expand -->
        <div class="group relative">
          <!-- Collapsed view - always visible -->
          <div class="bg-zinc-900/50 backdrop-blur-sm rounded-2xl border border-zinc-800 px-6 py-3 flex items-center justify-center gap-2">
            <button
              phx-click="prev_day"
              class="p-2 hover:bg-zinc-800 rounded-lg transition-colors"
              title="Previous trading day"
            >
              <svg class="w-5 h-5 text-zinc-400" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7" />
              </svg>
            </button>
            <div class="flex items-center gap-3 cursor-pointer px-2">
              <svg
                class="w-5 h-5 text-zinc-500"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M8 7V3m8 4V3m-9 8h10M5 21h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z"
                />
              </svg>
              <span class="text-lg font-semibold text-white">
                {Calendar.strftime(@selected_date, "%A, %B %d, %Y")}
              </span>
              <svg
                class="w-4 h-4 text-zinc-500 transition-transform group-hover:rotate-180"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M19 9l-7 7-7-7"
                />
              </svg>
            </div>
            <button
              phx-click="next_day"
              class="p-2 hover:bg-zinc-800 rounded-lg transition-colors"
              title="Next trading day"
            >
              <svg class="w-5 h-5 text-zinc-400" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5l7 7-7 7" />
              </svg>
            </button>
          </div>
          
    <!-- Expanded calendar - shows on hover -->
          <div class="absolute left-1/2 -translate-x-1/2 top-full mt-2 z-50 opacity-0 invisible group-hover:opacity-100 group-hover:visible transition-all duration-200 ease-out">
            <div class="bg-zinc-900 backdrop-blur-sm rounded-2xl border border-zinc-700 p-4 shadow-2xl min-w-[320px]">
              <div class="flex items-center justify-between mb-4">
                <button
                  phx-click="prev_month"
                  class="p-2 hover:bg-zinc-800 rounded-lg transition-colors"
                >
                  <svg
                    class="w-5 h-5 text-zinc-400"
                    fill="none"
                    viewBox="0 0 24 24"
                    stroke="currentColor"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M15 19l-7-7 7-7"
                    />
                  </svg>
                </button>
                <h3 class="text-lg font-semibold text-white">
                  {Calendar.strftime(@calendar_month, "%B %Y")}
                </h3>
                <button
                  phx-click="next_month"
                  class="p-2 hover:bg-zinc-800 rounded-lg transition-colors"
                >
                  <svg
                    class="w-5 h-5 text-zinc-400"
                    fill="none"
                    viewBox="0 0 24 24"
                    stroke="currentColor"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M9 5l7 7-7 7"
                    />
                  </svg>
                </button>
              </div>
              
    <!-- Day headers -->
              <div class="grid grid-cols-7 gap-1 mb-2">
                <div
                  :for={day <- ~w[S M T W T F S]}
                  class="text-center text-xs font-medium text-zinc-500 py-1"
                >
                  {day}
                </div>
              </div>
              
    <!-- Calendar grid -->
              <div class="space-y-1">
                <div :for={week <- calendar_weeks(@calendar_month)} class="grid grid-cols-7 gap-1">
                  <button
                    :for={date <- week}
                    phx-click="select_date"
                    phx-value-date={Date.to_iso8601(date)}
                    disabled={
                      !date_in_range?(date, @min_date, @max_date) ||
                        !is_trading_day?(date, @trading_days)
                    }
                    class={[
                      "w-9 h-9 text-sm rounded-lg transition-all duration-200 flex items-center justify-center",
                      date.month == @calendar_month.month && "text-white",
                      date.month != @calendar_month.month && "text-zinc-600",
                      date == @selected_date &&
                        "bg-blue-600 text-white font-semibold ring-2 ring-blue-500",
                      date != @selected_date && is_trading_day?(date, @trading_days) &&
                        date_in_range?(date, @min_date, @max_date) &&
                        "bg-green-500/10 hover:bg-green-500/20 border border-green-500/30",
                      !is_trading_day?(date, @trading_days) && "opacity-30 cursor-not-allowed",
                      !date_in_range?(date, @min_date, @max_date) && "opacity-30 cursor-not-allowed"
                    ]}
                  >
                    {date.day}
                  </button>
                </div>
              </div>
            </div>
          </div>
        </div>
        
    <!-- Chart - Full Width -->
        <div class="bg-zinc-900/50 backdrop-blur-sm rounded-2xl border border-zinc-800 overflow-hidden shadow-2xl">
          <!-- Chart Header -->
          <div class="px-6 py-4 border-b border-zinc-800 bg-zinc-900/80">
            <div class="flex items-center justify-between">
              <div>
                <h2 class="text-2xl font-bold text-white">{@symbol}</h2>
                <p class="text-sm text-zinc-500">
                  {Calendar.strftime(@selected_date, "%A, %B %d, %Y")}
                </p>
              </div>
            </div>
          </div>
          
    <!-- Chart Container -->
          <div
            id="symbol-chart"
            phx-hook="SymbolChart"
            phx-update="ignore"
            data-symbol={@symbol}
            data-initial-bars={Jason.encode!(format_bars_for_chart(@bars))}
            data-trades={Jason.encode!(format_trades_for_chart(@trades))}
            data-levels={Jason.encode!(format_levels_for_chart(@key_levels))}
            class="w-full min-h-[600px]"
          >
          </div>
          
    <!-- Chart Footer -->
          <%= if length(@bars) > 0 do %>
            <% first_bar = List.first(@bars) %>
            <% last_bar = List.last(@bars) %>
            <div class="px-6 py-4 bg-zinc-900/80 border-t border-zinc-800">
              <div class="grid grid-cols-4 gap-4 text-center">
                <div>
                  <div class="text-xs text-zinc-500 mb-1">OPEN</div>
                  <div class="text-sm font-mono font-semibold text-zinc-300">
                    ${format_price(first_bar.open)}
                  </div>
                </div>
                <div>
                  <div class="text-xs text-zinc-500 mb-1">HIGH</div>
                  <div class="text-sm font-mono font-semibold text-green-400">
                    ${format_price(Enum.max_by(@bars, &Decimal.to_float(&1.high)).high)}
                  </div>
                </div>
                <div>
                  <div class="text-xs text-zinc-500 mb-1">LOW</div>
                  <div class="text-sm font-mono font-semibold text-red-400">
                    ${format_price(Enum.min_by(@bars, &Decimal.to_float(&1.low)).low)}
                  </div>
                </div>
                <div>
                  <div class="text-xs text-zinc-500 mb-1">CLOSE</div>
                  <div class="text-sm font-mono font-semibold text-zinc-300">
                    ${format_price(last_bar.close)}
                  </div>
                </div>
              </div>
            </div>
          <% end %>
        </div>

    <!-- Run Simulation Button (shown when simulation hasn't been run) -->
        <%= if !@simulation_ran do %>
          <div class="flex justify-center">
            <button
              phx-click="run_simulation"
              class="inline-flex items-center gap-3 px-6 py-3 bg-zinc-800 hover:bg-zinc-700 rounded-xl border border-zinc-700 hover:border-emerald-600 transition-all group"
            >
              <svg
                class="w-5 h-5 text-emerald-500"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M14.752 11.168l-3.197-2.132A1 1 0 0010 9.87v4.263a1 1 0 001.555.832l3.197-2.132a1 1 0 000-1.664z"
                />
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
                />
              </svg>
              <span class="font-medium text-white animate-shimmer">Run break & retest simulation</span>
            </button>
          </div>
        <% end %>

    <!-- Trades - Full Width (only shown after simulation has run) -->
        <%= if @simulation_ran do %>
        <% all_trades = @trades ++ @simulated_trades %>
        <div class="bg-zinc-900/50 backdrop-blur-sm rounded-2xl border border-zinc-800 overflow-hidden">
          <div class="px-6 py-4 border-b border-zinc-800 bg-zinc-900/80">
            <div class="flex items-center justify-between">
              <div class="flex items-baseline gap-3">
                <h3 class="text-lg font-semibold text-white">Trades</h3>
                <%= if length(@simulated_trades) > 0 do %>
                  <span class="px-2 py-0.5 text-xs font-medium bg-blue-500/20 text-blue-400 rounded">
                    {length(@simulated_trades)} simulated
                  </span>
                <% end %>
              </div>
              <%= if length(@simulated_trades) > 0 do %>
                <button
                  phx-click="clear_simulation"
                  class="flex items-center gap-1 px-3 py-1.5 bg-zinc-700 hover:bg-zinc-600 text-zinc-300 text-sm rounded-lg transition-colors"
                >
                  <svg class="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M6 18L18 6M6 6l12 12"
                    />
                  </svg>
                  Clear
                </button>
              <% end %>
            </div>
          </div>

          <%= if Enum.empty?(all_trades) do %>
            <div class="p-8 text-center">
              <p class="text-zinc-500">No break & retest setups found for this date.</p>
            </div>
          <% else %>
            <div class="overflow-x-auto">
              <table class="min-w-full divide-y divide-zinc-800">
                <thead class="bg-zinc-900/50">
                  <tr>
                    <th class="px-4 py-3 text-left text-xs font-medium text-zinc-400 uppercase">
                      Direction
                    </th>
                    <th class="px-4 py-3 text-left text-xs font-medium text-zinc-400 uppercase">
                      Entry Time
                    </th>
                    <th class="px-4 py-3 text-right text-xs font-medium text-zinc-400 uppercase">
                      Entry
                    </th>
                    <th class="px-4 py-3 text-right text-xs font-medium text-zinc-400 uppercase">
                      Stop (1R)
                    </th>
                    <th class="px-4 py-3 text-right text-xs font-medium text-zinc-400 uppercase">
                      Target (2R)
                    </th>
                    <th class="px-4 py-3 text-right text-xs font-medium text-zinc-400 uppercase">
                      Exit
                    </th>
                    <th class="px-4 py-3 text-right text-xs font-medium text-zinc-400 uppercase">
                      R
                    </th>
                    <th class="px-4 py-3 text-center text-xs font-medium text-zinc-400 uppercase">
                      Result
                    </th>
                  </tr>
                </thead>
                <tbody id="trades-table" phx-hook="TradesTable" class="divide-y divide-zinc-800">
                  <tr
                    :for={trade <- all_trades}
                    data-trade-id={trade.id}
                    phx-click="select_trade"
                    phx-value-id={trade.id}
                    class="hover:bg-zinc-800/50 cursor-pointer transition-colors"
                  >
                    <td class="px-4 py-3 whitespace-nowrap">
                      <span class={[
                        "text-xs font-semibold px-2 py-1 rounded",
                        trade.direction == :long && "bg-green-500/20 text-green-400",
                        trade.direction == :short && "bg-red-500/20 text-red-400"
                      ]}>
                        {trade.direction |> to_string() |> String.upcase()}
                      </span>
                    </td>
                    <td class="px-4 py-3 whitespace-nowrap text-sm text-zinc-300">
                      <time data-utc={DateTime.to_unix(trade.entry_time) * 1000}>
                        {format_time_et(trade.entry_time)}
                      </time>
                    </td>
                    <td class="px-4 py-3 whitespace-nowrap text-sm font-mono text-white text-right">
                      {format_price(trade.entry_price)}
                    </td>
                    <td class="px-4 py-3 whitespace-nowrap text-sm font-mono text-red-400 text-right">
                      {format_price(trade.stop_loss)}
                    </td>
                    <td class="px-4 py-3 whitespace-nowrap text-sm font-mono text-green-400 text-right">
                      <%= if trade.take_profit do %>
                        {format_price(trade.take_profit)}
                      <% else %>
                        -
                      <% end %>
                    </td>
                    <td class="px-4 py-3 whitespace-nowrap text-sm font-mono text-zinc-300 text-right">
                      <%= if trade.exit_price do %>
                        {format_price(trade.exit_price)}
                      <% else %>
                        -
                      <% end %>
                    </td>
                    <td class={[
                      "px-4 py-3 whitespace-nowrap text-sm font-mono font-bold text-right",
                      pnl_color(trade.r_multiple)
                    ]}>
                      {format_r(trade.r_multiple)}
                    </td>
                    <td class="px-4 py-3 whitespace-nowrap text-center">
                      <% {status_text, status_class} = status_badge(trade.status) %>
                      <span class={["px-2 py-1 text-xs font-medium rounded border", status_class]}>
                        {status_text}
                      </span>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </div>
        <% end %>
      </div>

    <!-- Trade Detail Modal -->
      <%= if @selected_trade do %>
        <div
          class="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm"
          phx-click="close_trade_details"
        >
          <div
            class="bg-zinc-900 rounded-2xl border border-zinc-700 shadow-2xl max-w-xl w-full mx-4"
            phx-click-away="close_trade_details"
          >
            <div class="px-6 py-4 border-b border-zinc-800 flex items-center justify-between">
              <div class="flex items-center gap-3">
                <h3 class="text-xl font-bold text-white">Trade Details</h3>
                <% {status_text, status_class} = status_badge(@selected_trade.status) %>
                <span class={["px-2 py-1 text-xs font-medium rounded border", status_class]}>
                  {status_text}
                </span>
              </div>
              <button
                phx-click="close_trade_details"
                class="text-zinc-400 hover:text-white transition-colors"
              >
                <svg class="w-6 h-6" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M6 18L18 6M6 6l12 12"
                  />
                </svg>
              </button>
            </div>

            <div class="p-6 space-y-4">
              <!-- Direction & R-Multiple -->
              <div class="flex items-center justify-between">
                <span class={[
                  "text-lg font-bold px-3 py-1 rounded",
                  @selected_trade.direction == :long && "bg-green-500/20 text-green-400",
                  @selected_trade.direction == :short && "bg-red-500/20 text-red-400"
                ]}>
                  {@selected_trade.direction |> to_string() |> String.upcase()}
                </span>
                <div class="text-right">
                  <div class={["text-3xl font-bold font-mono", pnl_color(@selected_trade.r_multiple)]}>
                    {format_r(@selected_trade.r_multiple)}
                  </div>
                  <div class="text-sm text-zinc-500">R-Multiple</div>
                </div>
              </div>
              
    <!-- Trade Chart -->
              <div class="bg-zinc-800/50 rounded-xl p-4">
                <div class="text-xs text-zinc-500 mb-2">PRICE ACTION</div>
                <div
                  id="trade-detail-chart"
                  phx-hook="TradeDetailChart"
                  phx-update="ignore"
                  class="w-full flex justify-center"
                  style="height: 250px;"
                >
                </div>
              </div>
              
    <!-- Price Levels -->
              <div class="bg-zinc-800/50 rounded-xl p-4">
                <div class="grid grid-cols-4 gap-4 text-center">
                  <div>
                    <div class="text-xs text-zinc-500 mb-1">ENTRY</div>
                    <div class="text-lg font-mono font-semibold text-white">
                      {format_price(@selected_trade.entry_price)}
                    </div>
                  </div>
                  <div>
                    <div class="text-xs text-zinc-500 mb-1">STOP (1R)</div>
                    <div class="text-lg font-mono font-semibold text-red-400">
                      {format_price(@selected_trade.stop_loss)}
                    </div>
                  </div>
                  <div>
                    <div class="text-xs text-zinc-500 mb-1">TARGET (2R)</div>
                    <div class="text-lg font-mono font-semibold text-green-400">
                      <%= if @selected_trade.take_profit do %>
                        {format_price(@selected_trade.take_profit)}
                      <% else %>
                        -
                      <% end %>
                    </div>
                  </div>
                  <div>
                    <div class="text-xs text-zinc-500 mb-1">EXIT</div>
                    <div class="text-lg font-mono font-semibold text-zinc-300">
                      <%= if @selected_trade.exit_price do %>
                        {format_price(@selected_trade.exit_price)}
                      <% else %>
                        -
                      <% end %>
                    </div>
                  </div>
                </div>
              </div>
              
    <!-- Key Level (if available) -->
              <%= if Map.get(@selected_trade, :level_type) do %>
                <div class="bg-zinc-800/50 rounded-xl p-4">
                  <div class="flex items-center justify-between">
                    <div>
                      <div class="text-xs text-zinc-500 mb-1">KEY LEVEL</div>
                      <div class="text-sm font-medium text-amber-400">
                        {format_level_type(@selected_trade.level_type)}
                      </div>
                    </div>
                    <div class="text-right">
                      <div class="text-xs text-zinc-500 mb-1">LEVEL PRICE</div>
                      <div class="text-lg font-mono font-semibold text-amber-400">
                        {format_price(@selected_trade.level_price)}
                      </div>
                    </div>
                  </div>
                </div>
              <% end %>
              
    <!-- Times -->
              <div class="grid grid-cols-2 gap-4">
                <div class="bg-zinc-800/50 rounded-xl p-4">
                  <div class="text-xs text-zinc-500 mb-1">ENTRY TIME</div>
                  <div class="text-sm font-medium text-white">
                    {format_time_et(@selected_trade.entry_time)}
                  </div>
                </div>
                <div class="bg-zinc-800/50 rounded-xl p-4">
                  <div class="text-xs text-zinc-500 mb-1">EXIT TIME</div>
                  <div class="text-sm font-medium text-white">
                    <%= if @selected_trade.exit_time do %>
                      {format_time_et(@selected_trade.exit_time)}
                    <% else %>
                      Open
                    <% end %>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
