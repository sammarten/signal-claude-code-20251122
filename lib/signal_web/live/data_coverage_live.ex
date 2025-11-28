defmodule SignalWeb.DataCoverageLive do
  use SignalWeb, :live_view
  require Logger
  import Ecto.Query
  alias SignalWeb.Live.Components.Navigation
  alias Signal.Alpaca.Client, as: AlpacaClient
  alias Signal.MarketData.Bar
  alias Signal.MarketData.GapFiller
  alias Signal.Repo

  @moduledoc """
  Data coverage visualization showing a GitHub-style heatmap of bar data completeness.

  Displays a calendar grid where each cell represents a trading day, colored by
  data coverage percentage. Helps identify gaps in historical data.

  Uses Alpaca's market calendar API for accurate trading day and market hours data.
  """

  @impl true
  def mount(_params, _session, socket) do
    symbols = Application.get_env(:signal, :symbols, [])
    current_year = Date.utc_today().year

    socket =
      assign(socket,
        symbols: symbols,
        selected_symbol: List.first(symbols) || "AAPL",
        selected_year: current_year,
        available_years: (current_year - 5)..current_year |> Enum.to_list() |> Enum.reverse(),
        coverage_data: %{},
        loading: false,
        filling_gaps: false,
        fill_result: nil,
        stats: nil,
        calendar_error: nil
      )

    # Only load data when connected to avoid duplicate API calls
    socket = if connected?(socket), do: load_coverage_data(socket), else: socket

    {:ok, socket}
  end

  @impl true
  def handle_event("update_filters", %{"symbol" => symbol, "year" => year}, socket) do
    {:noreply,
     socket
     |> assign(selected_symbol: symbol, selected_year: String.to_integer(year), fill_result: nil)
     |> load_coverage_data()}
  end

  @impl true
  def handle_event("fill_gaps", _params, socket) do
    symbol = socket.assigns.selected_symbol
    coverage_data = socket.assigns.coverage_data
    parent = self()

    Task.start(fn ->
      # Use the optimized fill_from_coverage which batches contiguous missing days
      result = GapFiller.fill_from_coverage(symbol, coverage_data, threshold: 99)
      send(parent, {:fill_complete, result})
    end)

    {:noreply, assign(socket, filling_gaps: true, fill_result: nil)}
  end

  @impl true
  def handle_info({:fill_complete, result}, socket) do
    {:noreply,
     socket
     |> assign(filling_gaps: false, fill_result: result)
     |> load_coverage_data()}
  end

  defp load_coverage_data(socket) do
    symbol = socket.assigns.selected_symbol
    year = socket.assigns.selected_year

    {coverage_data, stats, calendar_error} = fetch_coverage_data(symbol, year)

    assign(socket,
      coverage_data: coverage_data,
      stats: stats,
      loading: false,
      calendar_error: calendar_error
    )
  end

  defp fetch_coverage_data(symbol, year) do
    start_date = Date.new!(year, 1, 1)
    year_end = Date.new!(year, 12, 31)
    today = Date.utc_today()
    end_date = if Date.compare(year_end, today) == :gt, do: today, else: year_end

    # Fetch trading calendar from Alpaca API
    {trading_calendar, calendar_error} = fetch_trading_calendar(start_date, end_date)

    # Query bar counts per day
    bar_counts =
      from(b in Bar,
        where: b.symbol == ^symbol,
        where: fragment("?::date", b.bar_time) >= ^start_date,
        where: fragment("?::date", b.bar_time) <= ^end_date,
        group_by: fragment("?::date", b.bar_time),
        select: {fragment("?::date", b.bar_time), count(b.bar_time)}
      )
      |> Repo.all()
      |> Map.new()

    Logger.debug("[DataCoverage] Found bar data for #{map_size(bar_counts)} days for #{symbol}")

    # Build coverage map for each trading day
    coverage_data =
      trading_calendar
      |> Enum.map(fn day ->
        expected = calculate_expected_bars(day.open, day.close)
        actual = Map.get(bar_counts, day.date, 0)
        coverage_pct = if expected > 0, do: min(100.0, actual / expected * 100), else: 0.0
        is_half_day = Time.compare(day.close, ~T[14:00:00]) == :lt

        {day.date,
         %{
           actual: actual,
           expected: expected,
           coverage_pct: coverage_pct,
           is_half_day: is_half_day,
           open: day.open,
           close: day.close
         }}
      end)
      |> Map.new()

    # Calculate stats
    total_trading_days = length(trading_calendar)
    days_with_full_data = Enum.count(coverage_data, fn {_, v} -> v.coverage_pct >= 99 end)

    days_with_partial_data =
      Enum.count(coverage_data, fn {_, v} -> v.coverage_pct > 0 and v.coverage_pct < 99 end)

    days_missing = Enum.count(coverage_data, fn {_, v} -> v.coverage_pct == 0 end)
    total_bars = Enum.sum(Enum.map(coverage_data, fn {_, v} -> v.actual end))
    expected_bars = Enum.sum(Enum.map(coverage_data, fn {_, v} -> v.expected end))

    stats = %{
      total_trading_days: total_trading_days,
      days_with_full_data: days_with_full_data,
      days_with_partial_data: days_with_partial_data,
      days_missing: days_missing,
      total_bars: total_bars,
      expected_bars: expected_bars,
      coverage_pct:
        if(expected_bars > 0, do: Float.round(total_bars / expected_bars * 100, 1), else: 0)
    }

    {coverage_data, stats, calendar_error}
  end

  defp fetch_trading_calendar(start_date, end_date) do
    Logger.debug("[DataCoverage] Fetching calendar from #{start_date} to #{end_date}")

    case AlpacaClient.get_calendar(start: start_date, end: end_date) do
      {:ok, calendar} ->
        Logger.debug("[DataCoverage] Got #{length(calendar)} trading days from calendar API")
        {calendar, nil}

      {:error, reason} ->
        Logger.error("[DataCoverage] Failed to fetch trading calendar: #{inspect(reason)}")
        {[], "Failed to fetch trading calendar from Alpaca API: #{inspect(reason)}"}
    end
  end

  defp calculate_expected_bars(open_time, close_time) do
    # Calculate minutes between open and close
    open_minutes = Time.diff(open_time, ~T[00:00:00], :minute)
    close_minutes = Time.diff(close_time, ~T[00:00:00], :minute)
    close_minutes - open_minutes
  end

  # Generate weeks for the heatmap grid (GitHub style: columns are weeks)
  defp generate_weeks(year, coverage_data) do
    start_date = Date.new!(year, 1, 1)
    end_date = Date.new!(year, 12, 31)
    today = Date.utc_today()

    # Start from the first Sunday on or before Jan 1
    first_sunday = Date.add(start_date, -Date.day_of_week(start_date))

    # Generate all weeks
    Stream.iterate(first_sunday, &Date.add(&1, 7))
    |> Enum.take_while(fn week_start -> Date.compare(week_start, end_date) != :gt end)
    |> Enum.map(fn week_start ->
      # Generate 7 days for this week (Sun-Sat, but we'll show Mon, Wed, Fri labels)
      days =
        0..6
        |> Enum.map(fn day_offset ->
          date = Date.add(week_start, day_offset)
          in_year = date.year == year
          in_future = Date.compare(date, today) == :gt

          coverage = Map.get(coverage_data, date)

          %{
            date: date,
            in_year: in_year,
            in_future: in_future,
            coverage: coverage,
            day_of_week: Date.day_of_week(date)
          }
        end)

      %{week_start: week_start, days: days}
    end)
  end

  # Non-trading day
  defp coverage_color(nil), do: "bg-zinc-800"

  defp coverage_color(%{coverage_pct: pct}) do
    cond do
      pct >= 99 -> "bg-green-500"
      pct >= 75 -> "bg-green-600"
      pct >= 50 -> "bg-yellow-500"
      pct >= 25 -> "bg-orange-500"
      pct > 0 -> "bg-red-500"
      # Missing data
      true -> "bg-zinc-700"
    end
  end

  defp month_labels(year) do
    # Calculate which week column each month starts in
    first_sunday = Date.add(Date.new!(year, 1, 1), -Date.day_of_week(Date.new!(year, 1, 1)))

    1..12
    |> Enum.map(fn month ->
      first_of_month = Date.new!(year, month, 1)
      days_since_start = Date.diff(first_of_month, first_sunday)
      week_index = div(days_since_start, 7)

      %{
        month: month,
        name: Calendar.strftime(first_of_month, "%b"),
        week_index: week_index
      }
    end)
  end

  @impl true
  def render(assigns) do
    weeks = generate_weeks(assigns.selected_year, assigns.coverage_data)
    months = month_labels(assigns.selected_year)
    assigns = assign(assigns, weeks: weeks, months: months)

    ~H"""
    <div class="min-h-screen bg-gradient-to-br from-zinc-950 via-zinc-900 to-zinc-950">
      <Navigation.header
        current_path="/data/coverage"
        page_title="Data Coverage"
        page_subtitle="Historical bar data completeness"
        page_icon_color="from-cyan-500 to-blue-600"
      />

      <div class="max-w-[1920px] mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <!-- Controls -->
        <form phx-change="update_filters" class="flex items-center gap-4 mb-8">
          <div class="flex items-center gap-2">
            <label class="text-sm text-zinc-400">Symbol:</label>
            <select
              name="symbol"
              class="bg-zinc-800 border border-zinc-700 rounded-lg px-3 py-2 text-white text-sm focus:ring-2 focus:ring-cyan-500 focus:border-transparent"
            >
              <%= for symbol <- @symbols do %>
                <option value={symbol} selected={symbol == @selected_symbol}>{symbol}</option>
              <% end %>
            </select>
          </div>

          <div class="flex items-center gap-2">
            <label class="text-sm text-zinc-400">Year:</label>
            <select
              name="year"
              class="bg-zinc-800 border border-zinc-700 rounded-lg px-3 py-2 text-white text-sm focus:ring-2 focus:ring-cyan-500 focus:border-transparent"
            >
              <%= for year <- @available_years do %>
                <option value={year} selected={year == @selected_year}>{year}</option>
              <% end %>
            </select>
          </div>

          <button
            type="button"
            phx-click="fill_gaps"
            disabled={@filling_gaps}
            class={[
              "px-4 py-2 rounded-lg text-sm font-medium transition-colors",
              if(@filling_gaps,
                do: "bg-zinc-700 text-zinc-400 cursor-not-allowed",
                else: "bg-cyan-600 hover:bg-cyan-500 text-white"
              )
            ]}
          >
            <%= if @filling_gaps do %>
              <span class="flex items-center gap-2">
                <svg
                  class="animate-spin h-4 w-4"
                  xmlns="http://www.w3.org/2000/svg"
                  fill="none"
                  viewBox="0 0 24 24"
                >
                  <circle
                    class="opacity-25"
                    cx="12"
                    cy="12"
                    r="10"
                    stroke="currentColor"
                    stroke-width="4"
                  >
                  </circle>
                  <path
                    class="opacity-75"
                    fill="currentColor"
                    d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
                  >
                  </path>
                </svg>
                Filling gaps...
              </span>
            <% else %>
              Fill Gaps
            <% end %>
          </button>

          <%= if @fill_result do %>
            <span class={[
              "text-sm px-3 py-1 rounded-lg",
              case @fill_result do
                {:ok, 0} -> "bg-zinc-700 text-zinc-300"
                {:ok, _} -> "bg-green-900/50 text-green-400"
                {:error, _} -> "bg-red-900/50 text-red-400"
              end
            ]}>
              <%= case @fill_result do %>
                <% {:ok, 0} -> %>
                  No gaps found
                <% {:ok, n} -> %>
                  Filled {n} bars
                <% {:error, reason} -> %>
                  Error: {inspect(reason)}
              <% end %>
            </span>
          <% end %>
        </form>
        
    <!-- Calendar API Error -->
        <%= if @calendar_error do %>
          <div class="mb-4 p-4 bg-red-900/30 border border-red-500/50 rounded-lg text-red-400">
            <div class="flex items-center gap-2">
              <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"
                />
              </svg>
              <span>{@calendar_error}</span>
            </div>
            <p class="mt-2 text-sm text-red-300">
              Make sure Alpaca API credentials are configured. Run
              <code class="bg-red-900/50 px-1 rounded">source .env</code>
              before starting the server.
            </p>
          </div>
        <% end %>
        
    <!-- Stats -->
        <%= if @stats do %>
          <div class="grid grid-cols-2 md:grid-cols-4 lg:grid-cols-7 gap-4 mb-8">
            <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-4">
              <div class="text-2xl font-bold text-white">{@stats.coverage_pct}%</div>
              <div class="text-xs text-zinc-400">Overall Coverage</div>
            </div>
            <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-4">
              <div class="text-2xl font-bold text-green-400">{@stats.days_with_full_data}</div>
              <div class="text-xs text-zinc-400">Full Days</div>
            </div>
            <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-4">
              <div class="text-2xl font-bold text-yellow-400">{@stats.days_with_partial_data}</div>
              <div class="text-xs text-zinc-400">Partial Days</div>
            </div>
            <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-4">
              <div class="text-2xl font-bold text-red-400">{@stats.days_missing}</div>
              <div class="text-xs text-zinc-400">Missing Days</div>
            </div>
            <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-4">
              <div class="text-2xl font-bold text-white">{@stats.total_trading_days}</div>
              <div class="text-xs text-zinc-400">Trading Days</div>
            </div>
            <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-4">
              <div class="text-2xl font-bold text-white">{format_number(@stats.total_bars)}</div>
              <div class="text-xs text-zinc-400">Total Bars</div>
            </div>
            <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-4">
              <div class="text-2xl font-bold text-zinc-400">
                {format_number(@stats.expected_bars)}
              </div>
              <div class="text-xs text-zinc-400">Expected Bars</div>
            </div>
          </div>
        <% end %>
        
    <!-- Heatmap -->
        <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-6">
          <div class="flex items-start gap-2">
            <!-- Day labels (Mon, Wed, Fri) -->
            <div class="flex flex-col gap-[3px] text-xs text-zinc-500 pt-5">
              <div class="h-[11px]"></div>
              <div class="h-[11px] flex items-center">Mon</div>
              <div class="h-[11px]"></div>
              <div class="h-[11px] flex items-center">Wed</div>
              <div class="h-[11px]"></div>
              <div class="h-[11px] flex items-center">Fri</div>
              <div class="h-[11px]"></div>
            </div>
            
    <!-- Grid -->
            <div class="flex-1 overflow-x-auto">
              <!-- Month labels -->
              <div class="flex gap-[3px] mb-1 text-xs text-zinc-500 relative h-4">
                <%= for month <- @months do %>
                  <div
                    class="absolute"
                    style={"left: #{month.week_index * 14}px"}
                  >
                    {month.name}
                  </div>
                <% end %>
              </div>
              
    <!-- Week columns -->
              <div class="flex gap-[3px]">
                <%= for week <- @weeks do %>
                  <div class="flex flex-col gap-[3px]">
                    <%= for day <- week.days do %>
                      <div
                        class={[
                          "w-[11px] h-[11px] rounded-sm",
                          cond do
                            not day.in_year -> "bg-transparent"
                            day.in_future -> "bg-zinc-800/50"
                            day.day_of_week in [6, 7] -> "bg-zinc-800/30"
                            true -> coverage_color(day.coverage)
                          end
                        ]}
                        title={format_tooltip(day)}
                      >
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>
            </div>
          </div>
          
    <!-- Legend -->
          <div class="flex items-center justify-end gap-2 mt-4 text-xs text-zinc-500">
            <span>Less</span>
            <div class="w-[11px] h-[11px] rounded-sm bg-zinc-700" title="No data"></div>
            <div class="w-[11px] h-[11px] rounded-sm bg-red-500" title="< 25%"></div>
            <div class="w-[11px] h-[11px] rounded-sm bg-orange-500" title="25-49%"></div>
            <div class="w-[11px] h-[11px] rounded-sm bg-yellow-500" title="50-74%"></div>
            <div class="w-[11px] h-[11px] rounded-sm bg-green-600" title="75-98%"></div>
            <div class="w-[11px] h-[11px] rounded-sm bg-green-500" title="99-100%"></div>
            <span>More</span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp format_tooltip(day) do
    cond do
      not day.in_year ->
        ""

      day.in_future ->
        "#{Date.to_string(day.date)} (future)"

      day.day_of_week in [6, 7] ->
        "#{Date.to_string(day.date)} (weekend)"

      day.coverage == nil ->
        "#{Date.to_string(day.date)} (holiday)"

      true ->
        c = day.coverage
        hours = format_market_hours(c.open, c.close)

        "#{Date.to_string(day.date)} #{hours}: #{c.actual}/#{c.expected} bars (#{Float.round(c.coverage_pct, 1)}%)"
    end
  end

  defp format_market_hours(open, close) do
    open_str = Calendar.strftime(open, "%-I:%M%P")
    close_str = Calendar.strftime(close, "%-I:%M%P")
    "(#{open_str}-#{close_str})"
  end

  defp format_number(number) when is_integer(number) do
    number
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  defp format_number(number), do: to_string(number)
end
