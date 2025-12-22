defmodule SignalWeb.PreviewLive do
  use SignalWeb, :live_view

  alias SignalWeb.Live.Components.Navigation
  alias SignalWeb.Live.Components.PreviewComponents
  alias Signal.Preview.Generator

  @moduledoc """
  Daily Market Preview page displaying market regime, scenarios, and watchlist.

  Generates and displays the daily market preview including:
  - Market regime (trending, ranging, breakout pending)
  - Index divergence (SPY/QQQ/DIA comparison)
  - Key levels and scenarios for SPY and QQQ
  - Watchlist with high conviction, monitoring, and avoid categories
  - Game plan with stance, position size, and risk notes

  Supports viewing historical previews via URL parameter:
  - /preview - Today's preview
  - /preview?date=2024-12-15 - Preview for specific date
  """

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(today: Date.utc_today())
      # Expansion states for progressive disclosure
      |> assign(regime_expanded: false)
      |> assign(divergence_expanded: false)
      |> assign(rs_expanded: false)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    date = parse_date_param(params["date"])

    socket =
      socket
      |> assign(date: date)
      |> cancel_existing_async()
      |> start_async_loading(date)

    {:noreply, socket}
  end

  # Cancel any existing async operations when date changes
  defp cancel_existing_async(socket) do
    socket
    |> cancel_async(:preview_data)
  end

  # Start async loading for all preview data in parallel
  defp start_async_loading(socket, date) do
    if connected?(socket) do
      assign_async(socket, :preview_data, fn ->
        {:ok, preview} = Generator.generate_parallel(date: date)
        {:ok, %{preview_data: preview}}
      end)
    else
      # Pre-render state: show loading
      assign(socket, :preview_data, %Phoenix.LiveView.AsyncResult{
        ok?: false,
        loading: true,
        failed: nil,
        result: nil
      })
    end
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    socket =
      socket
      |> cancel_existing_async()
      |> start_async_loading(socket.assigns.date)

    {:noreply, socket}
  end

  def handle_event("prev_day", _params, socket) do
    new_date = Date.add(socket.assigns.date, -1)
    {:noreply, push_patch(socket, to: date_path(new_date))}
  end

  def handle_event("next_day", _params, socket) do
    new_date = Date.add(socket.assigns.date, 1)
    {:noreply, push_patch(socket, to: date_path(new_date))}
  end

  def handle_event("today", _params, socket) do
    {:noreply, push_patch(socket, to: "/preview")}
  end

  def handle_event("change_date", %{"date" => date_string}, socket) do
    case Date.from_iso8601(date_string) do
      {:ok, date} ->
        {:noreply, push_patch(socket, to: date_path(date))}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_regime_details", _params, socket) do
    {:noreply, assign(socket, regime_expanded: !socket.assigns.regime_expanded)}
  end

  def handle_event("toggle_divergence_chart", _params, socket) do
    {:noreply, assign(socket, divergence_expanded: !socket.assigns.divergence_expanded)}
  end

  def handle_event("toggle_rs_rankings", _params, socket) do
    {:noreply, assign(socket, rs_expanded: !socket.assigns.rs_expanded)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-zinc-950">
      <Navigation.header
        current_path="/preview"
        page_title="Daily Preview"
        page_subtitle={format_date(@date)}
        page_icon_color="from-amber-500 to-orange-600"
      />

      <div class="max-w-[1920px] mx-auto px-4 sm:px-6 lg:px-8 py-6">
        <!-- Date Navigation -->
        <.date_navigator date={@date} today={@today} />

        <.async_result :let={data} assign={@preview_data}>
          <:loading>
            <.loading_state />
          </:loading>
          <:failed :let={_reason}>
            <.error_state error={:generation_failed} />
          </:failed>
          <.preview_content
            preview={data}
            regime_expanded={@regime_expanded}
            divergence_expanded={@divergence_expanded}
            rs_expanded={@rs_expanded}
          />
        </.async_result>
      </div>
    </div>
    """
  end

  defp date_navigator(assigns) do
    ~H"""
    <div class="flex items-center justify-between mb-6 bg-zinc-900/50 backdrop-blur-sm rounded-xl border border-zinc-800 p-4">
      <div class="flex items-center gap-2">
        <!-- Previous Day -->
        <button
          phx-click="prev_day"
          class="p-2 bg-zinc-800 hover:bg-zinc-700 text-zinc-300 rounded-lg transition-colors"
          title="Previous day"
        >
          <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7" />
          </svg>
        </button>
        
    <!-- Date Picker -->
        <div class="relative">
          <input
            type="date"
            value={Date.to_iso8601(@date)}
            max={Date.to_iso8601(@today)}
            phx-change="change_date"
            name="date"
            class="bg-zinc-800 border border-zinc-700 text-white rounded-lg px-4 py-2 focus:ring-2 focus:ring-amber-500 focus:border-transparent cursor-pointer"
          />
        </div>
        
    <!-- Next Day -->
        <button
          phx-click="next_day"
          disabled={@date >= @today}
          class={[
            "p-2 rounded-lg transition-colors",
            if(@date >= @today,
              do: "bg-zinc-800/50 text-zinc-600 cursor-not-allowed",
              else: "bg-zinc-800 hover:bg-zinc-700 text-zinc-300"
            )
          ]}
          title="Next day"
        >
          <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5l7 7-7 7" />
          </svg>
        </button>
      </div>

      <div class="flex items-center gap-3">
        <!-- Today Button -->
        <button
          :if={@date != @today}
          phx-click="today"
          class="px-4 py-2 bg-amber-600 hover:bg-amber-500 text-white rounded-lg transition-colors text-sm font-medium"
        >
          Today
        </button>
        
    <!-- Date Display -->
        <div class="text-zinc-400 text-sm hidden sm:block">
          {format_relative_date(@date, @today)}
        </div>
      </div>
    </div>
    """
  end

  defp loading_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center py-24">
      <div class="animate-spin rounded-full h-12 w-12 border-b-2 border-amber-500 mb-4"></div>
      <p class="text-zinc-400 text-lg">Generating market preview...</p>
      <p class="text-zinc-500 text-sm mt-2">Analyzing market regime, levels, and relative strength</p>
    </div>
    """
  end

  defp error_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center py-24">
      <div class="bg-red-500/10 border border-red-500/20 rounded-2xl p-8 max-w-md text-center">
        <div class="text-red-400 text-5xl mb-4">!</div>
        <h3 class="text-white text-lg font-semibold mb-2">Unable to generate preview</h3>
        <p class="text-zinc-400 text-sm mb-4">
          {error_message(@error)}
        </p>
        <button
          phx-click="refresh"
          class="px-4 py-2 bg-zinc-800 hover:bg-zinc-700 text-white rounded-lg transition-colors"
        >
          Try Again
        </button>
      </div>
    </div>
    """
  end

  defp error_message(:insufficient_data),
    do: "Not enough historical data available. Please ensure market data is loaded."

  defp error_message(error) when is_atom(error), do: "Error: #{error}"
  defp error_message(error), do: "Error: #{inspect(error)}"

  defp preview_content(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Header with refresh button -->
      <div class="flex items-center justify-between">
        <div>
          <p class="text-zinc-400 text-sm">
            Generated {format_time(@preview.generated_at)}
          </p>
        </div>
        <button
          phx-click="refresh"
          class="flex items-center gap-2 px-4 py-2 bg-zinc-800 hover:bg-zinc-700 text-zinc-300 rounded-lg transition-colors"
        >
          <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"
            />
          </svg>
          Refresh
        </button>
      </div>
      
    <!-- Market Context with expandable regime details -->
      <PreviewComponents.market_context
        context={@preview.market_context}
        volatility={@preview.expected_volatility}
        regime={@preview.spy_regime}
        expanded={@regime_expanded}
      />
      
    <!-- Two column layout for divergence and game plan -->
      <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <PreviewComponents.index_divergence
          divergence={@preview.index_divergence}
          history={@preview.divergence_history}
          expanded={@divergence_expanded}
        />
        <PreviewComponents.game_plan
          stance={@preview.stance}
          position_size={@preview.position_size}
          focus={@preview.focus}
          risk_notes={@preview.risk_notes}
        />
      </div>
      
    <!-- SPY and QQQ sections -->
      <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <PreviewComponents.index_section
          symbol="SPY"
          regime={@preview.spy_regime}
          scenarios={@preview.spy_scenarios}
        />
        <PreviewComponents.index_section
          symbol="QQQ"
          regime={@preview.qqq_regime}
          scenarios={@preview.qqq_scenarios}
        />
      </div>
      
    <!-- Watchlist -->
      <PreviewComponents.watchlist
        high_conviction={@preview.high_conviction}
        monitoring={@preview.monitoring}
        avoid={@preview.avoid}
      />
      
    <!-- Sector notes with expandable full RS rankings -->
      <PreviewComponents.sector_notes
        leaders={@preview.relative_strength_leaders}
        laggards={@preview.relative_strength_laggards}
        full_rankings={@preview.full_rs_rankings}
        expanded={@rs_expanded}
      />
    </div>
    """
  end

  # Helper Functions

  defp parse_date_param(nil), do: Date.utc_today()

  defp parse_date_param(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} -> date
      {:error, _} -> Date.utc_today()
    end
  end

  defp date_path(date) do
    today = Date.utc_today()

    if date == today do
      "/preview"
    else
      "/preview?date=#{Date.to_iso8601(date)}"
    end
  end

  defp format_date(date) do
    Calendar.strftime(date, "%A, %B %d, %Y")
  end

  defp format_relative_date(date, today) do
    diff = Date.diff(date, today)

    cond do
      diff == 0 -> "Today"
      diff == -1 -> "Yesterday"
      diff == 1 -> "Tomorrow"
      diff < 0 -> "#{abs(diff)} days ago"
      true -> "In #{diff} days"
    end
  end

  defp format_time(datetime) do
    datetime
    |> DateTime.shift_zone!("America/New_York")
    |> Calendar.strftime("%I:%M %p ET")
  end
end
