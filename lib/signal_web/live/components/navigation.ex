defmodule SignalWeb.Live.Components.Navigation do
  @moduledoc """
  Shared navigation component for the Signal application.

  Provides consistent header navigation across all LiveView pages with:
  - App branding
  - Navigation links with active state
  - Connection status badge (when applicable)
  """

  use Phoenix.Component
  import SignalWeb.CoreComponents

  @nav_items [
    %{path: "/", label: "Market", icon: "hero-chart-bar"},
    %{path: "/signals", label: "Signals", icon: "hero-bolt"},
    %{path: "/backtest", label: "Backtest", icon: "hero-play"},
    %{path: "/optimization", label: "Optimize", icon: "hero-adjustments-horizontal"},
    %{path: "/reports", label: "Reports", icon: "hero-document-chart-bar"},
    %{path: "/data/coverage", label: "Data", icon: "hero-server-stack"}
  ]

  attr :current_path, :string, required: true
  attr :page_title, :string, required: true
  attr :page_subtitle, :string, default: nil
  attr :page_icon_color, :string, default: "from-green-500 to-emerald-600"
  attr :connection_status, :atom, default: nil
  attr :connection_details, :map, default: %{}

  @doc """
  Renders the main header with navigation.
  """
  def header(assigns) do
    assigns = assign(assigns, :nav_items, @nav_items)

    ~H"""
    <div class="bg-gradient-to-r from-zinc-900 via-zinc-800 to-zinc-900 border-b border-zinc-800">
      <div class="max-w-[1920px] mx-auto px-4 sm:px-6 lg:px-8 py-6">
        <div class="flex items-center justify-between">
          <div class="flex items-center gap-4">
            <div class={"bg-gradient-to-br #{@page_icon_color} p-2 rounded-lg shadow-lg shadow-green-500/20"}>
              <.page_icon current_path={@current_path} />
            </div>
            <div>
              <h1 class="text-3xl font-bold text-white tracking-tight">{@page_title}</h1>
              <p :if={@page_subtitle} class="text-zinc-400 text-sm">{@page_subtitle}</p>
            </div>
          </div>
          
    <!-- Navigation -->
          <div class="flex items-center gap-2">
            <%= for item <- @nav_items do %>
              <.nav_link
                path={item.path}
                label={item.label}
                icon={item.icon}
                active={@current_path == item.path}
              />
            <% end %>
          </div>
          
    <!-- Connection Status Badge (if provided) -->
          <div
            :if={@connection_status}
            class={[
              "px-5 py-2.5 rounded-xl text-sm font-semibold backdrop-blur-sm transition-all duration-300 shadow-lg",
              connection_badge_class(@connection_status)
            ]}
          >
            <div class="flex items-center gap-2.5">
              <div class={[
                "w-2.5 h-2.5 rounded-full animate-pulse",
                if(@connection_status == :connected,
                  do: "bg-green-400 shadow-lg shadow-green-400/50",
                  else: "bg-red-400 shadow-lg shadow-red-400/50"
                )
              ]} />
              {connection_status_text(@connection_status, @connection_details)}
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :path, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :active, :boolean, default: false

  defp nav_link(assigns) do
    ~H"""
    <%= if @active do %>
      <span class="px-4 py-2 text-sm font-medium text-white bg-zinc-800 rounded-lg">
        <.icon name={@icon} class="w-4 h-4 inline mr-1" />
        {@label}
      </span>
    <% else %>
      <.link
        navigate={@path}
        class="px-4 py-2 text-sm font-medium text-zinc-400 hover:text-white transition-colors"
      >
        <.icon name={@icon} class="w-4 h-4 inline mr-1" />
        {@label}
      </.link>
    <% end %>
    """
  end

  defp page_icon(%{current_path: "/"} = assigns) do
    ~H"""
    <svg class="w-8 h-8 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M13 7h8m0 0v8m0-8l-8 8-4-4-6 6"
      />
    </svg>
    """
  end

  defp page_icon(%{current_path: "/signals"} = assigns) do
    ~H"""
    <.icon name="hero-bolt" class="w-8 h-8 text-white" />
    """
  end

  defp page_icon(%{current_path: "/backtest"} = assigns) do
    ~H"""
    <.icon name="hero-play" class="w-8 h-8 text-white" />
    """
  end

  defp page_icon(%{current_path: "/optimization"} = assigns) do
    ~H"""
    <.icon name="hero-adjustments-horizontal" class="w-8 h-8 text-white" />
    """
  end

  defp page_icon(%{current_path: "/reports"} = assigns) do
    ~H"""
    <.icon name="hero-document-chart-bar" class="w-8 h-8 text-white" />
    """
  end

  defp page_icon(%{current_path: "/data/coverage"} = assigns) do
    ~H"""
    <.icon name="hero-server-stack" class="w-8 h-8 text-white" />
    """
  end

  defp page_icon(assigns) do
    ~H"""
    <.icon name="hero-chart-bar" class="w-8 h-8 text-white" />
    """
  end

  defp connection_badge_class(status) do
    case status do
      :connected -> "bg-green-500/10 text-green-400 border border-green-500/20"
      :disconnected -> "bg-red-500/10 text-red-400 border border-red-500/20"
      :reconnecting -> "bg-yellow-500/10 text-yellow-400 border border-yellow-500/20"
      _ -> "bg-zinc-800/50 text-zinc-400 border border-zinc-700"
    end
  end

  defp connection_status_text(status, details) do
    case status do
      :connected -> "Connected"
      :disconnected -> "Disconnected"
      :reconnecting -> "Reconnecting (attempt #{Map.get(details, :attempt, 0)})"
      _ -> "Unknown"
    end
  end
end
