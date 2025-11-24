defmodule Signal.Technicals.Inspector do
  @moduledoc """
  Interactive testing and inspection helper for technical analysis modules.

  Use this module in IEx to quickly test and visualize the output of the
  Levels, Swings, and StructureDetector modules.

  ## Usage

      # In IEx
      iex> alias Signal.Technicals.Inspector
      iex> Inspector.inspect_symbol(:AAPL, days: 5)
      iex> Inspector.inspect_swings(:AAPL, days: 2)
      iex> Inspector.inspect_structure(:AAPL, days: 3)
      iex> Inspector.inspect_levels(:AAPL, ~D[2024-11-23])
  """

  import Ecto.Query
  alias Signal.Repo
  alias Signal.MarketData.Bar
  alias Signal.Technicals.{Levels, Swings, StructureDetector}

  @doc """
  Comprehensive inspection of all technical analysis for a symbol.

  ## Options

    * `:days` - Number of days to analyze (default: 5)
    * `:date` - Specific date to analyze (default: today)

  ## Example

      iex> Inspector.inspect_symbol(:AAPL, days: 5)
  """
  def inspect_symbol(symbol, opts \\ []) do
    days = Keyword.get(opts, :days, 5)
    date = Keyword.get(opts, :date, Date.utc_today())

    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("Technical Analysis for #{symbol}")
    IO.puts(String.duplicate("=", 80))

    # Get bars
    bars = get_recent_bars(symbol, days)

    IO.puts("\n📊 Data Range: #{length(bars)} bars over #{days} days")

    if Enum.empty?(bars) do
      IO.puts("\n⚠️  No bar data found. Load historical data first:")
      IO.puts("    mix signal.load_data --symbols #{symbol} --year 2024")
    else
      first = List.first(bars)
      last = List.last(bars)

      IO.puts("   From: #{format_datetime(first.bar_time)}")
      IO.puts("   To:   #{format_datetime(last.bar_time)}")
      IO.puts("   Price Range: $#{first.low} - $#{last.high}")

      # Inspect each component
      inspect_levels_section(symbol, date)
      inspect_swings_section(bars)
      inspect_structure_section(bars)
      show_ascii_chart(bars)
    end

    IO.puts("\n" <> String.duplicate("=", 80))
    :ok
  end

  @doc """
  Inspect swing detection for a symbol.

  ## Example

      iex> Inspector.inspect_swings(:AAPL, days: 2, lookback: 2)
  """
  def inspect_swings(symbol, opts \\ []) do
    days = Keyword.get(opts, :days, 2)
    lookback = Keyword.get(opts, :lookback, 2)

    bars = get_recent_bars(symbol, days)

    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("Swing Analysis for #{symbol} (lookback: #{lookback})")
    IO.puts(String.duplicate("=", 60))

    swings = Swings.identify_swings(bars, lookback: lookback)

    IO.puts("\n📍 Found #{length(swings)} swing points:")

    swings
    |> Enum.each(fn swing ->
      type_emoji = if swing.type == :high, do: "🔺", else: "🔻"
      type_label = if swing.type == :high, do: "HIGH", else: "LOW "

      IO.puts(
        "   #{type_emoji} #{type_label} at index #{String.pad_leading(to_string(swing.index), 3)} | " <>
          "$#{swing.price} | #{format_datetime(swing.bar_time)}"
      )
    end)

    # Show latest of each type
    latest_high = Swings.get_latest_swing(bars, :high)
    latest_low = Swings.get_latest_swing(bars, :low)

    IO.puts("\n📌 Latest Swings:")

    if latest_high do
      IO.puts(
        "   🔺 Last Swing High: $#{latest_high.price} at #{format_datetime(latest_high.bar_time)}"
      )
    end

    if latest_low do
      IO.puts(
        "   🔻 Last Swing Low:  $#{latest_low.price} at #{format_datetime(latest_low.bar_time)}"
      )
    end

    IO.puts(String.duplicate("=", 60))
    swings
  end

  @doc """
  Inspect market structure for a symbol.

  ## Example

      iex> Inspector.inspect_structure(:AAPL, days: 3)
  """
  def inspect_structure(symbol, opts \\ []) do
    days = Keyword.get(opts, :days, 3)
    lookback = Keyword.get(opts, :lookback, 2)

    bars = get_recent_bars(symbol, days)

    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("Market Structure Analysis for #{symbol}")
    IO.puts(String.duplicate("=", 60))

    structure = StructureDetector.analyze(bars, lookback: lookback)

    # Trend
    trend_emoji =
      case structure.trend do
        :bullish -> "📈"
        :bearish -> "📉"
        :ranging -> "↔️ "
      end

    IO.puts("\n#{trend_emoji} Trend: #{String.upcase(to_string(structure.trend))}")

    # Structure state
    state = StructureDetector.get_structure_state(structure)

    state_emoji =
      case state do
        :strong_bullish -> "💪📈"
        :weak_bullish -> "😐📈"
        :strong_bearish -> "💪📉"
        :weak_bearish -> "😐📉"
        :ranging -> "↔️ "
      end

    IO.puts("#{state_emoji} Structure State: #{format_state(state)}")

    # Swing summary
    IO.puts("\n📊 Swings:")
    IO.puts("   🔺 Swing Highs: #{length(structure.swing_highs)}")
    IO.puts("   🔻 Swing Lows:  #{length(structure.swing_lows)}")

    # BOS
    if structure.latest_bos do
      bos = structure.latest_bos
      bos_emoji = if bos.type == :bullish, do: "🟢", else: "🔴"

      IO.puts("\n#{bos_emoji} Latest BOS (#{bos.type}):")
      IO.puts("   Price: $#{bos.price}")
      IO.puts("   Time:  #{format_datetime(bos.bar_time)}")
      IO.puts("   Broke: $#{bos.broken_swing.price} swing #{bos.broken_swing.type}")
    else
      IO.puts("\n⚪ No BOS detected")
    end

    # ChoCh
    if structure.latest_choch do
      choch = structure.latest_choch
      choch_emoji = if choch.type == :bullish, do: "🔄🟢", else: "🔄🔴"

      IO.puts("\n#{choch_emoji} Latest ChoCh (#{choch.type} - reversal signal):")
      IO.puts("   Price: $#{choch.price}")
      IO.puts("   Time:  #{format_datetime(choch.bar_time)}")
      IO.puts("   Broke: $#{choch.broken_swing.price} swing #{choch.broken_swing.type}")
    else
      IO.puts("\n⚪ No ChoCh detected")
    end

    IO.puts(String.duplicate("=", 60))
    structure
  end

  @doc """
  Inspect key levels for a symbol on a specific date.

  ## Example

      iex> Inspector.inspect_levels(:AAPL, ~D[2024-11-23])
  """
  def inspect_levels(symbol, date \\ Date.utc_today()) do
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("Key Levels for #{symbol} on #{date}")
    IO.puts(String.duplicate("=", 60))

    case Levels.get_current_levels(symbol) do
      {:ok, levels} ->
        IO.puts("\n📊 Daily Reference Levels:")
        IO.puts("   Previous Day High (PDH): $#{levels.previous_day_high}")
        IO.puts("   Previous Day Low  (PDL): $#{levels.previous_day_low}")

        if levels.premarket_high do
          IO.puts("\n🌅 Premarket Levels:")
          IO.puts("   Premarket High (PMH): $#{levels.premarket_high}")
          IO.puts("   Premarket Low  (PML): $#{levels.premarket_low}")
        end

        if levels.opening_range_5m_high do
          IO.puts("\n⏱️  Opening Range (5min):")
          IO.puts("   OR5 High: $#{levels.opening_range_5m_high}")
          IO.puts("   OR5 Low:  $#{levels.opening_range_5m_low}")
        end

        if levels.opening_range_15m_high do
          IO.puts("\n⏱️  Opening Range (15min):")
          IO.puts("   OR15 High: $#{levels.opening_range_15m_high}")
          IO.puts("   OR15 Low:  $#{levels.opening_range_15m_low}")
        end

        # Try to get current price and show position
        case get_latest_price(symbol) do
          {:ok, price} ->
            case Levels.get_level_status(symbol, price) do
              {:ok, {position, level_name, level_value}} ->
                position_text =
                  case position do
                    :above -> "ABOVE ⬆️"
                    :below -> "BELOW ⬇️"
                    :at -> "AT ━"
                  end

                IO.puts("\n💰 Current Price: $#{price}")
                IO.puts("   Position: #{position_text} #{level_name} ($#{level_value})")

              _ ->
                IO.puts("\n💰 Current Price: $#{price}")
            end

          _ ->
            :ok
        end

        # Psychological levels
        if price = get_latest_price(symbol) do
          case price do
            {:ok, p} ->
              psych = Levels.find_nearest_psychological(p)
              IO.puts("\n🎯 Nearest Psychological Levels:")
              IO.puts("   Whole:   $#{psych.whole}")
              IO.puts("   Half:    $#{psych.half}")
              IO.puts("   Quarter: $#{psych.quarter}")

            _ ->
              :ok
          end
        end

      {:error, :not_found} ->
        IO.puts("\n⚠️  No levels calculated for this date.")
        IO.puts("   Calculate with: Levels.calculate_daily_levels(:#{symbol}, ~D[#{date}])")
    end

    IO.puts(String.duplicate("=", 60))
    :ok
  end

  @doc """
  Show an ASCII chart of recent price action with swings marked.

  ## Example

      iex> Inspector.show_chart(:AAPL, days: 2)
  """
  def show_chart(symbol, opts \\ []) do
    days = Keyword.get(opts, :days, 2)
    bars = get_recent_bars(symbol, days)
    show_ascii_chart(bars)
  end

  # Private Functions

  defp get_recent_bars(symbol, days) do
    cutoff = DateTime.add(DateTime.utc_now(), -days * 24 * 60 * 60, :second)

    query =
      from b in Bar,
        where: b.symbol == ^to_string(symbol),
        where: b.bar_time >= ^cutoff,
        order_by: [asc: b.bar_time],
        limit: 1000

    Repo.all(query)
  end

  defp get_latest_price(symbol) do
    query =
      from b in Bar,
        where: b.symbol == ^to_string(symbol),
        order_by: [desc: b.bar_time],
        limit: 1

    case Repo.one(query) do
      nil -> {:error, :not_found}
      bar -> {:ok, bar.close}
    end
  end

  defp inspect_levels_section(symbol, date) do
    IO.puts("\n" <> String.duplicate("-", 80))
    IO.puts("📊 KEY LEVELS")
    IO.puts(String.duplicate("-", 80))

    case Levels.get_current_levels(symbol) do
      {:ok, levels} ->
        IO.puts("   PDH: $#{levels.previous_day_high}  |  PDL: $#{levels.previous_day_low}")

        if levels.premarket_high do
          IO.puts("   PMH: $#{levels.premarket_high}  |  PML: $#{levels.premarket_low}")
        end

        if levels.opening_range_5m_high do
          IO.puts("   OR5: $#{levels.opening_range_5m_high} - $#{levels.opening_range_5m_low}")
        end

      {:error, :not_found} ->
        IO.puts("   ⚠️  No levels found. Calculate with:")
        IO.puts("      Levels.calculate_daily_levels(:#{symbol}, ~D[#{date}])")
    end
  end

  defp inspect_swings_section(bars) do
    IO.puts("\n" <> String.duplicate("-", 80))
    IO.puts("📍 SWING ANALYSIS")
    IO.puts(String.duplicate("-", 80))

    swings = Swings.identify_swings(bars, lookback: 2)

    IO.puts("   Total Swings: #{length(swings)}")

    swing_highs = Enum.filter(swings, &(&1.type == :high))
    swing_lows = Enum.filter(swings, &(&1.type == :low))

    IO.puts("   Swing Highs: #{length(swing_highs)}")
    IO.puts("   Swing Lows:  #{length(swing_lows)}")

    if latest_high = List.last(swing_highs) do
      IO.puts("   Latest High: $#{latest_high.price} at #{format_time(latest_high.bar_time)}")
    end

    if latest_low = List.last(swing_lows) do
      IO.puts("   Latest Low:  $#{latest_low.price} at #{format_time(latest_low.bar_time)}")
    end
  end

  defp inspect_structure_section(bars) do
    IO.puts("\n" <> String.duplicate("-", 80))
    IO.puts("🏗️  MARKET STRUCTURE")
    IO.puts(String.duplicate("-", 80))

    structure = StructureDetector.analyze(bars)

    trend_icon =
      case structure.trend do
        :bullish -> "📈 BULLISH"
        :bearish -> "📉 BEARISH"
        :ranging -> "↔️  RANGING"
      end

    IO.puts("   Trend: #{trend_icon}")

    state = StructureDetector.get_structure_state(structure)
    IO.puts("   State: #{format_state(state)}")

    if structure.latest_bos do
      bos = structure.latest_bos
      IO.puts("   BOS:   #{String.upcase(to_string(bos.type))} at $#{bos.price}")
    end

    if structure.latest_choch do
      choch = structure.latest_choch
      IO.puts("   ChoCh: #{String.upcase(to_string(choch.type))} at $#{choch.price}")
    end
  end

  defp show_ascii_chart(bars) when length(bars) > 0 do
    IO.puts("\n" <> String.duplicate("-", 80))
    IO.puts("📈 PRICE CHART (Last #{min(length(bars), 50)} bars)")
    IO.puts(String.duplicate("-", 80))

    # Take last 50 bars for chart
    chart_bars = Enum.take(bars, -50)

    # Get price range
    all_highs = Enum.map(chart_bars, & &1.high)
    all_lows = Enum.map(chart_bars, & &1.low)

    max_price = Enum.max(all_highs)
    min_price = Enum.min(all_lows)
    price_range = Decimal.sub(max_price, min_price)

    # Identify swings
    swings = Swings.identify_swings(chart_bars, lookback: 2)
    swing_indices = Enum.map(swings, & &1.index) |> MapSet.new()

    # Chart dimensions
    chart_height = 15
    chart_width = min(length(chart_bars), 50)

    # Draw chart
    Enum.each((chart_height - 1)..0, fn row ->
      # Calculate price level for this row
      price_at_row =
        Decimal.add(
          min_price,
          Decimal.mult(
            price_range,
            Decimal.div(Decimal.new(row), Decimal.new(chart_height - 1))
          )
        )

      # Draw price axis
      price_label = "$#{Decimal.round(price_at_row, 2)}"
      IO.write(String.pad_leading(price_label, 8) <> " │")

      # Draw bars
      Enum.with_index(chart_bars, fn bar, idx ->
        char =
          cond do
            # Bar's range includes this price level
            Decimal.compare(bar.high, price_at_row) != :lt and
                Decimal.compare(bar.low, price_at_row) != :gt ->
              cond do
                MapSet.member?(swing_indices, idx) -> "●"
                Decimal.compare(bar.close, bar.open) == :gt -> "▪"
                Decimal.compare(bar.close, bar.open) == :lt -> "▫"
                true -> "─"
              end

            true ->
              " "
          end

        IO.write(char)
      end)

      IO.puts("")
    end)

    # Time axis
    IO.write("         └" <> String.duplicate("─", chart_width))
    IO.puts("")

    # Show first and last time
    first_time = format_time(List.first(chart_bars).bar_time)
    last_time = format_time(List.last(chart_bars).bar_time)

    IO.puts("          #{first_time}" <> String.duplicate(" ", chart_width - 25) <> last_time)

    IO.puts("\n   Legend: ● Swing Point  ▪ Green Bar  ▫ Red Bar")
    IO.puts(String.duplicate("-", 80))
  end

  defp show_ascii_chart(_), do: :ok

  defp format_datetime(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S")
  end

  defp format_time(datetime) do
    Calendar.strftime(datetime, "%H:%M")
  end

  defp format_state(state) do
    case state do
      :strong_bullish -> "💪 STRONG BULLISH"
      :weak_bullish -> "😐 WEAK BULLISH"
      :strong_bearish -> "💪 STRONG BEARISH"
      :weak_bearish -> "😐 WEAK BEARISH"
      :ranging -> "↔️  RANGING"
    end
  end
end
