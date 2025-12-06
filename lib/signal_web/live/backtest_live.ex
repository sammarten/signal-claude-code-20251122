defmodule SignalWeb.BacktestLive do
  use SignalWeb, :live_view

  alias SignalWeb.Live.Components.Navigation
  alias Signal.Backtest.Coordinator
  alias Signal.Backtest.BacktestRun
  alias Signal.Backtest.SimulatedTrade
  alias Signal.Analytics.BacktestResult
  alias Signal.Repo

  import Ecto.Query
  import SignalWeb.Live.Helpers.Formatters

  @moduledoc """
  Backtest dashboard for configuring, running, and viewing backtest results.

  Features:
  - Configuration form for symbols, dates, strategies, capital, risk
  - Real-time progress tracking during backtest execution
  - Results display with metrics, equity curve, and trade list
  - Recent runs history
  """

  @default_symbols ~w[AAPL TSLA NVDA MSFT META]
  @available_strategies [
    {"break_and_retest", "Break & Retest"},
    {"opening_range_breakout", "Opening Range Breakout"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    # Load recent backtest runs
    recent_runs = load_recent_runs()

    {:ok,
     assign(socket,
       # Page info
       page_title: "Backtest",
       page_subtitle: "Test strategies on historical data",
       current_path: "/backtest",

       # Form state
       form: to_form(default_params()),
       available_symbols: @default_symbols,
       available_strategies: @available_strategies,
       selected_symbols: ["AAPL", "TSLA"],
       selected_strategies: ["break_and_retest"],

       # Run state
       current_run_id: nil,
       run_status: :idle,
       progress: %{pct_complete: 0.0, current_date: nil, bars_processed: 0, signals_generated: 0},

       # Results
       result: nil,
       trades: [],
       equity_curve: [],

       # History
       recent_runs: recent_runs,

       # UI state
       selected_trade: nil,
       active_tab: :config
     )}
  end

  @impl true
  def handle_event("toggle_symbol", %{"symbol" => symbol}, socket) do
    selected = socket.assigns.selected_symbols

    updated =
      if symbol in selected do
        List.delete(selected, symbol)
      else
        [symbol | selected]
      end

    {:noreply, assign(socket, :selected_symbols, updated)}
  end

  @impl true
  def handle_event("toggle_strategy", %{"strategy" => strategy}, socket) do
    selected = socket.assigns.selected_strategies

    updated =
      if strategy in selected do
        List.delete(selected, strategy)
      else
        [strategy | selected]
      end

    {:noreply, assign(socket, :selected_strategies, updated)}
  end

  @impl true
  def handle_event("validate", %{"backtest" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(params))}
  end

  @impl true
  def handle_event("run_backtest", %{"backtest" => params}, socket) do
    if socket.assigns.run_status == :running do
      {:noreply, socket}
    else
      case build_config(params, socket.assigns) do
        {:ok, config} ->
          run_backtest_async(config, socket)

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, reason)}
      end
    end
  end

  @impl true
  def handle_event("cancel_backtest", _params, socket) do
    if socket.assigns.current_run_id do
      Coordinator.cancel(socket.assigns.current_run_id)
    end

    {:noreply,
     assign(socket,
       run_status: :cancelled,
       current_run_id: nil
     )}
  end

  @impl true
  def handle_event("select_trade", %{"id" => id}, socket) do
    trade = Enum.find(socket.assigns.trades, &(&1.id == id))
    {:noreply, assign(socket, :selected_trade, trade)}
  end

  @impl true
  def handle_event("close_trade_details", _params, socket) do
    {:noreply, assign(socket, :selected_trade, nil)}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, String.to_existing_atom(tab))}
  end

  @impl true
  def handle_event("equity_stats", _params, socket) do
    # Stats pushed from EquityCurveChart hook - currently unused
    {:noreply, socket}
  end

  @impl true
  def handle_event("load_run", %{"id" => run_id}, socket) do
    case load_run_results(run_id) do
      {:ok, result, trades, equity_curve} ->
        {:noreply,
         assign(socket,
           result: result,
           trades: trades,
           equity_curve: equity_curve,
           active_tab: :results
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to load backtest results")}
    end
  end

  @impl true
  def handle_info({:backtest_progress, progress}, socket) do
    {:noreply, assign(socket, :progress, progress)}
  end

  @impl true
  def handle_info({:backtest_complete, coordinator_result}, socket) do
    # Load the persisted result from database for consistent format
    case load_run_results(coordinator_result.run_id) do
      {:ok, result, trades, equity_curve} ->
        # Prefer the coordinator's equity curve if available (more accurate)
        # Fall back to reconstructed curve from trades
        final_curve = coordinator_result.equity_curve || equity_curve

        {:noreply,
         assign(socket,
           run_status: :completed,
           result: result,
           trades: trades,
           equity_curve: final_curve,
           active_tab: :results,
           recent_runs: load_recent_runs()
         )}

      {:error, _reason} ->
        # Fallback if loading fails - shouldn't happen normally
        {:noreply,
         socket
         |> assign(run_status: :completed, recent_runs: load_recent_runs())
         |> put_flash(:error, "Backtest completed but failed to load results")}
    end
  end

  @impl true
  def handle_info({:backtest_failed, error}, socket) do
    {:noreply,
     socket
     |> assign(run_status: :failed)
     |> put_flash(:error, "Backtest failed: #{inspect(error)}")}
  end

  # Private helpers

  defp default_params do
    %{
      "start_date" => Date.to_iso8601(Date.add(Date.utc_today(), -365)),
      "end_date" => Date.to_iso8601(Date.add(Date.utc_today(), -1)),
      "initial_capital" => "100000",
      "risk_per_trade" => "1.0",
      "min_confluence" => "7",
      "min_rr" => "2.0",
      "signal_evaluation_mode" => "false"
    }
  end

  defp build_config(params, assigns) do
    with {:ok, start_date} <- Date.from_iso8601(params["start_date"]),
         {:ok, end_date} <- Date.from_iso8601(params["end_date"]),
         {capital, _} <- Float.parse(params["initial_capital"]),
         {risk, _} <- Float.parse(params["risk_per_trade"]),
         {min_confluence, _} <- Integer.parse(params["min_confluence"]),
         {min_rr, _} <- Float.parse(params["min_rr"]),
         :ok <- validate_symbols(assigns.selected_symbols),
         :ok <- validate_strategies(assigns.selected_strategies) do
      # Signal evaluation mode = unlimited capital (execute every signal)
      signal_eval_mode = params["signal_evaluation_mode"] == "true"

      {:ok,
       %{
         symbols: assigns.selected_symbols,
         start_date: start_date,
         end_date: end_date,
         strategies: Enum.map(assigns.selected_strategies, &String.to_atom/1),
         initial_capital: Decimal.new(trunc(capital)),
         risk_per_trade: Decimal.from_float(risk / 100),
         unlimited_capital: signal_eval_mode,
         parameters: %{
           min_confluence: min_confluence,
           min_rr: Decimal.from_float(min_rr)
         }
       }}
    end
  end

  defp validate_symbols([]), do: {:error, "Please select at least one symbol"}
  defp validate_symbols(_), do: :ok

  defp validate_strategies([]), do: {:error, "Please select at least one strategy"}
  defp validate_strategies(_), do: :ok

  defp run_backtest_async(config, socket) do
    parent = self()

    progress_callback = fn progress ->
      send(parent, {:backtest_progress, progress})
    end

    Task.start(fn ->
      case Coordinator.run(config, progress_callback) do
        {:ok, result} ->
          send(parent, {:backtest_complete, result})

        {:error, reason} ->
          send(parent, {:backtest_failed, reason})
      end
    end)

    {:noreply,
     assign(socket,
       run_status: :running,
       progress: %{pct_complete: 0.0, current_date: nil, bars_processed: 0, signals_generated: 0},
       result: nil,
       trades: []
     )}
  end

  defp load_recent_runs do
    BacktestRun
    |> order_by([r], desc: r.inserted_at)
    |> limit(10)
    |> Repo.all()
  end

  defp load_trades(run_id) do
    SimulatedTrade
    |> where([t], t.backtest_run_id == ^run_id)
    |> order_by([t], desc: t.entry_time)
    |> Repo.all()
  end

  defp load_trades_chronological(run_id) do
    SimulatedTrade
    |> where([t], t.backtest_run_id == ^run_id)
    |> order_by([t], asc: t.exit_time)
    |> Repo.all()
  end

  defp load_run_results(run_id) do
    case Repo.get(BacktestRun, run_id) do
      nil ->
        {:error, :not_found}

      run ->
        result = Repo.get_by(BacktestResult, backtest_run_id: run_id)
        trades = load_trades(run_id)
        trades_chrono = load_trades_chronological(run_id)
        equity_curve = build_equity_curve(trades_chrono, run.initial_capital, run.start_date)
        {:ok, %{run: run, analytics: result}, trades, equity_curve}
    end
  end

  # Build equity curve from closed trades
  defp build_equity_curve([], _initial_capital, _start_date), do: []

  defp build_equity_curve(trades, initial_capital, start_date) do
    # Start with initial capital at the beginning of the backtest
    start_datetime = DateTime.new!(start_date, ~T[09:30:00], "America/New_York")
    initial_point = {start_datetime, initial_capital}

    # Build running equity from trades sorted by exit time
    {curve, _final} =
      Enum.reduce(trades, {[initial_point], initial_capital}, fn trade, {points, equity} ->
        if trade.exit_time && trade.pnl do
          new_equity = Decimal.add(equity, trade.pnl)
          {[{trade.exit_time, new_equity} | points], new_equity}
        else
          {points, equity}
        end
      end)

    Enum.reverse(curve)
  end

  # Helper functions to extract metrics from result
  # Result format: %{run: BacktestRun, analytics: BacktestResult}
  defp get_analytics(result) do
    result[:analytics]
  end

  defp get_total_pnl(result) do
    case get_analytics(result) do
      nil -> nil
      analytics -> analytics.net_profit
    end
  end

  defp get_win_rate(result) do
    case get_analytics(result) do
      nil -> nil
      analytics -> analytics.win_rate
    end
  end

  defp get_total_trades(result) do
    case get_analytics(result) do
      nil -> 0
      analytics -> analytics.total_trades || 0
    end
  end

  defp get_profit_factor(result) do
    case get_analytics(result) do
      nil -> nil
      analytics -> analytics.profit_factor
    end
  end

  defp format_equity_curve_json(nil), do: "[]"
  defp format_equity_curve_json([]), do: "[]"

  defp format_equity_curve_json(equity_curve) do
    equity_curve
    |> Enum.map(fn {datetime, equity} ->
      %{
        time: DateTime.to_unix(datetime),
        value: Decimal.to_float(equity)
      }
    end)
    |> Jason.encode!()
  end

  defp get_initial_capital(result) do
    case result[:run] do
      nil -> "100000"
      run -> Decimal.to_string(run.initial_capital || Decimal.new("100000"))
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-zinc-950">
      <Navigation.header
        current_path={@current_path}
        page_title={@page_title}
        page_subtitle={@page_subtitle}
        page_icon_color="from-blue-500 to-indigo-600"
      />

      <div class="max-w-[1920px] mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <!-- Tab Navigation -->
        <div class="flex gap-2 mb-6">
          <button
            phx-click="switch_tab"
            phx-value-tab="config"
            class={[
              "px-4 py-2 rounded-lg text-sm font-medium transition-colors",
              if(@active_tab == :config,
                do: "bg-blue-500/20 text-blue-400",
                else: "text-zinc-400 hover:text-white"
              )
            ]}
          >
            Configuration
          </button>
          <button
            phx-click="switch_tab"
            phx-value-tab="results"
            class={[
              "px-4 py-2 rounded-lg text-sm font-medium transition-colors",
              if(@active_tab == :results,
                do: "bg-blue-500/20 text-blue-400",
                else: "text-zinc-400 hover:text-white"
              )
            ]}
          >
            Results
          </button>
          <button
            phx-click="switch_tab"
            phx-value-tab="history"
            class={[
              "px-4 py-2 rounded-lg text-sm font-medium transition-colors",
              if(@active_tab == :history,
                do: "bg-blue-500/20 text-blue-400",
                else: "text-zinc-400 hover:text-white"
              )
            ]}
          >
            History
          </button>
        </div>
        
    <!-- Progress Bar (when running) -->
        <div :if={@run_status == :running} class="mb-6">
          <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-4">
            <div class="flex items-center justify-between mb-2">
              <span class="text-sm text-zinc-400">Running backtest...</span>
              <button
                phx-click="cancel_backtest"
                class="text-sm text-red-400 hover:text-red-300"
              >
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
              <span>{Float.round((@progress.pct_complete || 0) / 1, 1)}%</span>
            </div>
          </div>
        </div>
        
    <!-- Configuration Tab -->
        <div :if={@active_tab == :config} class="grid grid-cols-1 lg:grid-cols-3 gap-6">
          <div class="lg:col-span-2">
            <.form for={@form} phx-change="validate" phx-submit="run_backtest" class="space-y-6">
              <!-- Symbols Selection -->
              <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-6">
                <h3 class="text-lg font-bold text-white mb-4">Symbols</h3>
                <div class="flex flex-wrap gap-2">
                  <%= for symbol <- @available_symbols do %>
                    <button
                      type="button"
                      phx-click="toggle_symbol"
                      phx-value-symbol={symbol}
                      class={[
                        "px-3 py-1.5 rounded-lg text-sm font-medium transition-colors",
                        if(symbol in @selected_symbols,
                          do: "bg-blue-500/20 text-blue-400 border border-blue-500/50",
                          else:
                            "bg-zinc-800 text-zinc-400 border border-zinc-700 hover:border-zinc-600"
                        )
                      ]}
                    >
                      {symbol}
                    </button>
                  <% end %>
                </div>
              </div>
              
    <!-- Strategies Selection -->
              <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-6">
                <h3 class="text-lg font-bold text-white mb-4">Strategies</h3>
                <div class="flex flex-wrap gap-2">
                  <%= for {key, label} <- @available_strategies do %>
                    <button
                      type="button"
                      phx-click="toggle_strategy"
                      phx-value-strategy={key}
                      class={[
                        "px-3 py-1.5 rounded-lg text-sm font-medium transition-colors",
                        if(key in @selected_strategies,
                          do: "bg-green-500/20 text-green-400 border border-green-500/50",
                          else:
                            "bg-zinc-800 text-zinc-400 border border-zinc-700 hover:border-zinc-600"
                        )
                      ]}
                    >
                      {label}
                    </button>
                  <% end %>
                </div>
              </div>
              
    <!-- Signal Evaluation Mode Toggle -->
              <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-6">
                <div class="flex items-center justify-between">
                  <div>
                    <h3 class="text-lg font-bold text-white">Signal Evaluation Mode</h3>
                    <p class="text-sm text-zinc-500 mt-1">
                      Execute every signal regardless of capital. Useful for evaluating strategy signals without portfolio constraints.
                    </p>
                  </div>
                  <label class="relative inline-flex items-center cursor-pointer">
                    <input
                      type="checkbox"
                      name="backtest[signal_evaluation_mode]"
                      value="true"
                      checked={@form[:signal_evaluation_mode].value == "true"}
                      class="sr-only peer"
                    />
                    <div class="w-11 h-6 bg-zinc-700 peer-focus:outline-none rounded-full peer peer-checked:after:translate-x-full rtl:peer-checked:after:-translate-x-full peer-checked:after:border-white after:content-[''] after:absolute after:top-[2px] after:start-[2px] after:bg-white after:border-zinc-300 after:border after:rounded-full after:h-5 after:w-5 after:transition-all peer-checked:bg-blue-600">
                    </div>
                  </label>
                </div>
              </div>
              
    <!-- Date Range & Capital -->
              <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-6">
                <h3 class="text-lg font-bold text-white mb-4">Configuration</h3>
                <div class="grid grid-cols-2 gap-4">
                  <div>
                    <label class="block text-sm text-zinc-400 mb-1">Start Date</label>
                    <input
                      type="date"
                      name="backtest[start_date]"
                      value={@form[:start_date].value}
                      class="w-full bg-zinc-800 border border-zinc-700 rounded-lg px-3 py-2 text-white"
                    />
                  </div>
                  <div>
                    <label class="block text-sm text-zinc-400 mb-1">End Date</label>
                    <input
                      type="date"
                      name="backtest[end_date]"
                      value={@form[:end_date].value}
                      class="w-full bg-zinc-800 border border-zinc-700 rounded-lg px-3 py-2 text-white"
                    />
                  </div>
                  <div>
                    <label class="block text-sm text-zinc-400 mb-1">Initial Capital ($)</label>
                    <input
                      type="number"
                      name="backtest[initial_capital]"
                      value={@form[:initial_capital].value}
                      class="w-full bg-zinc-800 border border-zinc-700 rounded-lg px-3 py-2 text-white"
                    />
                  </div>
                  <div>
                    <label class="block text-sm text-zinc-400 mb-1">Risk Per Trade (%)</label>
                    <input
                      type="number"
                      step="0.1"
                      name="backtest[risk_per_trade]"
                      value={@form[:risk_per_trade].value}
                      class="w-full bg-zinc-800 border border-zinc-700 rounded-lg px-3 py-2 text-white"
                    />
                  </div>
                  <div>
                    <label class="block text-sm text-zinc-400 mb-1">Min Confluence Score</label>
                    <input
                      type="number"
                      name="backtest[min_confluence]"
                      value={@form[:min_confluence].value}
                      class="w-full bg-zinc-800 border border-zinc-700 rounded-lg px-3 py-2 text-white"
                    />
                  </div>
                  <div>
                    <label class="block text-sm text-zinc-400 mb-1">Min Risk/Reward</label>
                    <input
                      type="number"
                      step="0.1"
                      name="backtest[min_rr]"
                      value={@form[:min_rr].value}
                      class="w-full bg-zinc-800 border border-zinc-700 rounded-lg px-3 py-2 text-white"
                    />
                  </div>
                </div>
              </div>
              
    <!-- Run Button -->
              <button
                type="submit"
                disabled={@run_status == :running}
                class={[
                  "w-full py-3 rounded-xl font-bold text-white transition-colors",
                  if(@run_status == :running,
                    do: "bg-zinc-700 cursor-not-allowed",
                    else: "bg-blue-600 hover:bg-blue-500"
                  )
                ]}
              >
                <%= if @run_status == :running do %>
                  Running...
                <% else %>
                  Run Backtest
                <% end %>
              </button>
            </.form>
          </div>
          
    <!-- Quick Stats Sidebar -->
          <div class="space-y-4">
            <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-4">
              <h4 class="text-sm font-medium text-zinc-400 mb-3">Selected</h4>
              <div class="space-y-2">
                <div class="flex justify-between text-sm">
                  <span class="text-zinc-500">Symbols</span>
                  <span class="text-white">{length(@selected_symbols)}</span>
                </div>
                <div class="flex justify-between text-sm">
                  <span class="text-zinc-500">Strategies</span>
                  <span class="text-white">{length(@selected_strategies)}</span>
                </div>
              </div>
            </div>
          </div>
        </div>
        
    <!-- Results Tab -->
        <div :if={@active_tab == :results}>
          <%= if @result do %>
            <div class="grid grid-cols-1 lg:grid-cols-4 gap-6 mb-6">
              <!-- Summary Metrics -->
              <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-4">
                <div class="text-xs text-zinc-500 mb-1">Net P&L</div>
                <% pnl = get_total_pnl(@result) %>
                <div class={"text-2xl font-bold #{if positive?(pnl), do: "text-green-400", else: "text-red-400"}"}>
                  {format_currency(pnl)}
                </div>
              </div>
              <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-4">
                <div class="text-xs text-zinc-500 mb-1">Win Rate</div>
                <div class="text-2xl font-bold text-white">
                  {format_pct(get_win_rate(@result))}
                </div>
              </div>
              <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-4">
                <div class="text-xs text-zinc-500 mb-1">Total Trades</div>
                <div class="text-2xl font-bold text-white">
                  {get_total_trades(@result)}
                </div>
              </div>
              <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-4">
                <div class="text-xs text-zinc-500 mb-1">Profit Factor</div>
                <div class="text-2xl font-bold text-amber-400">
                  {format_decimal(get_profit_factor(@result))}
                </div>
              </div>
            </div>
            
    <!-- Equity Curve Chart -->
            <div :if={@equity_curve != []} class="mb-6">
              <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 overflow-hidden">
                <div class="px-4 py-3 border-b border-zinc-800">
                  <h3 class="font-bold text-white">Equity Curve</h3>
                </div>
                <div class="p-4">
                  <div
                    id="equity-curve-chart"
                    phx-hook="EquityCurveChart"
                    phx-update="ignore"
                    data-equity={format_equity_curve_json(@equity_curve)}
                    data-initial-capital={get_initial_capital(@result)}
                    data-height="300"
                    class="w-full"
                  >
                  </div>
                </div>
              </div>
            </div>
            
    <!-- Trade List -->
            <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 overflow-hidden">
              <div class="px-4 py-3 border-b border-zinc-800">
                <h3 class="font-bold text-white">Trades ({length(@trades)})</h3>
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
                      <th class="px-4 py-3 text-right text-xs font-medium text-zinc-400 uppercase">
                        Entry
                      </th>
                      <th class="px-4 py-3 text-right text-xs font-medium text-zinc-400 uppercase">
                        Exit
                      </th>
                      <th class="px-4 py-3 text-right text-xs font-medium text-zinc-400 uppercase">
                        P&L
                      </th>
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
                        <td class="px-4 py-3 text-sm text-zinc-400">
                          {trade.status}
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            </div>
          <% else %>
            <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-12 text-center">
              <.icon name="hero-play" class="w-12 h-12 text-zinc-600 mx-auto mb-4" />
              <h3 class="text-lg font-medium text-zinc-400 mb-2">No Results Yet</h3>
              <p class="text-sm text-zinc-500">
                Configure and run a backtest to see results here.
              </p>
            </div>
          <% end %>
        </div>
        
    <!-- History Tab -->
        <div :if={@active_tab == :history}>
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
                      <th class="px-4 py-3 text-left text-xs font-medium text-zinc-400 uppercase">
                        Date
                      </th>
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
                        <td class="px-4 py-3 text-sm text-zinc-300">
                          {format_datetime(run.inserted_at)}
                        </td>
                        <td class="px-4 py-3 text-sm text-white">
                          {Enum.join(run.symbols, ", ")}
                        </td>
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
        </div>
      </div>
      
    <!-- Trade Details Modal -->
      <div
        :if={@selected_trade}
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
            <div class="flex justify-between">
              <span class="text-zinc-400">Symbol</span>
              <span class="text-white font-medium">{@selected_trade.symbol}</span>
            </div>
            <div class="flex justify-between">
              <span class="text-zinc-400">Direction</span>
              <span class={
                if @selected_trade.direction == :long, do: "text-green-400", else: "text-red-400"
              }>
                {@selected_trade.direction}
              </span>
            </div>
            <div class="flex justify-between">
              <span class="text-zinc-400">Entry Time</span>
              <span class="text-white">{format_datetime(@selected_trade.entry_time)}</span>
            </div>
            <div class="flex justify-between">
              <span class="text-zinc-400">Exit Time</span>
              <span class="text-white">{format_datetime(@selected_trade.exit_time)}</span>
            </div>
            <div class="flex justify-between">
              <span class="text-zinc-400">Entry Price</span>
              <span class="text-white font-mono">{format_currency(@selected_trade.entry_price)}</span>
            </div>
            <div class="flex justify-between">
              <span class="text-zinc-400">Exit Price</span>
              <span class="text-white font-mono">{format_currency(@selected_trade.exit_price)}</span>
            </div>
            <div class="flex justify-between">
              <span class="text-zinc-400">Position Size</span>
              <span class="text-white">{@selected_trade.position_size} shares</span>
            </div>
            <div class="flex justify-between">
              <span class="text-zinc-400">P&L</span>
              <span class={pnl_class(@selected_trade.pnl)}>
                {format_currency(@selected_trade.pnl)}
              </span>
            </div>
            <div class="flex justify-between">
              <span class="text-zinc-400">R-Multiple</span>
              <span class="text-amber-400">{format_decimal(@selected_trade.r_multiple)}R</span>
            </div>
            <div class="flex justify-between">
              <span class="text-zinc-400">Exit Reason</span>
              <span class="text-zinc-300">{@selected_trade.status}</span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
