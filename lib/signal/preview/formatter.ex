defmodule Signal.Preview.Formatter do
  @moduledoc """
  Formats DailyPreview into readable output formats.

  Supported formats:
  - Markdown (terminal-friendly)
  - JSON (for API/storage)

  ## Usage

      preview = %DailyPreview{...}
      markdown = Formatter.to_markdown(preview)
      json = Formatter.to_json(preview)
  """

  alias Signal.Preview.{DailyPreview, MarketRegime, IndexDivergence, Scenario, WatchlistItem}

  @line_width 66
  @double_line String.duplicate("═", @line_width)
  @single_line String.duplicate("─", @line_width)

  @doc """
  Formats a DailyPreview as markdown text.

  Returns a string suitable for terminal output or markdown files.
  """
  @spec to_markdown(DailyPreview.t()) :: String.t()
  def to_markdown(%DailyPreview{} = preview) do
    [
      header(preview),
      market_context(preview),
      index_divergence(preview),
      spy_section(preview),
      qqq_section(preview),
      watchlist_section(preview),
      sector_notes(preview),
      game_plan(preview),
      footer()
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  @doc """
  Formats a DailyPreview as JSON.
  """
  @spec to_json(DailyPreview.t()) :: String.t()
  def to_json(%DailyPreview{} = preview) do
    preview
    |> preview_to_map()
    |> Jason.encode!(pretty: true)
  end

  # Private Functions - Markdown Sections

  defp header(%DailyPreview{date: date, generated_at: generated_at}) do
    date_str = Calendar.strftime(date, "%A, %B %d, %Y")
    time_str = format_time_et(generated_at)

    """
    #{@double_line}
    DAILY MARKET PREVIEW - #{date_str}
    Generated: #{time_str} ET
    #{@double_line}
    """
  end

  defp market_context(%DailyPreview{} = preview) do
    regime_text = format_regime(preview.spy_regime)
    volatility = format_volatility(preview.expected_volatility)

    """
    OVERNIGHT SUMMARY
    #{@single_line}
    #{preview.market_context || "No context available"}

    MARKET REGIME: #{regime_text}
    Expected Volatility: #{volatility}
    """
  end

  defp index_divergence(%DailyPreview{index_divergence: nil}), do: nil

  defp index_divergence(%DailyPreview{index_divergence: div}) do
    """
    INDEX DIVERGENCE
    #{@single_line}
            5D Perf    From ATH    Status
    SPY     #{pad(format_pct(div.spy_5d_pct), 10)}#{pad(format_pct(div.spy_from_ath_pct), 12)}#{format_status(div.spy_status)}
    QQQ     #{pad(format_pct(div.qqq_5d_pct), 10)}#{pad(format_pct(div.qqq_from_ath_pct), 12)}#{format_status(div.qqq_status)}
    DIA     #{pad(format_pct(div.dia_5d_pct), 10)}#{pad(format_pct(div.dia_from_ath_pct), 12)}#{format_status(div.dia_status)}

    #{warning_icon(div)} #{div.implication}
    """
  end

  defp spy_section(%DailyPreview{spy_regime: nil}), do: nil

  defp spy_section(%DailyPreview{spy_regime: regime, spy_scenarios: scenarios}) do
    levels_text = format_regime_levels(regime)
    scenarios_text = format_scenarios(scenarios)

    """
    SPY KEY LEVELS
    #{@single_line}
    #{levels_text}

    SCENARIOS
    #{@single_line}
    #{scenarios_text}
    """
  end

  defp qqq_section(%DailyPreview{qqq_regime: nil}), do: nil

  defp qqq_section(%DailyPreview{qqq_regime: regime, qqq_scenarios: scenarios}) do
    levels_text = format_regime_levels(regime)
    scenarios_text = format_scenarios(scenarios)

    """
    QQQ KEY LEVELS
    #{@single_line}
    #{levels_text}

    SCENARIOS
    #{@single_line}
    #{scenarios_text}
    """
  end

  defp watchlist_section(%DailyPreview{} = preview) do
    high = format_watchlist_items(preview.high_conviction, "HIGH CONVICTION")
    monitoring = format_watchlist_items(preview.monitoring, "MONITORING")
    avoid = format_watchlist_items(preview.avoid, "AVOID/CAUTIOUS")

    """
    WATCHLIST
    #{@single_line}
    #{high}
    #{monitoring}
    #{avoid}
    """
  end

  defp sector_notes(%DailyPreview{} = preview) do
    leaders = Enum.join(preview.relative_strength_leaders, ", ")
    laggards = Enum.join(preview.relative_strength_laggards, ", ")

    """
    SECTOR NOTES
    #{@single_line}
    Relative Strength:  #{if leaders == "", do: "N/A", else: leaders}
    Relative Weakness:  #{if laggards == "", do: "N/A", else: laggards}
    """
  end

  defp game_plan(%DailyPreview{} = preview) do
    stance = format_stance(preview.stance)
    size = format_size(preview.position_size)
    risk_notes = format_risk_notes(preview.risk_notes)

    """
    GAME PLAN
    #{@single_line}
    Stance: #{stance}
    Size:   #{size}
    Focus:  #{preview.focus || "Standard playbook"}

    Risk Notes:
    #{risk_notes}
    """
  end

  defp footer do
    @double_line
  end

  # Private Functions - Formatting Helpers

  defp format_regime(nil), do: "UNKNOWN"

  defp format_regime(%MarketRegime{regime: regime, range_duration_days: days}) do
    base =
      regime
      |> Atom.to_string()
      |> String.upcase()
      |> String.replace("_", " ")

    if regime == :ranging and days do
      "#{base} (Day #{days})"
    else
      base
    end
  end

  defp format_volatility(:high), do: "HIGH"
  defp format_volatility(:normal), do: "NORMAL"
  defp format_volatility(:low), do: "LOW"
  defp format_volatility(_), do: "NORMAL"

  defp format_pct(nil), do: "N/A"

  defp format_pct(decimal) do
    value = Decimal.to_float(decimal)
    sign = if value >= 0, do: "+", else: ""
    "#{sign}#{:erlang.float_to_binary(value, decimals: 1)}%"
  end

  defp format_status(:leading), do: "LEADING"
  defp format_status(:lagging), do: "LAGGING"
  defp format_status(:neutral), do: "NEUTRAL"
  defp format_status(_), do: "N/A"

  defp warning_icon(%IndexDivergence{qqq_status: :lagging}), do: "⚠️"
  defp warning_icon(_), do: " "

  defp format_regime_levels(nil), do: "No levels available"

  defp format_regime_levels(%MarketRegime{} = regime) do
    lines =
      [
        {"Resistance", regime.range_high},
        {"Support", regime.range_low}
      ]
      |> Enum.map(fn {label, value} ->
        "#{pad(label <> ":", 13)}#{format_price(value)}"
      end)
      |> Enum.join("\n")

    if regime.distance_from_ath_percent do
      ath_dist = format_pct(regime.distance_from_ath_percent)
      lines <> "\nFrom ATH:    #{ath_dist}"
    else
      lines
    end
  end

  defp format_scenarios([]), do: "No scenarios available"

  defp format_scenarios(scenarios) do
    scenarios
    |> Enum.map(fn %Scenario{type: type, description: desc} ->
      type_str = type |> Atom.to_string() |> String.upcase() |> pad(10)
      "#{type_str}#{desc}"
    end)
    |> Enum.join("\n")
  end

  defp format_watchlist_items([], label), do: "#{label}:\n  (none)"

  defp format_watchlist_items(items, label) do
    items_text =
      items
      |> Enum.take(5)
      |> Enum.map(fn %WatchlistItem{} = item ->
        level_text = if item.key_level, do: " #{format_price(item.key_level)}", else: ""
        bias_text = format_bias(item.bias)
        "  • #{item.symbol} - #{item.setup}#{level_text}, #{bias_text} bias"
      end)
      |> Enum.join("\n")

    "#{label}:\n#{items_text}"
  end

  defp format_bias(:long), do: "LONG"
  defp format_bias(:short), do: "SHORT"
  defp format_bias(:neutral), do: "NEUTRAL"
  defp format_bias(_), do: "N/A"

  defp format_stance(:aggressive), do: "AGGRESSIVE"
  defp format_stance(:normal), do: "NORMAL"
  defp format_stance(:cautious), do: "CAUTIOUS"
  defp format_stance(:hands_off), do: "HANDS OFF"
  defp format_stance(_), do: "NORMAL"

  defp format_size(:full), do: "FULL"
  defp format_size(:half), do: "HALF"
  defp format_size(:quarter), do: "QUARTER"
  defp format_size(_), do: "FULL"

  defp format_risk_notes([]), do: "  • No specific risk notes"

  defp format_risk_notes(notes) do
    notes
    |> Enum.map(&("  • " <> &1))
    |> Enum.join("\n")
  end

  defp format_price(nil), do: "N/A"

  defp format_price(decimal) do
    decimal
    |> Decimal.round(2)
    |> Decimal.to_string()
  end

  defp format_time_et(datetime) do
    datetime
    |> DateTime.shift_zone!("America/New_York")
    |> Calendar.strftime("%I:%M %p")
  end

  defp pad(str, width) do
    String.pad_trailing(str, width)
  end

  # JSON Conversion

  defp preview_to_map(%DailyPreview{} = preview) do
    %{
      date: Date.to_iso8601(preview.date),
      generated_at: DateTime.to_iso8601(preview.generated_at),
      market_context: preview.market_context,
      expected_volatility: preview.expected_volatility,
      index_divergence: divergence_to_map(preview.index_divergence),
      spy_regime: regime_to_map(preview.spy_regime),
      qqq_regime: regime_to_map(preview.qqq_regime),
      spy_scenarios: Enum.map(preview.spy_scenarios, &scenario_to_map/1),
      qqq_scenarios: Enum.map(preview.qqq_scenarios, &scenario_to_map/1),
      watchlist: %{
        high_conviction: Enum.map(preview.high_conviction, &watchlist_item_to_map/1),
        monitoring: Enum.map(preview.monitoring, &watchlist_item_to_map/1),
        avoid: Enum.map(preview.avoid, &watchlist_item_to_map/1)
      },
      relative_strength: %{
        leaders: preview.relative_strength_leaders,
        laggards: preview.relative_strength_laggards
      },
      game_plan: %{
        stance: preview.stance,
        position_size: preview.position_size,
        focus: preview.focus,
        risk_notes: preview.risk_notes
      }
    }
  end

  defp divergence_to_map(nil), do: nil

  defp divergence_to_map(%IndexDivergence{} = div) do
    %{
      spy: %{
        status: div.spy_status,
        perf_5d: decimal_to_float(div.spy_5d_pct),
        from_ath: decimal_to_float(div.spy_from_ath_pct)
      },
      qqq: %{
        status: div.qqq_status,
        perf_5d: decimal_to_float(div.qqq_5d_pct),
        from_ath: decimal_to_float(div.qqq_from_ath_pct)
      },
      dia: %{
        status: div.dia_status,
        perf_5d: decimal_to_float(div.dia_5d_pct),
        from_ath: decimal_to_float(div.dia_from_ath_pct)
      },
      leader: div.leader,
      laggard: div.laggard,
      implication: div.implication
    }
  end

  defp regime_to_map(nil), do: nil

  defp regime_to_map(%MarketRegime{} = regime) do
    %{
      regime: regime.regime,
      range_high: decimal_to_float(regime.range_high),
      range_low: decimal_to_float(regime.range_low),
      range_duration_days: regime.range_duration_days,
      distance_from_ath_percent: decimal_to_float(regime.distance_from_ath_percent),
      trend_direction: regime.trend_direction
    }
  end

  defp scenario_to_map(%Scenario{} = scenario) do
    %{
      type: scenario.type,
      trigger_level: decimal_to_float(scenario.trigger_level),
      trigger_condition: scenario.trigger_condition,
      target_level: decimal_to_float(scenario.target_level),
      description: scenario.description
    }
  end

  defp watchlist_item_to_map(%WatchlistItem{} = item) do
    %{
      symbol: item.symbol,
      setup: item.setup,
      key_level: decimal_to_float(item.key_level),
      bias: item.bias,
      conviction: item.conviction,
      notes: item.notes
    }
  end

  defp decimal_to_float(nil), do: nil
  defp decimal_to_float(decimal), do: Decimal.to_float(decimal)
end
