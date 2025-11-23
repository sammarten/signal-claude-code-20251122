defmodule SignalWeb.Live.Components.SystemStats do
  use Phoenix.Component
  import SignalWeb.CoreComponents

  @moduledoc """
  System statistics component displaying connection status, message rates, and system health.

  ## Examples

      <.system_stats
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
      />
  """

  attr :connection_status, :atom, required: true
  attr :connection_details, :map, default: %{}
  attr :stats, :map, required: true

  def system_stats(assigns) do
    # Calculate overall system health
    assigns = assign(assigns, :health, calculate_health(assigns.stats, assigns.connection_status))

    ~H"""
    <div class="bg-white rounded-lg shadow-lg overflow-hidden">
      <div class="px-6 py-4 bg-gradient-to-r from-blue-500 to-blue-600">
        <h2 class="text-xl font-bold text-white flex items-center gap-2">
          <.icon name="hero-chart-bar" class="size-6" /> System Statistics
        </h2>
      </div>

      <div class="p-6">
        <!-- Overall Health Banner -->
        <div class={[
          "mb-6 p-4 rounded-lg text-center font-semibold",
          health_banner_class(@health)
        ]}>
          <div class="flex items-center justify-center gap-2">
            <.icon name={health_icon(@health)} class="size-6" />
            <span>{health_text(@health)}</span>
          </div>
        </div>
        
    <!-- Stats Grid -->
        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
          <!-- Connection Status -->
          <div class="bg-gray-50 rounded-lg p-4 hover:shadow-md transition-shadow">
            <div class="flex items-center gap-2 mb-2">
              <.icon name="hero-wifi" class={"size-5 #{connection_icon_class(@connection_status)}"} />
              <div class="text-sm font-medium text-gray-500">Connection</div>
            </div>
            <div class="text-lg font-bold text-gray-900">
              {connection_status_text(@connection_status, @connection_details)}
            </div>
            <div class="text-xs text-gray-500 mt-1">
              WebSocket Stream
            </div>
          </div>
          
    <!-- Message Rates -->
          <div class="bg-gray-50 rounded-lg p-4 hover:shadow-md transition-shadow">
            <div class="flex items-center gap-2 mb-2">
              <.icon name="hero-chat-bubble-left-right" class="size-5 text-blue-500" />
              <div class="text-sm font-medium text-gray-500">Message Rates</div>
            </div>
            <div class="space-y-1">
              <div class="flex justify-between items-center">
                <span class="text-xs text-gray-600">Quotes:</span>
                <span class="text-sm font-bold text-gray-900">{@stats.quotes_per_sec}/sec</span>
              </div>
              <div class="flex justify-between items-center">
                <span class="text-xs text-gray-600">Bars:</span>
                <span class="text-sm font-bold text-gray-900">{@stats.bars_per_min}/min</span>
              </div>
              <%= if @stats[:trades_per_sec] && @stats.trades_per_sec > 0 do %>
                <div class="flex justify-between items-center">
                  <span class="text-xs text-gray-600">Trades:</span>
                  <span class="text-sm font-bold text-gray-900">{@stats.trades_per_sec}/sec</span>
                </div>
              <% end %>
            </div>
          </div>
          
    <!-- Database Health -->
          <div class="bg-gray-50 rounded-lg p-4 hover:shadow-md transition-shadow">
            <div class="flex items-center gap-2 mb-2">
              <.icon name="hero-circle-stack" class={"size-5 #{db_icon_class(@stats.db_healthy)}"} />
              <div class="text-sm font-medium text-gray-500">Database</div>
            </div>
            <div class={["text-lg font-bold", db_text_class(@stats.db_healthy)]}>
              {if @stats.db_healthy, do: "Healthy", else: "Error"}
            </div>
            <div class="text-xs text-gray-500 mt-1">
              TimescaleDB
            </div>
          </div>
          
    <!-- System Uptime -->
          <div class="bg-gray-50 rounded-lg p-4 hover:shadow-md transition-shadow">
            <div class="flex items-center gap-2 mb-2">
              <.icon name="hero-clock" class="size-5 text-purple-500" />
              <div class="text-sm font-medium text-gray-500">Uptime</div>
            </div>
            <div class="text-lg font-bold text-gray-900">
              {format_uptime(@stats.uptime_seconds)}
            </div>
            <div class="text-xs text-gray-500 mt-1">
              {uptime_status_text(@stats.uptime_seconds)}
            </div>
          </div>
        </div>
        
    <!-- Last Message Timestamps -->
        <%= if @stats[:last_quote] || @stats[:last_bar] do %>
          <div class="mt-6 pt-6 border-t border-gray-200">
            <div class="flex items-center gap-2 mb-3">
              <.icon name="hero-arrow-path" class="size-4 text-gray-400" />
              <h3 class="text-sm font-medium text-gray-500">Last Updates</h3>
            </div>
            <div class="grid grid-cols-2 gap-4">
              <%= if @stats[:last_quote] do %>
                <div>
                  <div class="text-xs text-gray-500">Last Quote</div>
                  <div class="text-sm font-medium text-gray-900">{time_ago(@stats.last_quote)}</div>
                </div>
              <% end %>
              <%= if @stats[:last_bar] do %>
                <div>
                  <div class="text-xs text-gray-500">Last Bar</div>
                  <div class="text-sm font-medium text-gray-900">{time_ago(@stats.last_bar)}</div>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>
        
    <!-- Market Status Indicator -->
        <div class="mt-4 pt-4 border-t border-gray-200">
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-2">
              <.icon
                name="hero-building-office-2"
                class={"size-4 #{if market_open?(), do: "text-green-500", else: "text-gray-400"}"}
              />
              <span class="text-sm font-medium text-gray-700">Market Status</span>
            </div>
            <span class={[
              "text-xs font-medium px-2 py-1 rounded-full",
              if(market_open?(), do: "bg-green-100 text-green-800", else: "bg-gray-100 text-gray-800")
            ]}>
              {if market_open?(), do: "Open", else: "Closed"}
            </span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Helper Functions

  defp calculate_health(stats, connection_status) do
    cond do
      # Critical: disconnected or database unhealthy
      connection_status == :disconnected -> :error
      not stats.db_healthy -> :error
      # Degraded: reconnecting or no messages during market hours
      connection_status == :reconnecting -> :degraded
      stats.quotes_per_sec == 0 and market_open?() -> :degraded
      stats.bars_per_min == 0 and market_open?() -> :degraded
      # Healthy: all systems operational
      true -> :healthy
    end
  end

  defp market_open? do
    market_open_time = Application.get_env(:signal, :market_open, ~T[09:30:00])
    market_close_time = Application.get_env(:signal, :market_close, ~T[16:00:00])
    timezone = Application.get_env(:signal, :timezone, "America/New_York")

    try do
      # Get current time in market timezone
      now = DateTime.now!(timezone)
      current_time = DateTime.to_time(now)
      current_date = DateTime.to_date(now)
      day_of_week = Date.day_of_week(current_date)

      # Check if weekday (Monday=1 to Friday=5)
      is_weekday = day_of_week >= 1 and day_of_week <= 5

      # Check if within market hours
      is_market_hours =
        Time.compare(current_time, market_open_time) != :lt and
          Time.compare(current_time, market_close_time) != :gt

      is_weekday and is_market_hours
    rescue
      # If timezone calculation fails, default to false
      _ -> false
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

  defp health_banner_class(:healthy), do: "bg-green-100 text-green-800"
  defp health_banner_class(:degraded), do: "bg-yellow-100 text-yellow-800"
  defp health_banner_class(:error), do: "bg-red-100 text-red-800"

  defp health_icon(:healthy), do: "hero-check-circle"
  defp health_icon(:degraded), do: "hero-exclamation-triangle"
  defp health_icon(:error), do: "hero-x-circle"

  defp health_text(:healthy), do: "All Systems Operational"
  defp health_text(:degraded), do: "Degraded Performance"
  defp health_text(:error), do: "System Error Detected"

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

  defp db_text_class(true), do: "text-green-600"
  defp db_text_class(false), do: "text-red-600"
end
