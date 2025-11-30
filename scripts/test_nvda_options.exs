# Test NVDA Options Trading - January 2025
#
# Run with: mix run scripts/test_nvda_options.exs
#
# This script runs an options backtest on NVDA for January 2025,
# comparing options vs equity performance.

alias Signal.Backtest.Coordinator
alias Signal.Instruments.Config
alias Signal.Analytics.OptionsMetrics
alias Signal.Analytics.OptionsReport
alias Signal.Optimization.OptionsParams

IO.puts("""
════════════════════════════════════════════════════════════════════
NVDA Options Trading Backtest - January 2025
════════════════════════════════════════════════════════════════════
""")

# Configuration
symbol = "NVDA"
start_date = ~D[2025-01-02]
end_date = ~D[2025-02-28]
initial_capital = Decimal.new("100000")
risk_per_trade = Decimal.new("0.01")

IO.puts("Configuration:")
IO.puts("  Symbol: #{symbol}")
IO.puts("  Date Range: #{start_date} to #{end_date}")
IO.puts("  Initial Capital: $#{initial_capital}")
IO.puts("  Risk Per Trade: #{Decimal.mult(risk_per_trade, 100)}%")
IO.puts("")

# ─────────────────────────────────────────────────────────────────
# Run Equity Backtest
# ─────────────────────────────────────────────────────────────────
IO.puts("Running EQUITY backtest...")

equity_config = %{
  symbols: [symbol],
  start_date: start_date,
  end_date: end_date,
  strategies: [:break_and_retest],
  initial_capital: initial_capital,
  risk_per_trade: risk_per_trade,
  parameters: %{
    instrument_type: :equity
  },
  speed: :instant
}

equity_result = case Coordinator.run(equity_config) do
  {:ok, result} ->
    IO.puts("  ✓ Equity backtest complete")
    result
  {:error, reason} ->
    IO.puts("  ✗ Equity backtest failed: #{inspect(reason)}")
    nil
end

# ─────────────────────────────────────────────────────────────────
# Run Options Backtest - Weekly ATM
# ─────────────────────────────────────────────────────────────────
IO.puts("Running OPTIONS backtest (Weekly, ATM)...")

options_weekly_config = %{
  symbols: [symbol],
  start_date: start_date,
  end_date: end_date,
  strategies: [:break_and_retest],
  initial_capital: initial_capital,
  risk_per_trade: risk_per_trade,
  parameters: %{
    instrument_type: :options,
    expiration_preference: :weekly,
    strike_selection: :atm,
    slippage_pct: Decimal.new("0.01")
  },
  speed: :instant
}

options_weekly_result = case Coordinator.run(options_weekly_config) do
  {:ok, result} ->
    IO.puts("  ✓ Options (weekly) backtest complete")
    result
  {:error, reason} ->
    IO.puts("  ✗ Options (weekly) backtest failed: #{inspect(reason)}")
    nil
end

# ─────────────────────────────────────────────────────────────────
# Run Options Backtest - Weekly 1 OTM
# ─────────────────────────────────────────────────────────────────
IO.puts("Running OPTIONS backtest (Weekly, 1 OTM)...")

options_otm_config = %{
  symbols: [symbol],
  start_date: start_date,
  end_date: end_date,
  strategies: [:break_and_retest],
  initial_capital: initial_capital,
  risk_per_trade: risk_per_trade,
  parameters: %{
    instrument_type: :options,
    expiration_preference: :weekly,
    strike_selection: :one_otm,
    slippage_pct: Decimal.new("0.01")
  },
  speed: :instant
}

options_otm_result = case Coordinator.run(options_otm_config) do
  {:ok, result} ->
    IO.puts("  ✓ Options (1 OTM) backtest complete")
    result
  {:error, reason} ->
    IO.puts("  ✗ Options (1 OTM) backtest failed: #{inspect(reason)}")
    nil
end

IO.puts("")

# ─────────────────────────────────────────────────────────────────
# Display Results
# ─────────────────────────────────────────────────────────────────
IO.puts("""
════════════════════════════════════════════════════════════════════
RESULTS SUMMARY
════════════════════════════════════════════════════════════════════
""")

