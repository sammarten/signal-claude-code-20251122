defmodule SignalWeb.Live.Components.StrategyPerformance do
  use Phoenix.Component
  import SignalWeb.CoreComponents

  @moduledoc """
  Strategy performance metrics component.

  Displays aggregate statistics about signal generation including:
  - Signals by strategy
  - Signals by grade distribution
  - Win/loss metrics (when P&L data available)
  """

  attr :signals, :list, required: true
  attr :class, :string, default: ""

  @doc """
  Renders strategy performance metrics panel.
  """
  def strategy_performance(assigns) do
    assigns =
      assigns
      |> assign(:stats, calculate_stats(assigns.signals))

    ~H"""
    <div class={["bg-zinc-900/50 rounded-xl border border-zinc-800 overflow-hidden", @class]}>
      <div class="px-4 py-3 border-b border-zinc-800 bg-zinc-900/80">
        <h3 class="font-bold text-white flex items-center gap-2">
          <.icon name="hero-chart-pie" class="w-5 h-5 text-amber-400" /> Strategy Performance
        </h3>
      </div>

      <div class="p-4 space-y-6">
        <!-- Grade Distribution -->
        <div>
          <h4 class="text-sm font-medium text-zinc-400 mb-3">Grade Distribution</h4>
          <div class="space-y-2">
            <%= for {grade, count} <- @stats.by_grade do %>
              <div class="flex items-center gap-3">
                <span class={"w-8 text-center font-bold #{grade_color(grade)}"}>{grade}</span>
                <div class="flex-1 bg-zinc-800 rounded-full h-2 overflow-hidden">
                  <div
                    class={"h-full rounded-full #{grade_bar_color(grade)}"}
                    style={"width: #{grade_percentage(@stats.by_grade, grade)}%"}
                  >
                  </div>
                </div>
                <span class="text-sm font-mono text-zinc-400 w-8 text-right">{count}</span>
              </div>
            <% end %>
          </div>
        </div>
        
    <!-- Strategy Breakdown -->
        <div>
          <h4 class="text-sm font-medium text-zinc-400 mb-3">By Strategy</h4>
          <div class="space-y-2">
            <%= for {strategy, count} <- @stats.by_strategy do %>
              <div class="flex items-center justify-between text-sm">
                <span class="text-zinc-300">{strategy_display_name(strategy)}</span>
                <span class="font-mono text-white">{count}</span>
              </div>
            <% end %>
          </div>
        </div>
        
    <!-- Direction Split -->
        <div>
          <h4 class="text-sm font-medium text-zinc-400 mb-3">Direction</h4>
          <div class="grid grid-cols-2 gap-4">
            <div class="bg-green-500/10 rounded-lg p-3 text-center">
              <div class="text-2xl font-bold text-green-400">{@stats.long_count}</div>
              <div class="text-xs text-zinc-500">Long</div>
            </div>
            <div class="bg-red-500/10 rounded-lg p-3 text-center">
              <div class="text-2xl font-bold text-red-400">{@stats.short_count}</div>
              <div class="text-xs text-zinc-500">Short</div>
            </div>
          </div>
        </div>
        
    <!-- Status Summary -->
        <div>
          <h4 class="text-sm font-medium text-zinc-400 mb-3">Status</h4>
          <div class="grid grid-cols-2 gap-2">
            <div class="flex justify-between text-sm">
              <span class="text-zinc-400">Active</span>
              <span class="font-mono text-green-400">{@stats.active_count}</span>
            </div>
            <div class="flex justify-between text-sm">
              <span class="text-zinc-400">Filled</span>
              <span class="font-mono text-blue-400">{@stats.filled_count}</span>
            </div>
            <div class="flex justify-between text-sm">
              <span class="text-zinc-400">Expired</span>
              <span class="font-mono text-zinc-500">{@stats.expired_count}</span>
            </div>
            <div class="flex justify-between text-sm">
              <span class="text-zinc-400">Invalidated</span>
              <span class="font-mono text-red-400">{@stats.invalidated_count}</span>
            </div>
          </div>
        </div>
        
    <!-- Average Metrics -->
        <%= if @stats.total > 0 do %>
          <div>
            <h4 class="text-sm font-medium text-zinc-400 mb-3">Averages</h4>
            <div class="space-y-2">
              <div class="flex justify-between text-sm">
                <span class="text-zinc-400">Avg Confluence Score</span>
                <span class="font-mono text-amber-400">
                  {Float.round(@stats.avg_confluence, 1)}/13
                </span>
              </div>
              <div class="flex justify-between text-sm">
                <span class="text-zinc-400">Avg Risk/Reward</span>
                <span class="font-mono text-amber-400">
                  {Float.round(@stats.avg_rr, 1)}:1
                </span>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # Private helpers

  defp calculate_stats(signals) do
    total = length(signals)

    by_grade =
      signals
      |> Enum.group_by(& &1.quality_grade)
      |> Enum.map(fn {grade, sigs} -> {grade, length(sigs)} end)
      |> Enum.sort_by(fn {grade, _} -> grade_order(grade) end)

    by_strategy =
      signals
      |> Enum.group_by(& &1.strategy)
      |> Enum.map(fn {strategy, sigs} -> {strategy, length(sigs)} end)
      |> Enum.sort_by(fn {_, count} -> -count end)

    long_count = Enum.count(signals, &(&1.direction == "long"))
    short_count = Enum.count(signals, &(&1.direction == "short"))

    active_count = Enum.count(signals, &(&1.status == "active"))
    filled_count = Enum.count(signals, &(&1.status == "filled"))
    expired_count = Enum.count(signals, &(&1.status == "expired"))
    invalidated_count = Enum.count(signals, &(&1.status == "invalidated"))

    avg_confluence =
      if total > 0 do
        signals
        |> Enum.map(& &1.confluence_score)
        |> Enum.sum()
        |> Kernel./(total)
      else
        0.0
      end

    avg_rr =
      if total > 0 do
        signals
        |> Enum.map(&Decimal.to_float(&1.risk_reward))
        |> Enum.sum()
        |> Kernel./(total)
      else
        0.0
      end

    %{
      total: total,
      by_grade: by_grade,
      by_strategy: by_strategy,
      long_count: long_count,
      short_count: short_count,
      active_count: active_count,
      filled_count: filled_count,
      expired_count: expired_count,
      invalidated_count: invalidated_count,
      avg_confluence: avg_confluence,
      avg_rr: avg_rr
    }
  end

  defp grade_order("A"), do: 1
  defp grade_order("B"), do: 2
  defp grade_order("C"), do: 3
  defp grade_order("D"), do: 4
  defp grade_order("F"), do: 5
  defp grade_order(_), do: 6

  defp grade_color("A"), do: "text-green-400"
  defp grade_color("B"), do: "text-blue-400"
  defp grade_color("C"), do: "text-yellow-400"
  defp grade_color("D"), do: "text-orange-400"
  defp grade_color("F"), do: "text-red-400"
  defp grade_color(_), do: "text-zinc-400"

  defp grade_bar_color("A"), do: "bg-green-500"
  defp grade_bar_color("B"), do: "bg-blue-500"
  defp grade_bar_color("C"), do: "bg-yellow-500"
  defp grade_bar_color("D"), do: "bg-orange-500"
  defp grade_bar_color("F"), do: "bg-red-500"
  defp grade_bar_color(_), do: "bg-zinc-500"

  defp grade_percentage(by_grade, grade) do
    total = Enum.reduce(by_grade, 0, fn {_, count}, acc -> acc + count end)

    if total > 0 do
      count = Keyword.get(by_grade, grade, 0)
      count / total * 100
    else
      0
    end
  end

  defp strategy_display_name("break_and_retest"), do: "Break & Retest"
  defp strategy_display_name("opening_range_breakout"), do: "Opening Range"
  defp strategy_display_name("one_candle_rule"), do: "One Candle Rule"
  defp strategy_display_name("premarket_breakout"), do: "Premarket Breakout"
  defp strategy_display_name(strategy), do: strategy
end
