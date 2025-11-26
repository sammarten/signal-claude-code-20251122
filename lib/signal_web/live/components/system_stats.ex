defmodule SignalWeb.Live.Components.SystemStats do
  use Phoenix.Component
  import SignalWeb.CoreComponents
  alias Signal.MarketStatus

  @moduledoc """
  System statistics component with collapsible header displaying connection status, message rates, and system health.

  ## Examples

      <.system_stats_header
        connection_status={:connected}
        connection_details=%{attempt: 0}
        stats=%{
          quotes_per_sec: 137,
          bars_per_min: 25,
          trades_per_sec: 5,
          uptime_seconds: 9240,
          db_healthy: true,
          last_quote: ~U[2024-11-15 14:30:45Z],
          last_bar: ~U[2024-11-15 14:30:00Z]
        }
        expanded={false}
      />
  """

  attr :connection_status, :atom, required: true
  attr :connection_details, :map, default: %{}
  attr :stats, :map, required: true
  attr :expanded, :boolean, default: false

  @doc """
  Compact horizontal header with all system stats, expandable to detailed view.
  """
  def system_stats_header(assigns) do
    assigns = assign(assigns, :health, calculate_health(assigns.stats, assigns.connection_status))

    ~H"""
    <div class="bg-zinc-900/50 backdrop-blur-sm rounded-xl border border-zinc-800 overflow-hidden transition-all duration-300">
      <!-- Compact Header (Always Visible) -->
      <button
        type="button"
        phx-click="toggle_stats"
        class="w-full px-4 py-3 flex items-center justify-between hover:bg-zinc-800/30 transition-colors cursor-pointer"
      >
        <!-- Left: Health + Stats -->
        <div class="flex items-center gap-6 flex-wrap">
          <!-- Health Indicator -->
          <div class={[
            "flex items-center gap-2 px-3 py-1 rounded-lg text-sm font-medium",
            health_pill_class(@health)
          ]}>
            <.icon name={health_icon(@health)} class="size-4" />
            <span class="hidden sm:inline">{health_text_short(@health)}</span>
          </div>
          
    <!-- Divider -->
          <div class="hidden md:block h-5 w-px bg-zinc-700" />
          
    <!-- Connection -->
          <div class="flex items-center gap-2">
            <div class={["w-2 h-2 rounded-full", connection_dot_class(@connection_status)]} />
            <.icon name="hero-wifi" class={"size-4 #{connection_icon_class(@connection_status)}"} />
            <span class="text-sm text-zinc-300 hidden lg:inline">
              {connection_status_text(@connection_status, @connection_details)}
            </span>
          </div>
          
    <!-- Divider -->
          <div class="hidden md:block h-5 w-px bg-zinc-700" />
          
    <!-- Message Rates -->
          <div class="flex items-center gap-4 text-sm">
            <div class="flex items-center gap-1.5">
              <span class="text-zinc-500">Q:</span>
              <span class="text-white font-mono font-medium">{@stats.quotes_per_sec}/s</span>
            </div>
            <div class="flex items-center gap-1.5">
              <span class="text-zinc-500">B:</span>
              <span class="text-white font-mono font-medium">{@stats.bars_per_min}/m</span>
            </div>
          </div>
          
    <!-- Divider -->
          <div class="hidden lg:block h-5 w-px bg-zinc-700" />
          
    <!-- Database -->
          <div class="hidden lg:flex items-center gap-1.5">
            <.icon name="hero-circle-stack" class={"size-4 #{db_icon_class(@stats.db_healthy)}"} />
            <span class={["text-sm font-medium", db_text_class_dark(@stats.db_healthy)]}>
              {if @stats.db_healthy, do: "DB OK", else: "DB Error"}
            </span>
          </div>
          
    <!-- Divider -->
          <div class="hidden lg:block h-5 w-px bg-zinc-700" />
          
    <!-- Uptime -->
          <div class="hidden lg:flex items-center gap-1.5">
            <.icon name="hero-clock" class="size-4 text-purple-400" />
            <span class="text-sm text-white font-mono">{format_uptime(@stats.uptime_seconds)}</span>
          </div>
          
    <!-- Divider -->
          <div class="hidden xl:block h-5 w-px bg-zinc-700" />
          
    <!-- Market Status -->
          <div class="hidden xl:flex items-center gap-1.5">
            <.icon
              name="hero-building-office-2"
              class={"size-4 #{MarketStatus.color_class(MarketStatus.current())}"}
            />
            <span class={["text-sm font-medium", MarketStatus.color_class(MarketStatus.current())]}>
              {MarketStatus.label(MarketStatus.current())}
            </span>
          </div>
        </div>
        
    <!-- Right: Expand Button -->
        <div class="flex items-center gap-2 text-zinc-400 hover:text-zinc-200 transition-colors ml-4">
          <span class="text-xs hidden sm:inline">
            {if @expanded, do: "Collapse", else: "Details"}
          </span>
          <.icon
            name={if @expanded, do: "hero-chevron-up", else: "hero-chevron-down"}
            class="size-5"
          />
        </div>
      </button>
      
    <!-- Expanded Details -->
      <%= if @expanded do %>
        <div class="border-t border-zinc-800 p-6 animate-fade-in">
          <!-- Overall Health Banner -->
          <div class={[
            "mb-6 p-4 rounded-xl text-center font-bold backdrop-blur-sm transition-all duration-300",
            health_banner_class_dark(@health)
          ]}>
            <div class="flex items-center justify-center gap-3">
              <.icon name={health_icon(@health)} class="size-7" />
              <span class="text-lg">{health_text(@health)}</span>
            </div>
          </div>
          
    <!-- Stats Grid -->
          <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
            <!-- Connection Status -->
            <div class="bg-zinc-800/50 rounded-xl p-4 hover:bg-zinc-800/70 transition-all duration-300 border border-zinc-700/50 hover:border-zinc-600">
              <div class="flex items-center gap-2 mb-2">
                <.icon
                  name="hero-wifi"
                  class={"size-5 #{connection_icon_class(@connection_status)}"}
                />
                <div class="text-sm font-medium text-zinc-400">Connection</div>
              </div>
              <div class="text-lg font-bold text-white">
                {connection_status_text(@connection_status, @connection_details)}
              </div>
              <div class="text-xs text-zinc-500 mt-1">
                WebSocket Stream
              </div>
            </div>
            
    <!-- Message Rates -->
            <div class="bg-zinc-800/50 rounded-xl p-4 hover:bg-zinc-800/70 transition-all duration-300 border border-zinc-700/50 hover:border-zinc-600">
              <div class="flex items-center gap-2 mb-2">
                <.icon name="hero-chat-bubble-left-right" class="size-5 text-blue-400" />
                <div class="text-sm font-medium text-zinc-400">Message Rates</div>
              </div>
              <div class="space-y-1">
                <div class="flex justify-between items-center">
                  <span class="text-xs text-zinc-500">Quotes:</span>
                  <span class="text-sm font-bold text-white">{@stats.quotes_per_sec}/sec</span>
                </div>
                <div class="flex justify-between items-center">
                  <span class="text-xs text-zinc-500">Bars:</span>
                  <span class="text-sm font-bold text-white">{@stats.bars_per_min}/min</span>
                </div>
                <%= if @stats[:trades_per_sec] && @stats.trades_per_sec > 0 do %>
                  <div class="flex justify-between items-center">
                    <span class="text-xs text-zinc-500">Trades:</span>
                    <span class="text-sm font-bold text-white">{@stats.trades_per_sec}/sec</span>
                  </div>
                <% end %>
              </div>
            </div>
            
    <!-- Database Health -->
            <div class="bg-zinc-800/50 rounded-xl p-4 hover:bg-zinc-800/70 transition-all duration-300 border border-zinc-700/50 hover:border-zinc-600">
              <div class="flex items-center gap-2 mb-2">
                <.icon name="hero-circle-stack" class={"size-5 #{db_icon_class(@stats.db_healthy)}"} />
                <div class="text-sm font-medium text-zinc-400">Database</div>
              </div>
              <div class={["text-lg font-bold", db_text_class_dark(@stats.db_healthy)]}>
                {if @stats.db_healthy, do: "Healthy", else: "Error"}
              </div>
              <div class="text-xs text-zinc-500 mt-1">
                TimescaleDB
              </div>
            </div>
            
    <!-- System Uptime -->
            <div class="bg-zinc-800/50 rounded-xl p-4 hover:bg-zinc-800/70 transition-all duration-300 border border-zinc-700/50 hover:border-zinc-600">
              <div class="flex items-center gap-2 mb-2">
                <.icon name="hero-clock" class="size-5 text-purple-400" />
                <div class="text-sm font-medium text-zinc-400">Uptime</div>
              </div>
              <div class="text-lg font-bold text-white">
                {format_uptime(@stats.uptime_seconds)}
              </div>
              <div class="text-xs text-zinc-500 mt-1">
                {uptime_status_text(@stats.uptime_seconds)}
              </div>
            </div>
          </div>
          
    <!-- Last Message Timestamps -->
          <%= if @stats[:last_quote] || @stats[:last_bar] do %>
            <div class="mt-6 pt-6 border-t border-zinc-800">
              <div class="flex items-center gap-2 mb-3">
                <.icon name="hero-arrow-path" class="size-4 text-zinc-400" />
                <h3 class="text-sm font-medium text-zinc-400">Last Updates</h3>
              </div>
              <div class="grid grid-cols-2 gap-4">
                <%= if @stats[:last_quote] do %>
                  <div class="bg-zinc-800/30 rounded-lg p-3">
                    <div class="text-xs text-zinc-500 mb-1">Last Quote</div>
                    <div class="text-sm font-medium text-white">{time_ago(@stats.last_quote)}</div>
                  </div>
                <% end %>
                <%= if @stats[:last_bar] do %>
                  <div class="bg-zinc-800/30 rounded-lg p-3">
                    <div class="text-xs text-zinc-500 mb-1">Last Bar</div>
                    <div class="text-sm font-medium text-white">{time_ago(@stats.last_bar)}</div>
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>
          
    <!-- Market Status Indicator -->
          <div class="mt-4 pt-4 border-t border-zinc-800">
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-2">
                <.icon
                  name="hero-building-office-2"
                  class={"size-4 #{MarketStatus.color_class(MarketStatus.current())}"}
                />
                <span class="text-sm font-medium text-zinc-300">Market Status</span>
              </div>
              <span class={[
                "text-xs font-bold px-3 py-1.5 rounded-lg transition-all duration-300",
                MarketStatus.badge_class(MarketStatus.current())
              ]}>
                {MarketStatus.label(MarketStatus.current())}
              </span>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # Legacy component for backwards compatibility
  attr :connection_status, :atom, required: true
  attr :connection_details, :map, default: %{}
  attr :stats, :map, required: true

  def system_stats(assigns) do
    assigns = assign(assigns, :expanded, true)
    system_stats_header(assigns)
  end

  # Helper Functions

  defp calculate_health(stats, connection_status) do
    cond do
      # Critical: disconnected or database unhealthy
      connection_status == :disconnected -> :error
      not stats.db_healthy -> :error
      # Degraded: reconnecting or no messages during market hours
      connection_status == :reconnecting -> :degraded
      stats.quotes_per_sec == 0 and MarketStatus.open?() -> :degraded
      stats.bars_per_min == 0 and MarketStatus.open?() -> :degraded
      # Healthy: all systems operational
      true -> :healthy
    end
  end

  defp format_uptime(seconds) when is_integer(seconds) and seconds >= 0 do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    remaining_seconds = rem(seconds, 60)

    cond do
      hours > 0 -> "#{hours}h #{minutes}m"
      minutes > 0 -> "#{minutes}m #{remaining_seconds}s"
      true -> "#{seconds}s"
    end
  end

  defp format_uptime(_), do: "0s"

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

  defp uptime_status_text(seconds) when is_integer(seconds) and seconds >= 0 do
    cond do
      seconds < 60 -> "Just started"
      seconds < 3600 -> "Recently started"
      seconds < 86400 -> "Running today"
      true -> "Running #{div(seconds, 86400)} days"
    end
  end

  defp uptime_status_text(_), do: "Unknown"

  # Styling Helpers

  defp health_banner_class_dark(:healthy),
    do: "bg-green-500/20 text-green-400 border border-green-500/30 shadow-lg shadow-green-500/10"

  defp health_banner_class_dark(:degraded),
    do:
      "bg-yellow-500/20 text-yellow-400 border border-yellow-500/30 shadow-lg shadow-yellow-500/10"

  defp health_banner_class_dark(:error),
    do: "bg-red-500/20 text-red-400 border border-red-500/30 shadow-lg shadow-red-500/10"

  defp health_icon(:healthy), do: "hero-check-circle"
  defp health_icon(:degraded), do: "hero-exclamation-triangle"
  defp health_icon(:error), do: "hero-x-circle"

  defp health_text(:healthy), do: "All Systems Operational"
  defp health_text(:degraded), do: "Degraded Performance"
  defp health_text(:error), do: "System Error Detected"

  defp health_text_short(:healthy), do: "Operational"
  defp health_text_short(:degraded), do: "Degraded"
  defp health_text_short(:error), do: "Error"

  defp health_pill_class(:healthy),
    do: "bg-green-500/20 text-green-400 border border-green-500/30"

  defp health_pill_class(:degraded),
    do: "bg-yellow-500/20 text-yellow-400 border border-yellow-500/30"

  defp health_pill_class(:error),
    do: "bg-red-500/20 text-red-400 border border-red-500/30"

  defp connection_dot_class(:connected), do: "bg-green-400 animate-pulse"
  defp connection_dot_class(:disconnected), do: "bg-red-400"
  defp connection_dot_class(:reconnecting), do: "bg-yellow-400 animate-pulse"
  defp connection_dot_class(_), do: "bg-zinc-400"

  defp connection_icon_class(:connected), do: "text-green-500"
  defp connection_icon_class(:disconnected), do: "text-red-500"
  defp connection_icon_class(:reconnecting), do: "text-yellow-500"
  defp connection_icon_class(_), do: "text-gray-400"

  defp connection_status_text(:connected, _details), do: "Connected"
  defp connection_status_text(:disconnected, _details), do: "Disconnected"

  defp connection_status_text(:reconnecting, details),
    do: "Reconnecting (#{Map.get(details, :attempt, 0)})"

  defp connection_status_text(_, _), do: "Unknown"

  defp db_icon_class(true), do: "text-green-500"
  defp db_icon_class(false), do: "text-red-500"

  defp db_text_class_dark(true), do: "text-green-400"
  defp db_text_class_dark(false), do: "text-red-400"
end
