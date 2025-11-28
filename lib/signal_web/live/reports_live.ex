defmodule SignalWeb.ReportsLive do
  use SignalWeb, :live_view

  alias SignalWeb.Live.Components.Navigation
  alias Signal.Backtest.BacktestRun
  alias Signal.Backtest.SimulatedTrade
  alias Signal.Analytics.BacktestResult
  alias Signal.Repo

  import Ecto.Query
  import SignalWeb.Live.Helpers.Formatters

  @moduledoc """
  Reports dashboard for detailed performance analysis of backtest results.

  Features:
  - Backtest run selector
  - Time-based performance analysis (by time slot, weekday, month)
  - Signal analysis (by grade, strategy, symbol)
  - Trade explorer with export
  """

  @impl true
  def mount(_params, _session, socket) do
    completed_runs = load_completed_runs()

    {:ok,
     assign(socket,
       # Page info
       page_title: "Reports",
       page_subtitle: "Detailed performance analysis",
       current_path: "/reports",

       # Selection
       completed_runs: completed_runs,
       selected_run_id: nil,

       # Results data
       backtest_run: nil,
       backtest_result: nil,
       trades: [],

       # Analysis data
       time_analysis: nil,
       signal_analysis: nil,

       # UI state
       active_tab: :overview
     )}
  end

  @impl true
  def handle_event("select_run", %{"run_id" => run_id}, socket) do
    case load_run_data(run_id) do
      {:ok, data} ->
        {:noreply,
         assign(socket,
           selected_run_id: run_id,
           backtest_run: data.run,
           backtest_result: data.result,
           trades: data.trades,
           time_analysis: data.result && data.result.time_analysis,
           signal_analysis: data.result && data.result.signal_analysis
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to load backtest data")}
    end
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, String.to_existing_atom(tab))}
  end

  @impl true
  def handle_event("export_trades", _params, socket) do
    # TODO: Implement CSV export
    {:noreply, put_flash(socket, :info, "Export functionality coming soon")}
  end

  # Private helpers

  defp load_completed_runs do
    BacktestRun
    |> where([r], r.status == :completed)
    |> order_by([r], desc: r.completed_at)
    |> limit(50)
    |> Repo.all()
  end

  defp load_run_data(run_id) do
    case Repo.get(BacktestRun, run_id) do
      nil ->
        {:error, :not_found}

      run ->
        result = Repo.get_by(BacktestResult, backtest_run_id: run_id)

        trades =
          SimulatedTrade
          |> where([t], t.backtest_run_id == ^run_id)
          |> order_by([t], desc: t.entry_time)
          |> Repo.all()

        {:ok, %{run: run, result: result, trades: trades}}
    end
  end

  defp weekday_name(day) when is_binary(day), do: String.capitalize(day)
  defp weekday_name(day) when is_atom(day), do: Atom.to_string(day) |> String.capitalize()
  defp weekday_name(_), do: "-"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-zinc-950">
      <Navigation.header
        current_path={@current_path}
        page_title={@page_title}
        page_subtitle={@page_subtitle}
        page_icon_color="from-teal-500 to-cyan-600"
      />

      <div class="max-w-[1920px] mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <!-- Run Selector -->
        <div class="mb-6">
          <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-4">
            <div class="flex items-center gap-4">
              <label class="text-sm text-zinc-400">Select Backtest Run:</label>
              <select
                phx-change="select_run"
                name="run_id"
                class="flex-1 max-w-md bg-zinc-800 border border-zinc-700 rounded-lg px-3 py-2 text-white"
              >
                <option value="">Choose a backtest run...</option>
                <%= for run <- @completed_runs do %>
                  <option value={run.id} selected={run.id == @selected_run_id}>
                    {format_datetime(run.completed_at)} - {Enum.join(run.symbols, ", ")} ({format_date(
                      run.start_date
                    )} to {format_date(run.end_date)})
                  </option>
                <% end %>
              </select>
            </div>
          </div>
        </div>

        <%= if @backtest_result do %>
          <!-- Tab Navigation -->
          <div class="flex gap-2 mb-6">
            <button
              phx-click="switch_tab"
              phx-value-tab="overview"
              class={[
                "px-4 py-2 rounded-lg text-sm font-medium transition-colors",
                if(@active_tab == :overview,
                  do: "bg-teal-500/20 text-teal-400",
                  else: "text-zinc-400 hover:text-white"
                )
              ]}
            >
              Overview
            </button>
            <button
              phx-click="switch_tab"
              phx-value-tab="time"
              class={[
                "px-4 py-2 rounded-lg text-sm font-medium transition-colors",
                if(@active_tab == :time,
                  do: "bg-teal-500/20 text-teal-400",
                  else: "text-zinc-400 hover:text-white"
                )
              ]}
            >
              Time Analysis
            </button>
            <button
              phx-click="switch_tab"
              phx-value-tab="signals"
              class={[
                "px-4 py-2 rounded-lg text-sm font-medium transition-colors",
                if(@active_tab == :signals,
                  do: "bg-teal-500/20 text-teal-400",
                  else: "text-zinc-400 hover:text-white"
                )
              ]}
            >
              Signal Analysis
            </button>
            <button
              phx-click="switch_tab"
              phx-value-tab="trades"
              class={[
                "px-4 py-2 rounded-lg text-sm font-medium transition-colors",
                if(@active_tab == :trades,
                  do: "bg-teal-500/20 text-teal-400",
                  else: "text-zinc-400 hover:text-white"
                )
              ]}
            >
              Trade Explorer
            </button>
          </div>
          
    <!-- Overview Tab -->
          <div :if={@active_tab == :overview}>
            <!-- Summary Metrics Grid -->
            <div class="grid grid-cols-2 md:grid-cols-4 lg:grid-cols-6 gap-4 mb-6">
              <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-4">
                <div class="text-xs text-zinc-500 mb-1">Net Profit</div>
                <div class={"text-2xl font-bold #{if @backtest_result.net_profit && Decimal.positive?(@backtest_result.net_profit), do: "text-green-400", else: "text-red-400"}"}>
                  {format_currency(@backtest_result.net_profit)}
                </div>
              </div>
              <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-4">
                <div class="text-xs text-zinc-500 mb-1">Win Rate</div>
                <div class="text-2xl font-bold text-white">
                  {format_pct(@backtest_result.win_rate)}
                </div>
              </div>
              <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-4">
                <div class="text-xs text-zinc-500 mb-1">Profit Factor</div>
                <div class="text-2xl font-bold text-amber-400">
                  {format_decimal(@backtest_result.profit_factor)}
                </div>
              </div>
              <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-4">
                <div class="text-xs text-zinc-500 mb-1">Total Trades</div>
                <div class="text-2xl font-bold text-white">{@backtest_result.total_trades}</div>
              </div>
              <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-4">
                <div class="text-xs text-zinc-500 mb-1">Max Drawdown</div>
                <div class="text-2xl font-bold text-red-400">
                  {format_pct(@backtest_result.max_drawdown_pct)}
                </div>
              </div>
              <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-4">
                <div class="text-xs text-zinc-500 mb-1">Sharpe Ratio</div>
                <div class="text-2xl font-bold text-teal-400">
                  {format_decimal(@backtest_result.sharpe_ratio)}
                </div>
              </div>
            </div>
            
    <!-- Detailed Metrics -->
            <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
              <!-- Trade Stats -->
              <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-6">
                <h3 class="text-lg font-bold text-white mb-4">Trade Statistics</h3>
                <div class="space-y-3">
                  <div class="flex justify-between">
                    <span class="text-zinc-400">Winners</span>
                    <span class="text-green-400">{@backtest_result.winners}</span>
                  </div>
                  <div class="flex justify-between">
                    <span class="text-zinc-400">Losers</span>
                    <span class="text-red-400">{@backtest_result.losers}</span>
                  </div>
                  <div class="flex justify-between">
                    <span class="text-zinc-400">Breakeven</span>
                    <span class="text-zinc-300">{@backtest_result.breakeven}</span>
                  </div>
                  <div class="flex justify-between border-t border-zinc-800 pt-3">
                    <span class="text-zinc-400">Avg Win</span>
                    <span class="text-green-400">{format_currency(@backtest_result.avg_win)}</span>
                  </div>
                  <div class="flex justify-between">
                    <span class="text-zinc-400">Avg Loss</span>
                    <span class="text-red-400">{format_currency(@backtest_result.avg_loss)}</span>
                  </div>
                  <div class="flex justify-between">
                    <span class="text-zinc-400">Expectancy</span>
                    <span class="text-amber-400">{format_currency(@backtest_result.expectancy)}</span>
                  </div>
                </div>
              </div>
              
    <!-- R-Multiple Stats -->
              <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-6">
                <h3 class="text-lg font-bold text-white mb-4">R-Multiple Analysis</h3>
                <div class="space-y-3">
                  <div class="flex justify-between">
                    <span class="text-zinc-400">Avg R-Multiple</span>
                    <span class="text-white">{format_decimal(@backtest_result.avg_r_multiple)}R</span>
                  </div>
                  <div class="flex justify-between">
                    <span class="text-zinc-400">Max R-Multiple</span>
                    <span class="text-green-400">
                      {format_decimal(@backtest_result.max_r_multiple)}R
                    </span>
                  </div>
                  <div class="flex justify-between">
                    <span class="text-zinc-400">Min R-Multiple</span>
                    <span class="text-red-400">
                      {format_decimal(@backtest_result.min_r_multiple)}R
                    </span>
                  </div>
                  <div class="flex justify-between border-t border-zinc-800 pt-3">
                    <span class="text-zinc-400">Max Consecutive Wins</span>
                    <span class="text-green-400">{@backtest_result.max_consecutive_wins}</span>
                  </div>
                  <div class="flex justify-between">
                    <span class="text-zinc-400">Max Consecutive Losses</span>
                    <span class="text-red-400">{@backtest_result.max_consecutive_losses}</span>
                  </div>
                  <div class="flex justify-between">
                    <span class="text-zinc-400">Sortino Ratio</span>
                    <span class="text-teal-400">
                      {format_decimal(@backtest_result.sortino_ratio)}
                    </span>
                  </div>
                </div>
              </div>
            </div>
          </div>
          
    <!-- Time Analysis Tab -->
          <div :if={@active_tab == :time}>
            <%= if @time_analysis do %>
              <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
                <!-- By Time Slot -->
                <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-6">
                  <h3 class="text-lg font-bold text-white mb-4">By Time Slot</h3>
                  <div class="space-y-2">
                    <%= for {slot, stats} <- @time_analysis["by_time_slot"] || %{} do %>
                      <div class="flex items-center justify-between text-sm">
                        <span class="text-zinc-400">{slot}</span>
                        <div class="flex items-center gap-3">
                          <span class="text-zinc-300">{stats["count"]} trades</span>
                          <span class={"font-mono #{if String.to_float(stats["win_rate"] || "0") > 50, do: "text-green-400", else: "text-red-400"}"}>
                            {stats["win_rate"]}%
                          </span>
                        </div>
                      </div>
                    <% end %>
                  </div>
                  <div
                    :if={@time_analysis["best_time_slot"]}
                    class="mt-4 pt-4 border-t border-zinc-800"
                  >
                    <div class="text-xs text-zinc-500">Best Slot</div>
                    <div class="text-green-400 font-medium">{@time_analysis["best_time_slot"]}</div>
                  </div>
                </div>
                
    <!-- By Weekday -->
                <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-6">
                  <h3 class="text-lg font-bold text-white mb-4">By Weekday</h3>
                  <div class="space-y-2">
                    <%= for {day, stats} <- @time_analysis["by_weekday"] || %{} do %>
                      <div class="flex items-center justify-between text-sm">
                        <span class="text-zinc-400">{weekday_name(day)}</span>
                        <div class="flex items-center gap-3">
                          <span class="text-zinc-300">{stats["count"]} trades</span>
                          <span class={"font-mono #{if String.to_float(stats["win_rate"] || "0") > 50, do: "text-green-400", else: "text-red-400"}"}>
                            {stats["win_rate"]}%
                          </span>
                        </div>
                      </div>
                    <% end %>
                  </div>
                  <div :if={@time_analysis["best_weekday"]} class="mt-4 pt-4 border-t border-zinc-800">
                    <div class="text-xs text-zinc-500">Best Day</div>
                    <div class="text-green-400 font-medium">
                      {weekday_name(@time_analysis["best_weekday"])}
                    </div>
                  </div>
                </div>
                
    <!-- By Month -->
                <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-6">
                  <h3 class="text-lg font-bold text-white mb-4">By Month</h3>
                  <div class="space-y-2">
                    <%= for {month, stats} <- @time_analysis["by_month"] || %{} do %>
                      <div class="flex items-center justify-between text-sm">
                        <span class="text-zinc-400">{month}</span>
                        <div class="flex items-center gap-3">
                          <span class="text-zinc-300">{stats["count"]} trades</span>
                          <span class={"font-mono #{if String.to_float(stats["win_rate"] || "0") > 50, do: "text-green-400", else: "text-red-400"}"}>
                            {stats["win_rate"]}%
                          </span>
                        </div>
                      </div>
                    <% end %>
                  </div>
                </div>
              </div>
            <% else %>
              <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-8 text-center">
                <p class="text-zinc-500">No time analysis data available for this backtest.</p>
              </div>
            <% end %>
          </div>
          
    <!-- Signal Analysis Tab -->
          <div :if={@active_tab == :signals}>
            <%= if @signal_analysis do %>
              <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
                <!-- By Grade -->
                <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-6">
                  <h3 class="text-lg font-bold text-white mb-4">By Signal Grade</h3>
                  <div class="space-y-2">
                    <%= for {grade, stats} <- @signal_analysis["by_grade"] || %{} do %>
                      <div class="flex items-center justify-between text-sm">
                        <span class={"font-bold #{grade_color(grade)}"}>{grade}</span>
                        <div class="flex items-center gap-4">
                          <span class="text-zinc-300">{stats["count"]} trades</span>
                          <span class={"font-mono #{if String.to_float(stats["win_rate"] || "0") > 50, do: "text-green-400", else: "text-red-400"}"}>
                            {stats["win_rate"]}%
                          </span>
                          <span class="text-amber-400 font-mono">{stats["avg_r"]}R</span>
                        </div>
                      </div>
                    <% end %>
                  </div>
                </div>
                
    <!-- By Strategy -->
                <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-6">
                  <h3 class="text-lg font-bold text-white mb-4">By Strategy</h3>
                  <div class="space-y-2">
                    <%= for {strategy, stats} <- @signal_analysis["by_strategy"] || %{} do %>
                      <div class="flex items-center justify-between text-sm">
                        <span class="text-zinc-400">{strategy_name(strategy)}</span>
                        <div class="flex items-center gap-4">
                          <span class="text-zinc-300">{stats["count"]} trades</span>
                          <span class={"font-mono #{if String.to_float(stats["win_rate"] || "0") > 50, do: "text-green-400", else: "text-red-400"}"}>
                            {stats["win_rate"]}%
                          </span>
                        </div>
                      </div>
                    <% end %>
                  </div>
                </div>
                
    <!-- By Symbol -->
                <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-6">
                  <h3 class="text-lg font-bold text-white mb-4">By Symbol</h3>
                  <div class="space-y-2">
                    <%= for {symbol, stats} <- @signal_analysis["by_symbol"] || %{} do %>
                      <div class="flex items-center justify-between text-sm">
                        <span class="text-white font-medium">{symbol}</span>
                        <div class="flex items-center gap-4">
                          <span class="text-zinc-300">{stats["count"]} trades</span>
                          <span class={"font-mono #{if String.to_float(stats["win_rate"] || "0") > 50, do: "text-green-400", else: "text-red-400"}"}>
                            {stats["win_rate"]}%
                          </span>
                          <span class={"font-mono #{if (stats["net_profit"] || 0) > 0, do: "text-green-400", else: "text-red-400"}"}>
                            ${stats["net_profit"]}
                          </span>
                        </div>
                      </div>
                    <% end %>
                  </div>
                </div>
                
    <!-- By Direction -->
                <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-6">
                  <h3 class="text-lg font-bold text-white mb-4">By Direction</h3>
                  <div class="space-y-2">
                    <%= for {direction, stats} <- @signal_analysis["by_direction"] || %{} do %>
                      <div class="flex items-center justify-between text-sm">
                        <span class={
                          if direction == "long", do: "text-green-400", else: "text-red-400"
                        }>
                          {String.capitalize(direction)}
                        </span>
                        <div class="flex items-center gap-4">
                          <span class="text-zinc-300">{stats["count"]} trades</span>
                          <span class={"font-mono #{if String.to_float(stats["win_rate"] || "0") > 50, do: "text-green-400", else: "text-red-400"}"}>
                            {stats["win_rate"]}%
                          </span>
                        </div>
                      </div>
                    <% end %>
                  </div>
                </div>
              </div>
            <% else %>
              <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-8 text-center">
                <p class="text-zinc-500">No signal analysis data available for this backtest.</p>
              </div>
            <% end %>
          </div>
          
    <!-- Trade Explorer Tab -->
          <div :if={@active_tab == :trades}>
            <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 overflow-hidden">
              <div class="px-4 py-3 border-b border-zinc-800 flex items-center justify-between">
                <h3 class="font-bold text-white">All Trades ({length(@trades)})</h3>
                <button
                  phx-click="export_trades"
                  class="text-sm text-teal-400 hover:text-teal-300"
                >
                  Export CSV
                </button>
              </div>
              <div class="overflow-x-auto">
                <table class="min-w-full divide-y divide-zinc-800">
                  <thead class="bg-zinc-900/50">
                    <tr>
                      <th class="px-4 py-3 text-left text-xs font-medium text-zinc-400 uppercase">
                        Symbol
                      </th>
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
                        Exit
                      </th>
                      <th class="px-4 py-3 text-right text-xs font-medium text-zinc-400 uppercase">
                        Size
                      </th>
                      <th class="px-4 py-3 text-right text-xs font-medium text-zinc-400 uppercase">
                        P&L
                      </th>
                      <th class="px-4 py-3 text-right text-xs font-medium text-zinc-400 uppercase">
                        R
                      </th>
                      <th class="px-4 py-3 text-left text-xs font-medium text-zinc-400 uppercase">
                        Exit
                      </th>
                    </tr>
                  </thead>
                  <tbody class="divide-y divide-zinc-800">
                    <%= for trade <- @trades do %>
                      <tr class="hover:bg-zinc-800/50">
                        <td class="px-4 py-3 text-sm font-medium text-white">{trade.symbol}</td>
                        <td class={"px-4 py-3 text-sm #{if trade.direction == :long, do: "text-green-400", else: "text-red-400"}"}>
                          {trade.direction}
                        </td>
                        <td class="px-4 py-3 text-sm text-zinc-400">
                          {format_datetime(trade.entry_time)}
                        </td>
                        <td class="px-4 py-3 text-sm text-right text-zinc-300 font-mono">
                          {format_currency(trade.entry_price)}
                        </td>
                        <td class="px-4 py-3 text-sm text-right text-zinc-300 font-mono">
                          {format_currency(trade.exit_price)}
                        </td>
                        <td class="px-4 py-3 text-sm text-right text-zinc-300">
                          {trade.position_size}
                        </td>
                        <td class={"px-4 py-3 text-sm text-right font-mono #{pnl_class(trade.pnl)}"}>
                          {format_currency(trade.pnl)}
                        </td>
                        <td class="px-4 py-3 text-sm text-right text-amber-400 font-mono">
                          {format_decimal(trade.r_multiple)}R
                        </td>
                        <td class="px-4 py-3 text-sm text-zinc-400">
                          {trade.status}
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            </div>
          </div>
        <% else %>
          <!-- No Selection State -->
          <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-12 text-center">
            <.icon name="hero-document-chart-bar" class="w-12 h-12 text-zinc-600 mx-auto mb-4" />
            <h3 class="text-lg font-medium text-zinc-400 mb-2">Select a Backtest Run</h3>
            <p class="text-sm text-zinc-500">
              Choose a completed backtest from the dropdown above to view detailed reports.
            </p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp grade_color("A"), do: "text-green-400"
  defp grade_color("B"), do: "text-blue-400"
  defp grade_color("C"), do: "text-yellow-400"
  defp grade_color("D"), do: "text-orange-400"
  defp grade_color("F"), do: "text-red-400"
  defp grade_color(_), do: "text-zinc-400"

  defp strategy_name("break_and_retest"), do: "Break & Retest"
  defp strategy_name("opening_range_breakout"), do: "Opening Range"
  defp strategy_name(s), do: s
end
