defmodule SignalWeb.Live.Components.BacktestTabs do
  @moduledoc """
  Tab components for the Backtest LiveView.

  Extracts tab content into reusable function components to improve
  readability and maintainability of the main BacktestLive module.
  """

  use Phoenix.Component
  import SignalWeb.CoreComponents
  import SignalWeb.Live.Helpers.Formatters

  # ============================================================================
  # Tab Navigation
  # ============================================================================

  attr :active_tab, :atom, required: true

  def tab_nav(assigns) do
    ~H"""
    <div class="flex gap-2 mb-6">
      <.tab_button tab={:config} active_tab={@active_tab} label="Configuration" />
      <.tab_button tab={:results} active_tab={@active_tab} label="Results" />
      <.tab_button tab={:history} active_tab={@active_tab} label="History" />
    </div>
    """
  end

  attr :tab, :atom, required: true
  attr :active_tab, :atom, required: true
  attr :label, :string, required: true

  defp tab_button(assigns) do
    ~H"""
    <button
      phx-click="switch_tab"
      phx-value-tab={@tab}
      class={[
        "px-4 py-2 rounded-lg text-sm font-medium transition-colors",
        if(@active_tab == @tab,
          do: "bg-blue-500/20 text-blue-400",
          else: "text-zinc-400 hover:text-white"
        )
      ]}
    >
      {@label}
    </button>
    """
  end

  # ============================================================================
  # Progress Bar
  # ============================================================================

  attr :progress, :map, required: true

  def progress_bar(assigns) do
    ~H"""
    <div class="mb-6">
      <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-4">
        <div class="flex items-center justify-between mb-2">
          <span class="text-sm text-zinc-400">Running backtest...</span>
          <button phx-click="cancel_backtest" class="text-sm text-red-400 hover:text-red-300">
            Cancel
          </button>
        </div>
        <div class="w-full bg-zinc-800 rounded-full h-2 mb-2">
          <div
            class="bg-blue-500 h-2 rounded-full transition-all duration-300"
            style={"width: #{@progress.pct_complete || 0}%"}
          >
          </div>
        </div>
        <div class="flex justify-between text-xs text-zinc-500">
          <span>Bars: {@progress.bars_processed || 0}</span>
          <span>Signals: {@progress.signals_generated || 0}</span>
          <span>{Float.round(@progress.pct_complete || 0.0, 1)}%</span>
        </div>
      </div>
    </div>
    """
  end

  # ============================================================================
  # Results Summary Cards
  # ============================================================================

  attr :result, :map, required: true
  attr :get_total_pnl, :any, required: true
  attr :get_win_rate, :any, required: true
  attr :get_total_trades, :any, required: true
  attr :get_profit_factor, :any, required: true

  def results_summary(assigns) do
    ~H"""
    <div class="grid grid-cols-1 lg:grid-cols-4 gap-6 mb-6">
      <.metric_card label="Net P&L" value={@get_total_pnl.(@result)} type={:currency} />
      <.metric_card label="Win Rate" value={@get_win_rate.(@result)} type={:percent} />
      <.metric_card label="Total Trades" value={@get_total_trades.(@result)} type={:number} />
      <.metric_card label="Profit Factor" value={@get_profit_factor.(@result)} type={:decimal} />
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :type, :atom, required: true

  defp metric_card(assigns) do
    ~H"""
    <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-4">
      <div class="text-xs text-zinc-500 mb-1">{@label}</div>
      <div class={metric_class(@type, @value)}>
        {format_value(@value, @type)}
      </div>
    </div>
    """
  end

  defp metric_class(:currency, value) do
    base = "text-2xl font-bold"
    color = if positive?(value), do: "text-green-400", else: "text-red-400"
    "#{base} #{color}"
  end

  defp metric_class(:percent, _value), do: "text-2xl font-bold text-white"
  defp metric_class(:number, _value), do: "text-2xl font-bold text-white"
  defp metric_class(:decimal, _value), do: "text-2xl font-bold text-amber-400"

  defp format_value(value, :currency), do: format_currency(value)
  defp format_value(value, :percent), do: format_pct(value)
  defp format_value(value, :number), do: value
  defp format_value(value, :decimal), do: format_decimal(value)

  # ============================================================================
  # Trade Table
  # ============================================================================

  attr :trades, :list, required: true

  def trade_table(assigns) do
    ~H"""
    <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 overflow-hidden">
      <div class="px-4 py-3 border-b border-zinc-800">
        <h3 class="font-bold text-white">Trades ({length(@trades)})</h3>
      </div>
      <div class="overflow-x-auto">
        <table class="min-w-full divide-y divide-zinc-800">
          <thead class="bg-zinc-900/50">
            <tr>
              <th class="px-4 py-3 text-left text-xs font-medium text-zinc-400 uppercase">Symbol</th>
              <th class="px-4 py-3 text-left text-xs font-medium text-zinc-400 uppercase">
                Direction
              </th>
              <th class="px-4 py-3 text-right text-xs font-medium text-zinc-400 uppercase">Entry</th>
              <th class="px-4 py-3 text-right text-xs font-medium text-zinc-400 uppercase">Exit</th>
              <th class="px-4 py-3 text-right text-xs font-medium text-zinc-400 uppercase">P&L</th>
              <th class="px-4 py-3 text-right text-xs font-medium text-zinc-400 uppercase">
                R-Multiple
              </th>
              <th class="px-4 py-3 text-left text-xs font-medium text-zinc-400 uppercase">
                Exit Type
              </th>
            </tr>
          </thead>
          <tbody class="divide-y divide-zinc-800">
            <%= for trade <- Enum.take(@trades, 50) do %>
              <tr
                class="hover:bg-zinc-800/50 cursor-pointer"
                phx-click="select_trade"
                phx-value-id={trade.id}
              >
                <td class="px-4 py-3 text-sm font-medium text-white">{trade.symbol}</td>
                <td class={"px-4 py-3 text-sm #{if trade.direction == :long, do: "text-green-400", else: "text-red-400"}"}>
                  {trade.direction}
                </td>
                <td class="px-4 py-3 text-sm text-right text-zinc-300 font-mono">
                  {format_currency(trade.entry_price)}
                </td>
                <td class="px-4 py-3 text-sm text-right text-zinc-300 font-mono">
                  {format_currency(trade.exit_price)}
                </td>
                <td class={"px-4 py-3 text-sm text-right font-mono #{pnl_class(trade.pnl)}"}>
                  {format_currency(trade.pnl)}
                </td>
                <td class="px-4 py-3 text-sm text-right text-zinc-300 font-mono">
                  {format_decimal(trade.r_multiple)}R
                </td>
                <td class="px-4 py-3 text-sm text-zinc-400">{trade.status}</td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  # ============================================================================
  # History Table
  # ============================================================================

  attr :recent_runs, :list, required: true

  def history_table(assigns) do
    ~H"""
    <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 overflow-hidden">
      <div class="px-4 py-3 border-b border-zinc-800">
        <h3 class="font-bold text-white">Recent Backtest Runs</h3>
      </div>
      <%= if Enum.empty?(@recent_runs) do %>
        <div class="p-8 text-center">
          <p class="text-zinc-500">No backtest runs yet.</p>
        </div>
      <% else %>
        <div class="overflow-x-auto">
          <table class="min-w-full divide-y divide-zinc-800">
            <thead class="bg-zinc-900/50">
              <tr>
                <th class="px-4 py-3 text-left text-xs font-medium text-zinc-400 uppercase">Date</th>
                <th class="px-4 py-3 text-left text-xs font-medium text-zinc-400 uppercase">
                  Symbols
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-zinc-400 uppercase">
                  Period
                </th>
                <th class="px-4 py-3 text-center text-xs font-medium text-zinc-400 uppercase">
                  Status
                </th>
                <th class="px-4 py-3 text-right text-xs font-medium text-zinc-400 uppercase">
                  Signals
                </th>
                <th class="px-4 py-3 text-right text-xs font-medium text-zinc-400 uppercase">
                  Actions
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-zinc-800">
              <%= for run <- @recent_runs do %>
                <tr class="hover:bg-zinc-800/50">
                  <td class="px-4 py-3 text-sm text-zinc-300">{format_datetime(run.inserted_at)}</td>
                  <td class="px-4 py-3 text-sm text-white">{Enum.join(run.symbols, ", ")}</td>
                  <td class="px-4 py-3 text-sm text-zinc-400">
                    {format_date(run.start_date)} - {format_date(run.end_date)}
                  </td>
                  <td class="px-4 py-3 text-center">
                    <span class={"px-2 py-1 text-xs rounded #{status_badge_class(run.status)}"}>
                      {run.status}
                    </span>
                  </td>
                  <td class="px-4 py-3 text-sm text-right text-zinc-300">
                    {run.signals_generated || 0}
                  </td>
                  <td class="px-4 py-3 text-right">
                    <button
                      :if={run.status == :completed}
                      phx-click="load_run"
                      phx-value-id={run.id}
                      class="text-sm text-blue-400 hover:text-blue-300"
                    >
                      View
                    </button>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% end %>
    </div>
    """
  end

  # ============================================================================
  # Empty State
  # ============================================================================

  def no_results(assigns) do
    ~H"""
    <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-12 text-center">
      <.icon name="hero-play" class="w-12 h-12 text-zinc-600 mx-auto mb-4" />
      <h3 class="text-lg font-medium text-zinc-400 mb-2">No Results Yet</h3>
      <p class="text-sm text-zinc-500">
        Configure and run a backtest to see results here.
      </p>
    </div>
    """
  end

  # ============================================================================
  # Trade Details Modal
  # ============================================================================

  attr :trade, :map, required: true

  def trade_modal(assigns) do
    ~H"""
    <div
      class="fixed inset-0 bg-black/50 flex items-center justify-center z-50"
      phx-click="close_trade_details"
    >
      <div
        class="bg-zinc-900 rounded-xl border border-zinc-700 p-6 max-w-lg w-full mx-4"
        phx-click-away="close_trade_details"
      >
        <div class="flex justify-between items-center mb-4">
          <h3 class="text-lg font-bold text-white">Trade Details</h3>
          <button phx-click="close_trade_details" class="text-zinc-400 hover:text-white">
            <.icon name="hero-x-mark" class="w-5 h-5" />
          </button>
        </div>
        <div class="space-y-3">
          <.detail_row label="Symbol" value={@trade.symbol} />
          <.detail_row
            label="Direction"
            value={@trade.direction}
            class={if @trade.direction == :long, do: "text-green-400", else: "text-red-400"}
          />
          <.detail_row label="Entry Time" value={format_datetime(@trade.entry_time)} />
          <.detail_row label="Exit Time" value={format_datetime(@trade.exit_time)} />
          <.detail_row
            label="Entry Price"
            value={format_currency(@trade.entry_price)}
            class="font-mono"
          />
          <.detail_row
            label="Exit Price"
            value={format_currency(@trade.exit_price)}
            class="font-mono"
          />
          <.detail_row label="Position Size" value={"#{@trade.position_size} shares"} />
          <.detail_row label="P&L" value={format_currency(@trade.pnl)} class={pnl_class(@trade.pnl)} />
          <.detail_row
            label="R-Multiple"
            value={"#{format_decimal(@trade.r_multiple)}R"}
            class="text-amber-400"
          />
          <.detail_row label="Exit Reason" value={@trade.status} />
        </div>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :class, :string, default: "text-white"

  defp detail_row(assigns) do
    ~H"""
    <div class="flex justify-between">
      <span class="text-zinc-400">{@label}</span>
      <span class={@class}>{@value}</span>
    </div>
    """
  end
end