defmodule ResultPrinter do
  def print_result(nil, _name), do: IO.puts("  No results available\n")

  def print_result(result, name) do
    trades = result.closed_trades || []
    analytics = result.analytics

    IO.puts("#{name}:")
    IO.puts("─────────────────────────────────────────────────────────────────")

    if Enum.empty?(trades) do
      IO.puts("  No trades executed")
    else
      trade_metrics = analytics && analytics.trade_metrics

      if trade_metrics do
        IO.puts("  Total Trades:    #{trade_metrics.total_trades}")
        IO.puts("  Winners:         #{trade_metrics.winners}")
        IO.puts("  Losers:          #{trade_metrics.losers}")
        IO.puts("  Win Rate:        #{format_decimal(trade_metrics.win_rate)}%")
        IO.puts("  Net Profit:      $#{format_decimal(trade_metrics.net_profit)}")
        IO.puts("  Profit Factor:   #{format_decimal(trade_metrics.profit_factor) || "N/A"}")
        IO.puts("  Avg R-Multiple:  #{format_decimal(trade_metrics.avg_r_multiple) || "N/A"}R")
        IO.puts("  Expectancy:      $#{format_decimal(trade_metrics.expectancy)}/trade")
      else
        IO.puts("  Trades: #{length(trades)}")
        total_pnl = trades |> Enum.map(&(&1.pnl || Decimal.new(0))) |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
        IO.puts("  Total P&L: $#{format_decimal(total_pnl)}")
      end
    end

    IO.puts("")
  end

  def format_decimal(nil), do: nil
  def format_decimal(%Decimal{} = d), do: d |> Decimal.round(2) |> Decimal.to_string()
  def format_decimal(other), do: to_string(other)
end

ResultPrinter.print_result(equity_result, "EQUITY")
ResultPrinter.print_result(options_weekly_result, "OPTIONS (Weekly, ATM)")
ResultPrinter.print_result(options_otm_result, "OPTIONS (Weekly, 1 OTM)")

# ─────────────────────────────────────────────────────────────────
# Options vs Equity Comparison
# ─────────────────────────────────────────────────────────────────
if equity_result && options_weekly_result do
  equity_trades = equity_result.closed_trades || []
  options_trades = options_weekly_result.closed_trades || []

  # Tag trades with instrument type for analysis
  options_trades_tagged = Enum.map(options_trades, fn trade ->
    Map.put(trade, :instrument_type, "options")
  end)

  if length(equity_trades) > 0 || length(options_trades_tagged) > 0 do
    IO.puts("""
════════════════════════════════════════════════════════════════════
OPTIONS VS EQUITY COMPARISON
════════════════════════════════════════════════════════════════════
""")

    case OptionsReport.comparison_report(equity_trades, options_trades_tagged) do
      {:ok, report} ->
        IO.puts(OptionsReport.to_text(report))
      {:error, reason} ->
        IO.puts("Could not generate comparison report: #{inspect(reason)}")
    end
  end
end

# ─────────────────────────────────────────────────────────────────
# Options Configuration Breakdown
# ─────────────────────────────────────────────────────────────────
if options_weekly_result do
  options_trades = options_weekly_result.closed_trades || []
  options_trades_tagged = Enum.map(options_trades, fn trade ->
    Map.put(trade, :instrument_type, "options")
  end)

  if length(options_trades_tagged) > 0 do
    IO.puts("""
════════════════════════════════════════════════════════════════════
OPTIONS METRICS BREAKDOWN
════════════════════════════════════════════════════════════════════
""")

    case OptionsMetrics.calculate(options_trades_tagged) do
      {:ok, metrics} ->
        IO.puts("Premium Statistics:")
        IO.puts("  Avg Entry Premium:  $#{ResultPrinter.format_decimal(metrics.avg_entry_premium) || "N/A"}")
        IO.puts("  Avg Exit Premium:   $#{ResultPrinter.format_decimal(metrics.avg_exit_premium) || "N/A"}")
        IO.puts("  Premium Capture:    #{ResultPrinter.format_decimal(metrics.avg_premium_capture_multiple) || "N/A"}x")
        IO.puts("  Total Contracts:    #{metrics.total_contracts}")
        IO.puts("")

        if map_size(metrics.by_exit_reason) > 0 do
          IO.puts("By Exit Reason:")
          Enum.each(metrics.by_exit_reason, fn {reason, stats} ->
            IO.puts("  #{reason}: #{stats.count} trades, #{ResultPrinter.format_decimal(stats.win_rate)}% win rate")
          end)
          IO.puts("")
        end

        if map_size(metrics.by_contract_type) > 0 do
          IO.puts("By Contract Type:")
          Enum.each(metrics.by_contract_type, fn {type, stats} ->
            IO.puts("  #{type}: #{stats.count} trades, #{ResultPrinter.format_decimal(stats.win_rate)}% win rate, $#{ResultPrinter.format_decimal(stats.total_pnl)} P&L")
          end)
        end

      {:error, reason} ->
        IO.puts("Could not calculate options metrics: #{inspect(reason)}")
    end
  end
end

IO.puts("""

════════════════════════════════════════════════════════════════════
Test Complete
════════════════════════════════════════════════════════════════════
""")
