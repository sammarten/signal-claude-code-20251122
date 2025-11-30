defmodule Signal.Analytics.OptionsReport do
  @moduledoc """
  Generates comparison reports between options and equity trading performance.

  Provides side-by-side analysis of the same signals executed as both equity
  trades and options trades, allowing traders to evaluate the effectiveness
  of options vs equity strategies.

  ## Report Types

  - **Comparison Report**: Side-by-side equity vs options metrics
  - **Configuration Report**: Breakdown by options configuration (weekly vs 0DTE, strike)
  - **Premium Efficiency Report**: Analysis of premium capture and decay
  - **Risk-Adjusted Report**: Compare risk-adjusted returns (Sharpe, Sortino, etc.)

  ## Usage

      # Compare equity and options performance
      {:ok, report} = OptionsReport.comparison_report(equity_trades, options_trades)

      # Get configuration breakdown
      {:ok, config_report} = OptionsReport.configuration_report(options_trades)
  """

  alias Signal.Analytics.TradeMetrics
  alias Signal.Analytics.OptionsMetrics

  @zero Decimal.new(0)

  @doc """
  Generates a side-by-side comparison of equity vs options performance.

  ## Parameters

    * `equity_trades` - List of equity trade maps
    * `options_trades` - List of options trade maps (should be on same signals)

  ## Returns

    * `{:ok, report}` - Comparison report map
    * `{:error, reason}` - Generation failed
  """
  @spec comparison_report(list(map()), list(map())) :: {:ok, map()} | {:error, term()}
  def comparison_report(equity_trades, options_trades) do
    with {:ok, equity_metrics} <- TradeMetrics.calculate(equity_trades),
         {:ok, options_metrics} <- OptionsMetrics.calculate(options_trades) do
      report = %{
        equity: summarize_equity_metrics(equity_metrics),
        options: summarize_options_metrics(options_metrics),
        comparison: build_comparison(equity_metrics, options_metrics),
        recommendation: generate_recommendation(equity_metrics, options_metrics)
      }

      {:ok, report}
    end
  end

  @doc """
  Generates a breakdown report by options configuration.

  Analyzes performance by:
  - Expiration type (0DTE, weekly, monthly)
  - Strike selection (ATM, 1 OTM, 2 OTM)
  - Contract type (call, put)

  ## Parameters

    * `options_trades` - List of options trade maps

  ## Returns

    * `{:ok, report}` - Configuration breakdown report
  """
  @spec configuration_report(list(map())) :: {:ok, map()} | {:error, term()}
  def configuration_report(options_trades) do
    with {:ok, metrics} <- OptionsMetrics.calculate(options_trades) do
      report = %{
        by_expiration_type: format_breakdown(metrics.by_expiration_type),
        by_strike_distance: format_breakdown(metrics.by_strike_distance),
        by_contract_type: format_breakdown(metrics.by_contract_type),
        by_exit_reason: format_breakdown(metrics.by_exit_reason),
        best_configuration: find_best_configuration(metrics),
        worst_configuration: find_worst_configuration(metrics)
      }

      {:ok, report}
    end
  end

  @doc """
  Generates a formatted text report comparing equity and options performance.
  """
  @spec to_text(map()) :: String.t()
  def to_text(%{equity: equity, options: options, comparison: comparison, recommendation: rec}) do
    """
    ══════════════════════════════════════════════════════════════════
    OPTIONS VS EQUITY COMPARISON REPORT
    ══════════════════════════════════════════════════════════════════

    SUMMARY METRICS
    ─────────────────────────────────────────────────────────────────
                          EQUITY              OPTIONS
    Total Trades:         #{pad_left(equity.total_trades, 8)}          #{pad_left(options.total_trades, 8)}
    Win Rate:             #{pad_left(format_pct(equity.win_rate), 8)}          #{pad_left(format_pct(options.win_rate), 8)}
    Profit Factor:        #{pad_left(format_decimal(equity.profit_factor), 8)}          #{pad_left(format_decimal(options.profit_factor), 8)}
    Net Profit:           #{pad_left(format_currency(equity.net_profit), 8)}         #{pad_left(format_currency(options.net_profit), 8)}
    Avg R-Multiple:       #{pad_left(format_r(equity.avg_r), 8)}          #{pad_left(format_r(options.avg_r), 8)}
    Expectancy:           #{pad_left(format_currency(equity.expectancy), 8)}          #{pad_left(format_currency(options.expectancy), 8)}

    COMPARISON
    ─────────────────────────────────────────────────────────────────
    Return Advantage:     #{comparison.return_advantage}
    Win Rate Advantage:   #{comparison.win_rate_advantage}
    Risk/Reward:          #{comparison.risk_reward_comparison}
    Capital Efficiency:   #{comparison.capital_efficiency}

    OPTIONS-SPECIFIC
    ─────────────────────────────────────────────────────────────────
    Total Contracts:      #{options.total_contracts}
    Avg Entry Premium:    #{format_currency(options.avg_entry_premium)}
    Avg Exit Premium:     #{format_currency(options.avg_exit_premium)}
    Premium Capture:      #{format_decimal(options.avg_premium_capture_multiple)}x

    RECOMMENDATION
    ─────────────────────────────────────────────────────────────────
    #{rec}

    ══════════════════════════════════════════════════════════════════
    """
  end

  @doc """
  Generates a formatted configuration breakdown report.
  """
  @spec configuration_to_text(map()) :: String.t()
  def configuration_to_text(report) do
    """
    ══════════════════════════════════════════════════════════════════
    OPTIONS CONFIGURATION BREAKDOWN
    ══════════════════════════════════════════════════════════════════

    BY EXPIRATION TYPE
    ─────────────────────────────────────────────────────────────────
    #{format_breakdown_section(report.by_expiration_type)}

    BY STRIKE DISTANCE
    ─────────────────────────────────────────────────────────────────
    #{format_breakdown_section(report.by_strike_distance)}

    BY CONTRACT TYPE
    ─────────────────────────────────────────────────────────────────
    #{format_breakdown_section(report.by_contract_type)}

    BY EXIT REASON
    ─────────────────────────────────────────────────────────────────
    #{format_breakdown_section(report.by_exit_reason)}

    RECOMMENDATIONS
    ─────────────────────────────────────────────────────────────────
    Best Configuration:  #{format_config(report.best_configuration)}
    Worst Configuration: #{format_config(report.worst_configuration)}

    ══════════════════════════════════════════════════════════════════
    """
  end

  # Private Functions

  defp summarize_equity_metrics(metrics) do
    %{
      total_trades: metrics.total_trades,
      win_rate: metrics.win_rate,
      profit_factor: metrics.profit_factor,
      net_profit: metrics.net_profit,
      avg_r: metrics.avg_r_multiple,
      expectancy: metrics.expectancy,
      gross_profit: metrics.gross_profit,
      gross_loss: metrics.gross_loss
    }
  end

  defp summarize_options_metrics(%OptionsMetrics{} = metrics) do
    base = metrics.base_metrics

    %{
      total_trades: base.total_trades,
      win_rate: base.win_rate,
      profit_factor: base.profit_factor,
      net_profit: base.net_profit,
      avg_r: base.avg_r_multiple,
      expectancy: base.expectancy,
      gross_profit: base.gross_profit,
      gross_loss: base.gross_loss,
      total_contracts: metrics.total_contracts,
      avg_entry_premium: metrics.avg_entry_premium,
      avg_exit_premium: metrics.avg_exit_premium,
      avg_premium_capture_multiple: metrics.avg_premium_capture_multiple
    }
  end

  defp build_comparison(equity_metrics, options_metrics) do
    options_base = options_metrics.base_metrics

    # Calculate return advantage
    equity_return = equity_metrics.net_profit || @zero
    options_return = options_base.net_profit || @zero

    return_diff = Decimal.sub(options_return, equity_return)

    return_advantage =
      cond do
        Decimal.compare(return_diff, @zero) == :gt ->
          "Options +$#{format_decimal(return_diff)}"

        Decimal.compare(return_diff, @zero) == :lt ->
          "Equity +$#{format_decimal(Decimal.abs(return_diff))}"

        true ->
          "Equal"
      end

    # Win rate comparison
    equity_wr = equity_metrics.win_rate || @zero
    options_wr = options_base.win_rate || @zero
    wr_diff = Decimal.sub(options_wr, equity_wr)

    win_rate_advantage =
      cond do
        Decimal.compare(wr_diff, @zero) == :gt ->
          "Options +#{format_decimal(wr_diff)}%"

        Decimal.compare(wr_diff, @zero) == :lt ->
          "Equity +#{format_decimal(Decimal.abs(wr_diff))}%"

        true ->
          "Equal"
      end

    # Risk/Reward (using profit factor as proxy)
    equity_pf = equity_metrics.profit_factor
    options_pf = options_base.profit_factor

    risk_reward_comparison =
      cond do
        is_nil(equity_pf) and is_nil(options_pf) ->
          "Insufficient data"

        is_nil(equity_pf) ->
          "Options only (#{format_decimal(options_pf)})"

        is_nil(options_pf) ->
          "Equity only (#{format_decimal(equity_pf)})"

        Decimal.compare(options_pf, equity_pf) == :gt ->
          "Options better (#{format_decimal(options_pf)} vs #{format_decimal(equity_pf)})"

        Decimal.compare(options_pf, equity_pf) == :lt ->
          "Equity better (#{format_decimal(equity_pf)} vs #{format_decimal(options_pf)})"

        true ->
          "Equal (#{format_decimal(equity_pf)})"
      end

    # Capital efficiency (return per dollar deployed)
    # For options, the entry premium * contracts * 100 is the capital deployed
    capital_efficiency =
      if options_metrics.avg_premium_capture_multiple do
        multiple = options_metrics.avg_premium_capture_multiple

        cond do
          Decimal.compare(multiple, Decimal.new("1.5")) == :gt ->
            "High (#{format_decimal(multiple)}x premium capture)"

          Decimal.compare(multiple, Decimal.new("1.0")) == :gt ->
            "Moderate (#{format_decimal(multiple)}x premium capture)"

          true ->
            "Low (#{format_decimal(multiple)}x premium capture)"
        end
      else
        "Insufficient data"
      end

    %{
      return_advantage: return_advantage,
      win_rate_advantage: win_rate_advantage,
      risk_reward_comparison: risk_reward_comparison,
      capital_efficiency: capital_efficiency
    }
  end

  defp generate_recommendation(equity_metrics, options_metrics) do
    options_base = options_metrics.base_metrics

    equity_pf = equity_metrics.profit_factor || @zero
    options_pf = options_base.profit_factor || @zero
    equity_wr = equity_metrics.win_rate || @zero
    options_wr = options_base.win_rate || @zero

    conditions = [
      # Options has better profit factor
      Decimal.compare(options_pf, equity_pf) == :gt,
      # Options has better win rate
      Decimal.compare(options_wr, equity_wr) == :gt,
      # Options has positive net profit
      Decimal.compare(options_base.net_profit || @zero, @zero) == :gt
    ]

    positives = Enum.count(conditions, & &1)

    cond do
      positives >= 3 ->
        "STRONG: Options strategy outperforms equity on key metrics. Consider options for capital efficiency."

      positives == 2 ->
        "MODERATE: Options show promise. Consider A/B testing with live trading."

      positives == 1 ->
        "MIXED: Results inconclusive. Equity may be simpler with similar returns."

      true ->
        "CAUTION: Equity strategy performs better. Options may not be optimal for this signal type."
    end
  end

  defp format_breakdown(breakdown_map) when is_map(breakdown_map) do
    breakdown_map
    |> Enum.map(fn {key, metrics} ->
      {key,
       %{
         count: metrics.count,
         win_rate: format_decimal(metrics.win_rate),
         avg_r: format_decimal(metrics.avg_r),
         total_pnl: format_decimal(metrics.total_pnl),
         avg_pnl: format_decimal(metrics.avg_pnl)
       }}
    end)
    |> Map.new()
  end

  defp find_best_configuration(metrics) do
    all_configs = [
      {:expiration, metrics.by_expiration_type},
      {:strike, metrics.by_strike_distance},
      {:contract_type, metrics.by_contract_type}
    ]

    best =
      all_configs
      |> Enum.flat_map(fn {category, breakdown} ->
        breakdown
        |> Enum.filter(fn {_key, m} -> m.count >= 3 end)
        |> Enum.map(fn {key, m} ->
          score = calculate_config_score(m)
          {category, key, score, m}
        end)
      end)
      |> Enum.max_by(fn {_, _, score, _} -> Decimal.to_float(score) end, fn -> nil end)

    case best do
      nil -> %{category: nil, value: nil, metrics: nil}
      {category, key, _score, m} -> %{category: category, value: key, metrics: m}
    end
  end

  defp find_worst_configuration(metrics) do
    all_configs = [
      {:expiration, metrics.by_expiration_type},
      {:strike, metrics.by_strike_distance},
      {:contract_type, metrics.by_contract_type}
    ]

    worst =
      all_configs
      |> Enum.flat_map(fn {category, breakdown} ->
        breakdown
        |> Enum.filter(fn {_key, m} -> m.count >= 3 end)
        |> Enum.map(fn {key, m} ->
          score = calculate_config_score(m)
          {category, key, score, m}
        end)
      end)
      |> Enum.min_by(fn {_, _, score, _} -> Decimal.to_float(score) end, fn -> nil end)

    case worst do
      nil -> %{category: nil, value: nil, metrics: nil}
      {category, key, _score, m} -> %{category: category, value: key, metrics: m}
    end
  end

  defp calculate_config_score(metrics) do
    # Score = win_rate * 0.4 + (avg_r * 20) * 0.6
    # This weights both win rate and R-multiple
    win_rate = metrics.win_rate || @zero
    avg_r = metrics.avg_r || @zero

    wr_component = Decimal.mult(win_rate, Decimal.new("0.4"))
    r_component = Decimal.mult(Decimal.mult(avg_r, Decimal.new("20")), Decimal.new("0.6"))

    Decimal.add(wr_component, r_component)
  end

  defp format_breakdown_section(breakdown) when is_map(breakdown) do
    breakdown
    |> Enum.sort_by(fn {_, m} -> -parse_count(m.count) end)
    |> Enum.map(fn {key, m} ->
      "#{pad_right(String.upcase(to_string(key)), 15)} " <>
        "Count: #{pad_left(m.count, 4)} | " <>
        "Win: #{pad_left(m.win_rate, 6)}% | " <>
        "Avg R: #{pad_left(m.avg_r || "N/A", 6)} | " <>
        "P&L: #{pad_left(m.total_pnl, 10)}"
    end)
    |> Enum.join("\n")
  end

  defp parse_count(count) when is_integer(count), do: count
  defp parse_count(count) when is_binary(count), do: String.to_integer(count)
  defp parse_count(_), do: 0

  defp format_config(%{category: nil}), do: "Insufficient data"

  defp format_config(%{category: category, value: value, metrics: m}) do
    "#{category}=#{value} (Win: #{format_decimal(m.win_rate)}%, R: #{format_decimal(m.avg_r)})"
  end

  # Formatting helpers

  defp format_decimal(nil), do: "N/A"

  defp format_decimal(%Decimal{} = d) do
    d |> Decimal.round(2) |> Decimal.to_string()
  end

  defp format_decimal(other), do: to_string(other)

  defp format_pct(nil), do: "N/A"

  defp format_pct(%Decimal{} = d) do
    "#{format_decimal(d)}%"
  end

  defp format_currency(nil), do: "N/A"

  defp format_currency(%Decimal{} = d) do
    "$#{format_decimal(d)}"
  end

  defp format_r(nil), do: "N/A"

  defp format_r(%Decimal{} = d) do
    "#{format_decimal(d)}R"
  end

  defp pad_left(value, width) do
    str = to_string(value)
    String.pad_leading(str, width)
  end

  defp pad_right(value, width) do
    str = to_string(value)
    String.pad_trailing(str, width)
  end
end
