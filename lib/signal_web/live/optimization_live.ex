defmodule SignalWeb.OptimizationLive do
  use SignalWeb, :live_view

  alias SignalWeb.Live.Components.Navigation
  alias Signal.Optimization.Runner
  alias Signal.Optimization.OptimizationRun
  alias Signal.Optimization.OptimizationResult
  alias Signal.Repo

  import Ecto.Query
  import SignalWeb.Live.Helpers.Formatters

  @moduledoc """
  Optimization dashboard for parameter tuning and walk-forward analysis.

  Features:
  - Parameter grid configuration with checkbox selection
  - Walk-forward optimization settings
  - Real-time progress tracking
  - Results comparison with overfitting detection
  """

  @default_symbols ~w[AAPL TSLA NVDA MSFT META]
  @available_strategies [
    {"break_and_retest", "Break & Retest"},
    {"opening_range_breakout", "Opening Range Breakout"}
  ]

  @confluence_options [5, 6, 7, 8, 9]
  @rr_options [1.5, 2.0, 2.5, 3.0]
  @risk_options [0.01, 0.015, 0.02]

  @impl true
  def mount(_params, _session, socket) do
    recent_runs = load_recent_runs()

    {:ok,
     assign(socket,
       # Page info
       page_title: "Optimize",
       page_subtitle: "Parameter tuning and walk-forward analysis",
       current_path: "/optimization",

       # Form state
       form: to_form(default_params()),
       available_symbols: @default_symbols,
       available_strategies: @available_strategies,
       selected_symbols: ["AAPL", "TSLA"],
       selected_strategies: ["break_and_retest"],

       # Parameter grid options
       confluence_options: @confluence_options,
       rr_options: @rr_options,
       risk_options: @risk_options,
       selected_confluence: [7, 8],
       selected_rr: [2.0, 2.5],
       selected_risk: [0.01],

       # Walk-forward settings
       walk_forward_enabled: false,
       walk_forward_config: %{
         training_months: 12,
         testing_months: 3,
         step_months: 3
       },

       # Run state
       current_run_id: nil,
       run_status: :idle,
       progress: %{completed: 0, total: 0, pct: 0},

       # Results
       results: [],
       best_params: nil,

       # History
       recent_runs: recent_runs,

       # UI state
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
  def handle_event("toggle_confluence", %{"value" => value}, socket) do
    val = String.to_integer(value)
    selected = socket.assigns.selected_confluence

    updated =
      if val in selected do
        List.delete(selected, val)
      else
        [val | selected] |> Enum.sort()
      end

    {:noreply, assign(socket, :selected_confluence, updated)}
  end

  @impl true
  def handle_event("toggle_rr", %{"value" => value}, socket) do
    {val, _} = Float.parse(value)
    selected = socket.assigns.selected_rr

    updated =
      if val in selected do
        List.delete(selected, val)
      else
        [val | selected] |> Enum.sort()
      end

    {:noreply, assign(socket, :selected_rr, updated)}
  end

  @impl true
  def handle_event("toggle_risk", %{"value" => value}, socket) do
    {val, _} = Float.parse(value)
    selected = socket.assigns.selected_risk

    updated =
      if val in selected do
        List.delete(selected, val)
      else
        [val | selected] |> Enum.sort()
      end

    {:noreply, assign(socket, :selected_risk, updated)}
  end

  @impl true
  def handle_event("toggle_walk_forward", _params, socket) do
    {:noreply, assign(socket, :walk_forward_enabled, !socket.assigns.walk_forward_enabled)}
  end

  @impl true
  def handle_event("validate", %{"optimization" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(params))}
  end

  @impl true
  def handle_event("run_optimization", %{"optimization" => params}, socket) do
    if socket.assigns.run_status == :running do
      {:noreply, socket}
    else
      case build_config(params, socket.assigns) do
        {:ok, config} ->
          run_optimization_async(config, socket)

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, reason)}
      end
    end
  end

  @impl true
  def handle_event("cancel_optimization", _params, socket) do
    if socket.assigns.current_run_id do
      Runner.cancel(socket.assigns.current_run_id)
    end

    {:noreply,
     assign(socket,
       run_status: :cancelled,
       current_run_id: nil
     )}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, String.to_existing_atom(tab))}
  end

  @impl true
  def handle_event("load_run", %{"id" => run_id}, socket) do
    case load_run_results(run_id) do
      {:ok, results, best_params} ->
        {:noreply,
         assign(socket,
           results: results,
           best_params: best_params,
           active_tab: :results
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to load results")}
    end
  end

  @impl true
  def handle_info({:optimization_progress, progress}, socket) do
    {:noreply, assign(socket, :progress, progress)}
  end

  @impl true
  def handle_info({:optimization_complete, result}, socket) do
    {:noreply,
     assign(socket,
       run_status: :completed,
       results: load_results(result.run_id),
       best_params: result.best_params,
       active_tab: :results,
       recent_runs: load_recent_runs()
     )}
  end

  @impl true
  def handle_info({:optimization_failed, error}, socket) do
    {:noreply,
     socket
     |> assign(run_status: :failed)
     |> put_flash(:error, "Optimization failed: #{inspect(error)}")}
  end

  # Private helpers

  defp default_params do
    %{
      "start_date" => Date.to_iso8601(Date.add(Date.utc_today(), -730)),
      "end_date" => Date.to_iso8601(Date.add(Date.utc_today(), -1)),
      "initial_capital" => "100000",
      "min_trades" => "30",
      "optimization_metric" => "profit_factor"
    }
  end

  defp build_config(params, assigns) do
    with {:ok, start_date} <- Date.from_iso8601(params["start_date"]),
         {:ok, end_date} <- Date.from_iso8601(params["end_date"]),
         {capital, _} <- Float.parse(params["initial_capital"]),
         {min_trades, _} <- Integer.parse(params["min_trades"]),
         :ok <- validate_symbols(assigns.selected_symbols),
         :ok <- validate_strategies(assigns.selected_strategies),
         :ok <- validate_parameter_grid(assigns) do
      config = %{
        symbols: assigns.selected_symbols,
        start_date: start_date,
        end_date: end_date,
        strategies: Enum.map(assigns.selected_strategies, &String.to_atom/1),
        initial_capital: Decimal.new(trunc(capital)),
        base_risk_per_trade: Decimal.new("0.01"),
        parameter_grid: %{
          min_confluence_score: assigns.selected_confluence,
          min_rr: assigns.selected_rr,
          risk_per_trade: Enum.map(assigns.selected_risk, &Decimal.from_float/1)
        },
        optimization_metric: String.to_atom(params["optimization_metric"]),
        min_trades: min_trades
      }

      config =
        if assigns.walk_forward_enabled do
          Map.put(config, :walk_forward_config, assigns.walk_forward_config)
        else
          config
        end

      {:ok, config}
    end
  end

  defp validate_symbols([]), do: {:error, "Please select at least one symbol"}
  defp validate_symbols(_), do: :ok

  defp validate_strategies([]), do: {:error, "Please select at least one strategy"}
  defp validate_strategies(_), do: :ok

  defp validate_parameter_grid(assigns) do
    if Enum.empty?(assigns.selected_confluence) ||
         Enum.empty?(assigns.selected_rr) ||
         Enum.empty?(assigns.selected_risk) do
      {:error, "Please select at least one value for each parameter"}
    else
      :ok
    end
  end

  defp run_optimization_async(config, socket) do
    parent = self()

    progress_callback = fn progress ->
      send(parent, {:optimization_progress, progress})
    end

    Task.start(fn ->
      case Runner.run(config, progress_callback) do
        {:ok, result} ->
          send(parent, {:optimization_complete, result})

        {:error, reason} ->
          send(parent, {:optimization_failed, reason})
      end
    end)

    total_combinations = calculate_combinations(socket.assigns)

    {:noreply,
     assign(socket,
       run_status: :running,
       progress: %{completed: 0, total: total_combinations, pct: 0},
       results: [],
       best_params: nil
     )}
  end

  defp calculate_combinations(assigns) do
    length(assigns.selected_confluence) *
      length(assigns.selected_rr) *
      length(assigns.selected_risk)
  end

  defp load_recent_runs do
    OptimizationRun
    |> order_by([r], desc: r.inserted_at)
    |> limit(10)
    |> Repo.all()
  end

  defp load_results(run_id) do
    OptimizationResult
    |> where([r], r.optimization_run_id == ^run_id)
    |> where([r], r.is_training == true)
    |> order_by([r], desc: r.profit_factor)
    |> limit(20)
    |> Repo.all()
  end

  defp load_run_results(run_id) do
    case Repo.get(OptimizationRun, run_id) do
      nil ->
        {:error, :not_found}

      run ->
        results = load_results(run_id)
        {:ok, results, run.best_params}
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
        page_icon_color="from-purple-500 to-pink-600"
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
                do: "bg-purple-500/20 text-purple-400",
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
                do: "bg-purple-500/20 text-purple-400",
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
                do: "bg-purple-500/20 text-purple-400",
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
              <span class="text-sm text-zinc-400">Running optimization...</span>
              <button
                phx-click="cancel_optimization"
                class="text-sm text-red-400 hover:text-red-300"
              >
                Cancel
              </button>
            </div>
            <div class="w-full bg-zinc-800 rounded-full h-2 mb-2">
              <div
                class="bg-purple-500 h-2 rounded-full transition-all duration-300"
                style={"width: #{@progress.pct_complete || 0}%"}
              >
              </div>
            </div>
            <div class="flex justify-between text-xs text-zinc-500">
              <span>Combinations: {@progress.completed || 0} / {@progress.total || 0}</span>
              <span>{Float.round(@progress.pct_complete || 0.0, 1)}%</span>
            </div>
          </div>
        </div>
        
    <!-- Configuration Tab -->
        <div :if={@active_tab == :config} class="grid grid-cols-1 lg:grid-cols-3 gap-6">
          <div class="lg:col-span-2">
            <.form for={@form} phx-change="validate" phx-submit="run_optimization" class="space-y-6">
              <!-- Symbols & Strategies -->
              <div class="grid grid-cols-2 gap-6">
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
                            do: "bg-purple-500/20 text-purple-400 border border-purple-500/50",
                            else: "bg-zinc-800 text-zinc-400 border border-zinc-700"
                          )
                        ]}
                      >
                        {symbol}
                      </button>
                    <% end %>
                  </div>
                </div>

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
                            else: "bg-zinc-800 text-zinc-400 border border-zinc-700"
                          )
                        ]}
                      >
                        {label}
                      </button>
                    <% end %>
                  </div>
                </div>
              </div>
              
    <!-- Parameter Grid -->
              <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-6">
                <h3 class="text-lg font-bold text-white mb-4">Parameter Grid</h3>
                <div class="grid grid-cols-3 gap-6">
                  <!-- Min Confluence -->
                  <div>
                    <label class="block text-sm text-zinc-400 mb-2">Min Confluence Score</label>
                    <div class="flex flex-wrap gap-2">
                      <%= for val <- @confluence_options do %>
                        <button
                          type="button"
                          phx-click="toggle_confluence"
                          phx-value-value={val}
                          class={[
                            "px-3 py-1.5 rounded-lg text-sm font-medium transition-colors",
                            if(val in @selected_confluence,
                              do: "bg-amber-500/20 text-amber-400 border border-amber-500/50",
                              else: "bg-zinc-800 text-zinc-400 border border-zinc-700"
                            )
                          ]}
                        >
                          {val}
                        </button>
                      <% end %>
                    </div>
                  </div>
                  
    <!-- Min R:R -->
                  <div>
                    <label class="block text-sm text-zinc-400 mb-2">Min Risk/Reward</label>
                    <div class="flex flex-wrap gap-2">
                      <%= for val <- @rr_options do %>
                        <button
                          type="button"
                          phx-click="toggle_rr"
                          phx-value-value={val}
                          class={[
                            "px-3 py-1.5 rounded-lg text-sm font-medium transition-colors",
                            if(val in @selected_rr,
                              do: "bg-amber-500/20 text-amber-400 border border-amber-500/50",
                              else: "bg-zinc-800 text-zinc-400 border border-zinc-700"
                            )
                          ]}
                        >
                          {val}
                        </button>
                      <% end %>
                    </div>
                  </div>
                  
    <!-- Risk Per Trade -->
                  <div>
                    <label class="block text-sm text-zinc-400 mb-2">Risk Per Trade</label>
                    <div class="flex flex-wrap gap-2">
                      <%= for val <- @risk_options do %>
                        <button
                          type="button"
                          phx-click="toggle_risk"
                          phx-value-value={val}
                          class={[
                            "px-3 py-1.5 rounded-lg text-sm font-medium transition-colors",
                            if(val in @selected_risk,
                              do: "bg-amber-500/20 text-amber-400 border border-amber-500/50",
                              else: "bg-zinc-800 text-zinc-400 border border-zinc-700"
                            )
                          ]}
                        >
                          {Float.round(val * 100, 1)}%
                        </button>
                      <% end %>
                    </div>
                  </div>
                </div>
              </div>
              
    <!-- Date Range & Settings -->
              <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-6">
                <h3 class="text-lg font-bold text-white mb-4">Settings</h3>
                <div class="grid grid-cols-2 lg:grid-cols-4 gap-4">
                  <div>
                    <label class="block text-sm text-zinc-400 mb-1">Start Date</label>
                    <input
                      type="date"
                      name="optimization[start_date]"
                      value={@form[:start_date].value}
                      class="w-full bg-zinc-800 border border-zinc-700 rounded-lg px-3 py-2 text-white"
                    />
                  </div>
                  <div>
                    <label class="block text-sm text-zinc-400 mb-1">End Date</label>
                    <input
                      type="date"
                      name="optimization[end_date]"
                      value={@form[:end_date].value}
                      class="w-full bg-zinc-800 border border-zinc-700 rounded-lg px-3 py-2 text-white"
                    />
                  </div>
                  <div>
                    <label class="block text-sm text-zinc-400 mb-1">Initial Capital ($)</label>
                    <input
                      type="number"
                      name="optimization[initial_capital]"
                      value={@form[:initial_capital].value}
                      class="w-full bg-zinc-800 border border-zinc-700 rounded-lg px-3 py-2 text-white"
                    />
                  </div>
                  <div>
                    <label class="block text-sm text-zinc-400 mb-1">Min Trades</label>
                    <input
                      type="number"
                      name="optimization[min_trades]"
                      value={@form[:min_trades].value}
                      class="w-full bg-zinc-800 border border-zinc-700 rounded-lg px-3 py-2 text-white"
                    />
                  </div>
                </div>
              </div>
              
    <!-- Walk-Forward Toggle -->
              <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-6">
                <div class="flex items-center justify-between">
                  <div>
                    <h3 class="text-lg font-bold text-white">Walk-Forward Analysis</h3>
                    <p class="text-sm text-zinc-500">
                      Test for overfitting with out-of-sample validation
                    </p>
                  </div>
                  <button
                    type="button"
                    phx-click="toggle_walk_forward"
                    class={[
                      "w-12 h-6 rounded-full transition-colors relative",
                      if(@walk_forward_enabled, do: "bg-purple-500", else: "bg-zinc-700")
                    ]}
                  >
                    <span class={[
                      "absolute w-4 h-4 bg-white rounded-full top-1 transition-all",
                      if(@walk_forward_enabled, do: "left-7", else: "left-1")
                    ]} />
                  </button>
                </div>
                <div :if={@walk_forward_enabled} class="mt-4 grid grid-cols-3 gap-4">
                  <div>
                    <label class="block text-sm text-zinc-400 mb-1">Training Months</label>
                    <input
                      type="number"
                      value={@walk_forward_config.training_months}
                      disabled
                      class="w-full bg-zinc-800 border border-zinc-700 rounded-lg px-3 py-2 text-white"
                    />
                  </div>
                  <div>
                    <label class="block text-sm text-zinc-400 mb-1">Testing Months</label>
                    <input
                      type="number"
                      value={@walk_forward_config.testing_months}
                      disabled
                      class="w-full bg-zinc-800 border border-zinc-700 rounded-lg px-3 py-2 text-white"
                    />
                  </div>
                  <div>
                    <label class="block text-sm text-zinc-400 mb-1">Step Months</label>
                    <input
                      type="number"
                      value={@walk_forward_config.step_months}
                      disabled
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
                    else: "bg-purple-600 hover:bg-purple-500"
                  )
                ]}
              >
                <%= if @run_status == :running do %>
                  Running...
                <% else %>
                  Run Optimization ({calculate_combinations(assigns)} combinations)
                <% end %>
              </button>
            </.form>
          </div>
          
    <!-- Stats Sidebar -->
          <div class="space-y-4">
            <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-4">
              <h4 class="text-sm font-medium text-zinc-400 mb-3">Combinations</h4>
              <div class="text-3xl font-bold text-purple-400">
                {calculate_combinations(assigns)}
              </div>
              <p class="text-xs text-zinc-500 mt-1">
                {length(@selected_confluence)} confluence x {length(@selected_rr)} R:R x {length(
                  @selected_risk
                )} risk
              </p>
            </div>
          </div>
        </div>
        
    <!-- Results Tab -->
        <div :if={@active_tab == :results}>
          <%= if Enum.any?(@results) do %>
            <!-- Best Parameters -->
            <div :if={@best_params} class="mb-6">
              <div class="bg-gradient-to-r from-purple-900/50 to-pink-900/50 rounded-xl border border-purple-500/30 p-6">
                <h3 class="text-lg font-bold text-white mb-2">Best Parameters</h3>
                <div class="flex flex-wrap gap-4">
                  <%= for {key, value} <- @best_params || %{} do %>
                    <div class="bg-zinc-900/50 rounded-lg px-3 py-2">
                      <span class="text-xs text-zinc-500">{key}</span>
                      <span class="ml-2 text-white font-mono">{value}</span>
                    </div>
                  <% end %>
                </div>
              </div>
            </div>
            
    <!-- Results Table -->
            <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 overflow-hidden">
              <div class="px-4 py-3 border-b border-zinc-800">
                <h3 class="font-bold text-white">Top Parameter Sets</h3>
              </div>
              <div class="overflow-x-auto">
                <table class="min-w-full divide-y divide-zinc-800">
                  <thead class="bg-zinc-900/50">
                    <tr>
                      <th class="px-4 py-3 text-left text-xs font-medium text-zinc-400 uppercase">
                        Parameters
                      </th>
                      <th class="px-4 py-3 text-right text-xs font-medium text-zinc-400 uppercase">
                        Profit Factor
                      </th>
                      <th class="px-4 py-3 text-right text-xs font-medium text-zinc-400 uppercase">
                        Win Rate
                      </th>
                      <th class="px-4 py-3 text-right text-xs font-medium text-zinc-400 uppercase">
                        Net Profit
                      </th>
                      <th class="px-4 py-3 text-right text-xs font-medium text-zinc-400 uppercase">
                        Trades
                      </th>
                      <th class="px-4 py-3 text-right text-xs font-medium text-zinc-400 uppercase">
                        Max DD
                      </th>
                    </tr>
                  </thead>
                  <tbody class="divide-y divide-zinc-800">
                    <%= for result <- @results do %>
                      <tr class="hover:bg-zinc-800/50">
                        <td class="px-4 py-3 text-sm">
                          <div class="flex flex-wrap gap-1">
                            <%= for {key, value} <- result.parameters || %{} do %>
                              <span class="px-2 py-0.5 bg-zinc-800 rounded text-xs text-zinc-300">
                                {key}: {value}
                              </span>
                            <% end %>
                          </div>
                        </td>
                        <td class="px-4 py-3 text-sm text-right text-amber-400 font-mono">
                          {format_decimal(result.profit_factor)}
                        </td>
                        <td class="px-4 py-3 text-sm text-right text-white font-mono">
                          {format_pct(result.win_rate)}
                        </td>
                        <td class={"px-4 py-3 text-sm text-right font-mono #{if result.net_profit && Decimal.positive?(result.net_profit), do: "text-green-400", else: "text-red-400"}"}>
                          ${format_decimal(result.net_profit)}
                        </td>
                        <td class="px-4 py-3 text-sm text-right text-zinc-300">
                          {result.total_trades}
                        </td>
                        <td class="px-4 py-3 text-sm text-right text-red-400 font-mono">
                          {format_pct(result.max_drawdown_pct)}
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            </div>
          <% else %>
            <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 p-12 text-center">
              <.icon name="hero-adjustments-horizontal" class="w-12 h-12 text-zinc-600 mx-auto mb-4" />
              <h3 class="text-lg font-medium text-zinc-400 mb-2">No Results Yet</h3>
              <p class="text-sm text-zinc-500">
                Configure and run an optimization to see results here.
              </p>
            </div>
          <% end %>
        </div>
        
    <!-- History Tab -->
        <div :if={@active_tab == :history}>
          <div class="bg-zinc-900/50 rounded-xl border border-zinc-800 overflow-hidden">
            <div class="px-4 py-3 border-b border-zinc-800">
              <h3 class="font-bold text-white">Recent Optimization Runs</h3>
            </div>
            <%= if Enum.empty?(@recent_runs) do %>
              <div class="p-8 text-center">
                <p class="text-zinc-500">No optimization runs yet.</p>
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
                      <th class="px-4 py-3 text-center text-xs font-medium text-zinc-400 uppercase">
                        Status
                      </th>
                      <th class="px-4 py-3 text-right text-xs font-medium text-zinc-400 uppercase">
                        Combinations
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
                        <td class="px-4 py-3 text-center">
                          <span class={"px-2 py-1 text-xs rounded #{status_badge_class(run.status)}"}>
                            {run.status}
                          </span>
                        </td>
                        <td class="px-4 py-3 text-sm text-right text-zinc-300">
                          {run.total_combinations}
                        </td>
                        <td class="px-4 py-3 text-right">
                          <button
                            :if={run.status == :completed}
                            phx-click="load_run"
                            phx-value-id={run.id}
                            class="text-sm text-purple-400 hover:text-purple-300"
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
    </div>
    """
  end
end
