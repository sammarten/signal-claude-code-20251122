defmodule SignalWeb.Live.Components.PreviewComponents do
  @moduledoc """
  UI components for the Daily Market Preview page.

  Provides visual components for displaying:
  - Market context and regime
  - Index divergence analysis
  - Game plan and risk management
  - Key levels and scenarios
  - Watchlist items
  - Sector relative strength
  """

  use Phoenix.Component

  # Market Context Component

  attr :context, :string, required: true
  attr :volatility, :atom, required: true
  attr :regime, :any, required: true

  @doc """
  Renders the market context section with regime and volatility indicators.
  """
  def market_context(assigns) do
    ~H"""
    <div class="bg-zinc-900/50 backdrop-blur-sm rounded-2xl border border-zinc-800 p-6">
      <h2 class="text-lg font-semibold text-white mb-4 flex items-center gap-2">
        <svg class="w-5 h-5 text-amber-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z" />
        </svg>
        Market Context
      </h2>

      <div class="grid grid-cols-1 md:grid-cols-3 gap-4 mb-4">
        <!-- Regime Badge -->
        <div class="bg-zinc-800/50 rounded-xl p-4">
          <div class="text-zinc-400 text-sm mb-1">Market Regime</div>
          <div class={"text-xl font-bold #{regime_color(@regime)}"}>
            {regime_display(@regime)}
          </div>
        </div>

        <!-- Volatility -->
        <div class="bg-zinc-800/50 rounded-xl p-4">
          <div class="text-zinc-400 text-sm mb-1">Expected Volatility</div>
          <div class={"text-xl font-bold #{volatility_color(@volatility)}"}>
            {volatility_display(@volatility)}
          </div>
        </div>

        <!-- Trend Direction -->
        <div class="bg-zinc-800/50 rounded-xl p-4">
          <div class="text-zinc-400 text-sm mb-1">Trend Direction</div>
          <div class={"text-xl font-bold #{trend_color(@regime)}"}>
            {trend_display(@regime)}
          </div>
        </div>
      </div>

      <%= if @context do %>
        <div class="bg-zinc-800/30 rounded-xl p-4">
          <p class="text-zinc-300 leading-relaxed">{@context}</p>
        </div>
      <% end %>
    </div>
    """
  end

  # Index Divergence Component

  attr :divergence, :any, required: true

  @doc """
  Renders index divergence analysis between SPY, QQQ, and DIA.
  """
  def index_divergence(assigns) do
    ~H"""
    <div class="bg-zinc-900/50 backdrop-blur-sm rounded-2xl border border-zinc-800 p-6">
      <h2 class="text-lg font-semibold text-white mb-4 flex items-center gap-2">
        <svg class="w-5 h-5 text-blue-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M7 12l3-3 3 3 4-4M8 21l4-4 4 4M3 4h18M4 4h16v12a1 1 0 01-1 1H5a1 1 0 01-1-1V4z" />
        </svg>
        Index Divergence
      </h2>

      <%= if @divergence do %>
        <!-- Performance Table -->
        <div class="overflow-x-auto mb-4">
          <table class="w-full text-sm">
            <thead>
              <tr class="text-zinc-400 text-left">
                <th class="pb-2">Index</th>
                <th class="pb-2 text-right">1D</th>
                <th class="pb-2 text-right">5D</th>
                <th class="pb-2 text-right">From ATH</th>
                <th class="pb-2 text-right">Status</th>
              </tr>
            </thead>
            <tbody class="text-white">
              <tr class="border-t border-zinc-800">
                <td class="py-2 font-medium">SPY</td>
                <td class={"py-2 text-right font-mono #{pct_color(@divergence.spy_1d_pct)}"}>
                  {format_pct(@divergence.spy_1d_pct)}
                </td>
                <td class={"py-2 text-right font-mono #{pct_color(@divergence.spy_5d_pct)}"}>
                  {format_pct(@divergence.spy_5d_pct)}
                </td>
                <td class="py-2 text-right font-mono text-zinc-400">
                  {format_pct_negative(@divergence.spy_from_ath_pct)}
                </td>
                <td class={"py-2 text-right font-semibold #{status_color(@divergence.spy_status)}"}>
                  {status_display(@divergence.spy_status)}
                </td>
              </tr>
              <tr class="border-t border-zinc-800">
                <td class="py-2 font-medium">QQQ</td>
                <td class={"py-2 text-right font-mono #{pct_color(@divergence.qqq_1d_pct)}"}>
                  {format_pct(@divergence.qqq_1d_pct)}
                </td>
                <td class={"py-2 text-right font-mono #{pct_color(@divergence.qqq_5d_pct)}"}>
                  {format_pct(@divergence.qqq_5d_pct)}
                </td>
                <td class="py-2 text-right font-mono text-zinc-400">
                  {format_pct_negative(@divergence.qqq_from_ath_pct)}
                </td>
                <td class={"py-2 text-right font-semibold #{status_color(@divergence.qqq_status)}"}>
                  {status_display(@divergence.qqq_status)}
                </td>
              </tr>
              <tr class="border-t border-zinc-800">
                <td class="py-2 font-medium">DIA</td>
                <td class={"py-2 text-right font-mono #{pct_color(@divergence.dia_1d_pct)}"}>
                  {format_pct(@divergence.dia_1d_pct)}
                </td>
                <td class={"py-2 text-right font-mono #{pct_color(@divergence.dia_5d_pct)}"}>
                  {format_pct(@divergence.dia_5d_pct)}
                </td>
                <td class="py-2 text-right font-mono text-zinc-400">
                  {format_pct_negative(@divergence.dia_from_ath_pct)}
                </td>
                <td class={"py-2 text-right font-semibold #{status_color(@divergence.dia_status)}"}>
                  {status_display(@divergence.dia_status)}
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <!-- Leader/Laggard Summary -->
        <div class="grid grid-cols-2 gap-4 mb-4">
          <div class="bg-green-500/10 border border-green-500/20 rounded-xl p-3 text-center">
            <div class="text-green-400 text-sm mb-1">Leader</div>
            <div class="text-white font-bold text-lg">{@divergence.leader}</div>
          </div>
          <div class="bg-red-500/10 border border-red-500/20 rounded-xl p-3 text-center">
            <div class="text-red-400 text-sm mb-1">Laggard</div>
            <div class="text-white font-bold text-lg">{@divergence.laggard}</div>
          </div>
        </div>

        <!-- Implication -->
        <div class="bg-amber-500/10 border border-amber-500/20 rounded-xl p-3">
          <div class="text-amber-400 text-sm mb-1">Implication</div>
          <div class="text-white">{@divergence.implication}</div>
        </div>
      <% else %>
        <div class="text-zinc-500 text-center py-8">
          Divergence data not available
        </div>
      <% end %>
    </div>
    """
  end

  # Game Plan Component

  attr :stance, :atom, required: true
  attr :position_size, :atom, required: true
  attr :focus, :string, required: true
  attr :risk_notes, :list, required: true

  @doc """
  Renders the trading game plan with stance, position size, and risk notes.
  """
  def game_plan(assigns) do
    ~H"""
    <div class="bg-zinc-900/50 backdrop-blur-sm rounded-2xl border border-zinc-800 p-6">
      <h2 class="text-lg font-semibold text-white mb-4 flex items-center gap-2">
        <svg class="w-5 h-5 text-purple-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5H7a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2V7a2 2 0 00-2-2h-2M9 5a2 2 0 002 2h2a2 2 0 002-2M9 5a2 2 0 012-2h2a2 2 0 012 2m-3 7h3m-3 4h3m-6-4h.01M9 16h.01" />
        </svg>
        Game Plan
      </h2>

      <div class="grid grid-cols-2 gap-4 mb-4">
        <!-- Stance -->
        <div class="bg-zinc-800/50 rounded-xl p-4">
          <div class="text-zinc-400 text-sm mb-1">Stance</div>
          <div class={"text-xl font-bold #{stance_color(@stance)}"}>
            {stance_display(@stance)}
          </div>
        </div>

        <!-- Position Size -->
        <div class="bg-zinc-800/50 rounded-xl p-4">
          <div class="text-zinc-400 text-sm mb-1">Position Size</div>
          <div class={"text-xl font-bold #{size_color(@position_size)}"}>
            {size_display(@position_size)}
          </div>
        </div>
      </div>

      <!-- Focus -->
      <%= if @focus do %>
        <div class="bg-zinc-800/30 rounded-xl p-4 mb-4">
          <div class="text-zinc-400 text-sm mb-1">Focus</div>
          <div class="text-white">{@focus}</div>
        </div>
      <% end %>

      <!-- Risk Notes -->
      <%= if @risk_notes != [] do %>
        <div class="bg-red-500/10 border border-red-500/20 rounded-xl p-4">
          <div class="text-red-400 text-sm mb-2 font-semibold">Risk Notes</div>
          <ul class="space-y-1">
            <%= for note <- @risk_notes do %>
              <li class="text-zinc-300 text-sm flex items-start gap-2">
                <span class="text-red-400 mt-0.5">!</span>
                {note}
              </li>
            <% end %>
          </ul>
        </div>
      <% end %>
    </div>
    """
  end

  # Index Section Component

  attr :symbol, :string, required: true
  attr :regime, :any, required: true
  attr :scenarios, :list, required: true

  @doc """
  Renders an index section with regime info and trading scenarios.
  """
  def index_section(assigns) do
    symbol_color = if assigns.symbol == "SPY", do: "text-blue-400", else: "text-purple-400"
    assigns = assign(assigns, :symbol_color, symbol_color)

    ~H"""
    <div class="bg-zinc-900/50 backdrop-blur-sm rounded-2xl border border-zinc-800 p-6">
      <h2 class={"text-lg font-semibold text-white mb-4 flex items-center gap-2"}>
        <span class={@symbol_color}>{@symbol}</span>
        <%= if @regime do %>
          <span class={"text-sm px-2 py-0.5 rounded-full #{regime_badge_class(@regime.regime)}"}>
            {regime_display(@regime)}
          </span>
        <% end %>
      </h2>

      <!-- Regime Details -->
      <%= if @regime do %>
        <div class="grid grid-cols-2 sm:grid-cols-4 gap-3 mb-4">
          <%= if @regime.range_high do %>
            <div class="bg-zinc-800/50 rounded-lg p-3">
              <div class="text-zinc-500 text-xs">Range High</div>
              <div class="text-white font-mono">{format_price(@regime.range_high)}</div>
            </div>
          <% end %>
          <%= if @regime.range_low do %>
            <div class="bg-zinc-800/50 rounded-lg p-3">
              <div class="text-zinc-500 text-xs">Range Low</div>
              <div class="text-white font-mono">{format_price(@regime.range_low)}</div>
            </div>
          <% end %>
          <%= if @regime.distance_from_ath_percent do %>
            <div class="bg-zinc-800/50 rounded-lg p-3">
              <div class="text-zinc-500 text-xs">From ATH</div>
              <div class="text-red-400 font-mono">{format_pct_negative(@regime.distance_from_ath_percent)}</div>
            </div>
          <% end %>
          <%= if @regime.range_duration_days do %>
            <div class="bg-zinc-800/50 rounded-lg p-3">
              <div class="text-zinc-500 text-xs">Range Days</div>
              <div class="text-white font-mono">{@regime.range_duration_days}</div>
            </div>
          <% end %>
        </div>
      <% end %>

      <!-- Scenarios -->
      <div class="space-y-3">
        <h3 class="text-sm font-medium text-zinc-400">Scenarios</h3>
        <%= if @scenarios == [] do %>
          <div class="text-zinc-500 text-sm">No scenarios available</div>
        <% else %>
          <%= for scenario <- @scenarios do %>
            <.scenario_card scenario={scenario} />
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  attr :scenario, :any, required: true

  defp scenario_card(assigns) do
    ~H"""
    <div class={"rounded-xl p-4 #{scenario_bg(@scenario.type)}"}>
      <div class="flex items-center justify-between mb-2">
        <span class={"font-semibold #{scenario_type_color(@scenario.type)}"}>
          {scenario_type_display(@scenario.type)}
        </span>
        <span class="text-zinc-400 text-sm">{@scenario.trigger_condition}</span>
      </div>
      <div class="grid grid-cols-2 gap-4 mb-2">
        <div>
          <div class="text-zinc-500 text-xs">Trigger</div>
          <div class="text-white font-mono">{format_price(@scenario.trigger_level)}</div>
        </div>
        <div>
          <div class="text-zinc-500 text-xs">Target</div>
          <div class="text-white font-mono">{format_price(@scenario.target_level)}</div>
        </div>
      </div>
      <p class="text-zinc-400 text-sm">{@scenario.description}</p>
    </div>
    """
  end

  # Watchlist Component

  attr :high_conviction, :list, required: true
  attr :monitoring, :list, required: true
  attr :avoid, :list, required: true

  @doc """
  Renders the watchlist with high conviction, monitoring, and avoid sections.
  """
  def watchlist(assigns) do
    ~H"""
    <div class="bg-zinc-900/50 backdrop-blur-sm rounded-2xl border border-zinc-800 p-6">
      <h2 class="text-lg font-semibold text-white mb-4 flex items-center gap-2">
        <svg class="w-5 h-5 text-green-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5H7a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2V7a2 2 0 00-2-2h-2M9 5a2 2 0 002 2h2a2 2 0 002-2M9 5a2 2 0 012-2h2a2 2 0 012 2" />
        </svg>
        Watchlist
      </h2>

      <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
        <!-- High Conviction -->
        <div class="bg-green-500/10 border border-green-500/20 rounded-xl p-4">
          <h3 class="text-green-400 font-semibold mb-3 flex items-center gap-2">
            <svg class="w-4 h-4" fill="currentColor" viewBox="0 0 20 20">
              <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z" clip-rule="evenodd" />
            </svg>
            High Conviction
          </h3>
          <%= if @high_conviction == [] do %>
            <div class="text-zinc-500 text-sm">No high conviction plays</div>
          <% else %>
            <div class="space-y-2">
              <%= for item <- @high_conviction do %>
                <.watchlist_item item={item} />
              <% end %>
            </div>
          <% end %>
        </div>

        <!-- Monitoring -->
        <div class="bg-amber-500/10 border border-amber-500/20 rounded-xl p-4">
          <h3 class="text-amber-400 font-semibold mb-3 flex items-center gap-2">
            <svg class="w-4 h-4" fill="currentColor" viewBox="0 0 20 20">
              <path d="M10 12a2 2 0 100-4 2 2 0 000 4z" />
              <path fill-rule="evenodd" d="M.458 10C1.732 5.943 5.522 3 10 3s8.268 2.943 9.542 7c-1.274 4.057-5.064 7-9.542 7S1.732 14.057.458 10zM14 10a4 4 0 11-8 0 4 4 0 018 0z" clip-rule="evenodd" />
            </svg>
            Monitoring
          </h3>
          <%= if @monitoring == [] do %>
            <div class="text-zinc-500 text-sm">No symbols to monitor</div>
          <% else %>
            <div class="space-y-2">
              <%= for item <- @monitoring do %>
                <.watchlist_item item={item} />
              <% end %>
            </div>
          <% end %>
        </div>

        <!-- Avoid -->
        <div class="bg-red-500/10 border border-red-500/20 rounded-xl p-4">
          <h3 class="text-red-400 font-semibold mb-3 flex items-center gap-2">
            <svg class="w-4 h-4" fill="currentColor" viewBox="0 0 20 20">
              <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zM8.707 7.293a1 1 0 00-1.414 1.414L8.586 10l-1.293 1.293a1 1 0 101.414 1.414L10 11.414l1.293 1.293a1 1 0 001.414-1.414L11.414 10l1.293-1.293a1 1 0 00-1.414-1.414L10 8.586 8.707 7.293z" clip-rule="evenodd" />
            </svg>
            Avoid
          </h3>
          <%= if @avoid == [] do %>
            <div class="text-zinc-500 text-sm">No symbols to avoid</div>
          <% else %>
            <div class="space-y-2">
              <%= for item <- @avoid do %>
                <.watchlist_item item={item} />
              <% end %>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  attr :item, :any, required: true

  defp watchlist_item(assigns) do
    ~H"""
    <div class="bg-zinc-900/50 rounded-lg p-3">
      <div class="flex items-center justify-between mb-1">
        <span class="text-white font-semibold">{@item.symbol}</span>
        <span class={"text-xs px-2 py-0.5 rounded-full #{bias_badge_class(@item.bias)}"}>
          {bias_display(@item.bias)}
        </span>
      </div>
      <div class="text-zinc-400 text-sm mb-1">{@item.setup}</div>
      <div class="flex items-center justify-between text-xs">
        <span class="text-zinc-500">Key: {format_price(@item.key_level)}</span>
        <%= if @item.notes do %>
          <span class="text-zinc-500 truncate ml-2">{@item.notes}</span>
        <% end %>
      </div>
    </div>
    """
  end

  # Sector Notes Component

  attr :leaders, :list, required: true
  attr :laggards, :list, required: true

  @doc """
  Renders relative strength leaders and laggards.
  """
  def sector_notes(assigns) do
    ~H"""
    <div class="bg-zinc-900/50 backdrop-blur-sm rounded-2xl border border-zinc-800 p-6">
      <h2 class="text-lg font-semibold text-white mb-4 flex items-center gap-2">
        <svg class="w-5 h-5 text-cyan-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 7h8m0 0v8m0-8l-8 8-4-4-6 6" />
        </svg>
        Relative Strength
      </h2>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
        <!-- Leaders -->
        <div class="bg-green-500/10 border border-green-500/20 rounded-xl p-4">
          <h3 class="text-green-400 font-semibold mb-3">RS Leaders</h3>
          <%= if @leaders == [] do %>
            <div class="text-zinc-500 text-sm">No leaders identified</div>
          <% else %>
            <div class="flex flex-wrap gap-2">
              <%= for symbol <- @leaders do %>
                <span class="bg-green-500/20 text-green-300 px-3 py-1 rounded-full text-sm font-medium">
                  {symbol}
                </span>
              <% end %>
            </div>
          <% end %>
        </div>

        <!-- Laggards -->
        <div class="bg-red-500/10 border border-red-500/20 rounded-xl p-4">
          <h3 class="text-red-400 font-semibold mb-3">RS Laggards</h3>
          <%= if @laggards == [] do %>
            <div class="text-zinc-500 text-sm">No laggards identified</div>
          <% else %>
            <div class="flex flex-wrap gap-2">
              <%= for symbol <- @laggards do %>
                <span class="bg-red-500/20 text-red-300 px-3 py-1 rounded-full text-sm font-medium">
                  {symbol}
                </span>
              <% end %>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # Helper Functions

  defp regime_display(nil), do: "Unknown"
  defp regime_display(%{regime: :trending_up}), do: "Trending Up"
  defp regime_display(%{regime: :trending_down}), do: "Trending Down"
  defp regime_display(%{regime: :ranging}), do: "Ranging"
  defp regime_display(%{regime: :breakout_pending}), do: "Breakout Pending"
  defp regime_display(_), do: "Unknown"

  defp regime_color(nil), do: "text-zinc-400"
  defp regime_color(%{regime: :trending_up}), do: "text-green-400"
  defp regime_color(%{regime: :trending_down}), do: "text-red-400"
  defp regime_color(%{regime: :ranging}), do: "text-amber-400"
  defp regime_color(%{regime: :breakout_pending}), do: "text-purple-400"
  defp regime_color(_), do: "text-zinc-400"

  defp regime_badge_class(:trending_up), do: "bg-green-500/20 text-green-400"
  defp regime_badge_class(:trending_down), do: "bg-red-500/20 text-red-400"
  defp regime_badge_class(:ranging), do: "bg-amber-500/20 text-amber-400"
  defp regime_badge_class(:breakout_pending), do: "bg-purple-500/20 text-purple-400"
  defp regime_badge_class(_), do: "bg-zinc-500/20 text-zinc-400"

  defp trend_display(nil), do: "N/A"
  defp trend_display(%{trend_direction: :up}), do: "Up"
  defp trend_display(%{trend_direction: :down}), do: "Down"
  defp trend_display(%{trend_direction: :neutral}), do: "Neutral"
  defp trend_display(_), do: "N/A"

  defp trend_color(nil), do: "text-zinc-400"
  defp trend_color(%{trend_direction: :up}), do: "text-green-400"
  defp trend_color(%{trend_direction: :down}), do: "text-red-400"
  defp trend_color(%{trend_direction: :neutral}), do: "text-amber-400"
  defp trend_color(_), do: "text-zinc-400"

  defp volatility_display(:high), do: "High"
  defp volatility_display(:normal), do: "Normal"
  defp volatility_display(:low), do: "Low"
  defp volatility_display(_), do: "Unknown"

  defp volatility_color(:high), do: "text-red-400"
  defp volatility_color(:normal), do: "text-amber-400"
  defp volatility_color(:low), do: "text-green-400"
  defp volatility_color(_), do: "text-zinc-400"

  defp stance_display(:aggressive), do: "Aggressive"
  defp stance_display(:normal), do: "Normal"
  defp stance_display(:cautious), do: "Cautious"
  defp stance_display(:hands_off), do: "Hands Off"
  defp stance_display(_), do: "Unknown"

  defp stance_color(:aggressive), do: "text-green-400"
  defp stance_color(:normal), do: "text-blue-400"
  defp stance_color(:cautious), do: "text-amber-400"
  defp stance_color(:hands_off), do: "text-red-400"
  defp stance_color(_), do: "text-zinc-400"

  defp size_display(:full), do: "Full Size"
  defp size_display(:half), do: "Half Size"
  defp size_display(:quarter), do: "Quarter Size"
  defp size_display(_), do: "Unknown"

  defp size_color(:full), do: "text-green-400"
  defp size_color(:half), do: "text-amber-400"
  defp size_color(:quarter), do: "text-red-400"
  defp size_color(_), do: "text-zinc-400"

  defp status_display(:leading), do: "Leading"
  defp status_display(:lagging), do: "Lagging"
  defp status_display(:neutral), do: "Neutral"
  defp status_display(_), do: "N/A"

  defp status_color(:leading), do: "text-green-400"
  defp status_color(:lagging), do: "text-red-400"
  defp status_color(:neutral), do: "text-zinc-400"
  defp status_color(_), do: "text-zinc-400"

  defp scenario_type_display(:bullish), do: "Bullish"
  defp scenario_type_display(:bearish), do: "Bearish"
  defp scenario_type_display(:bounce), do: "Bounce"
  defp scenario_type_display(:fade), do: "Fade"
  defp scenario_type_display(_), do: "Unknown"

  defp scenario_type_color(:bullish), do: "text-green-400"
  defp scenario_type_color(:bearish), do: "text-red-400"
  defp scenario_type_color(:bounce), do: "text-blue-400"
  defp scenario_type_color(:fade), do: "text-amber-400"
  defp scenario_type_color(_), do: "text-zinc-400"

  defp scenario_bg(:bullish), do: "bg-green-500/10 border border-green-500/20"
  defp scenario_bg(:bearish), do: "bg-red-500/10 border border-red-500/20"
  defp scenario_bg(:bounce), do: "bg-blue-500/10 border border-blue-500/20"
  defp scenario_bg(:fade), do: "bg-amber-500/10 border border-amber-500/20"
  defp scenario_bg(_), do: "bg-zinc-800/50"

  defp bias_display(:long), do: "Long"
  defp bias_display(:short), do: "Short"
  defp bias_display(:neutral), do: "Neutral"
  defp bias_display(_), do: "N/A"

  defp bias_badge_class(:long), do: "bg-green-500/30 text-green-300"
  defp bias_badge_class(:short), do: "bg-red-500/30 text-red-300"
  defp bias_badge_class(:neutral), do: "bg-zinc-500/30 text-zinc-300"
  defp bias_badge_class(_), do: "bg-zinc-500/30 text-zinc-300"

  defp format_price(nil), do: "N/A"

  defp format_price(%Decimal{} = price) do
    "$#{Decimal.round(price, 2)}"
  end

  defp format_price(price) when is_number(price) do
    "$#{Float.round(price / 1, 2)}"
  end

  defp format_pct(nil), do: "N/A"

  defp format_pct(%Decimal{} = pct) do
    value = Decimal.to_float(pct)
    sign = if value >= 0, do: "+", else: ""
    "#{sign}#{Float.round(value, 2)}%"
  end

  defp format_pct_negative(nil), do: "N/A"

  defp format_pct_negative(%Decimal{} = pct) do
    value = Decimal.to_float(pct)
    "-#{Float.round(value, 2)}%"
  end

  defp pct_color(nil), do: "text-zinc-400"

  defp pct_color(%Decimal{} = pct) do
    case Decimal.compare(pct, Decimal.new(0)) do
      :gt -> "text-green-400"
      :lt -> "text-red-400"
      _ -> "text-zinc-400"
    end
  end
end
