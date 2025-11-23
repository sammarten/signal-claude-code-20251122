#!/usr/bin/env elixir

# Data Verification Script
# Usage: mix run scripts/verify_data.exs [SYMBOL]
# Example: mix run scripts/verify_data.exs AAPL

IO.puts("\n" <> String.duplicate("=", 70))
IO.puts("Market Data Verification Report")
IO.puts(String.duplicate("=", 70) <> "\n")

alias Signal.MarketData.Verifier
alias Signal.Repo

# Color helpers
defmodule Colors do
  def green(text), do: IO.ANSI.green() <> text <> IO.ANSI.reset()
  def red(text), do: IO.ANSI.red() <> text <> IO.ANSI.reset()
  def yellow(text), do: IO.ANSI.yellow() <> text <> IO.ANSI.reset()
  def blue(text), do: IO.ANSI.blue() <> text <> IO.ANSI.reset()
  def cyan(text), do: IO.ANSI.cyan() <> text <> IO.ANSI.reset()
  def bold(text), do: IO.ANSI.bright() <> text <> IO.ANSI.reset()
end

defmodule ReportFormatter do
  def format_number(num) when num >= 1_000_000 do
    "#{Float.round(num / 1_000_000, 1)}M"
  end

  def format_number(num) when num >= 1_000 do
    "#{Float.round(num / 1_000, 1)}K"
  end

  def format_number(num), do: "#{num}"

  def severity_icon(:critical), do: Colors.red("✗")
  def severity_icon(:high), do: Colors.red("⚠")
  def severity_icon(:medium), do: Colors.yellow("⚠")
  def severity_icon(:low), do: Colors.yellow("•")
  def severity_icon(_), do: "•"

  def issue_type_name(:ohlc_violation), do: "OHLC Violations"
  def issue_type_name(:gaps), do: "Data Gaps"
  def issue_type_name(:duplicate_bars), do: "Duplicate Bars"
  def issue_type_name(type), do: "#{type}"

  def print_symbol_report(report) do
    IO.puts(Colors.bold("\n#{report.symbol}"))
    IO.puts(String.duplicate("-", 70))

    # Statistics
    IO.puts("#{Colors.cyan("Bars:")} #{format_number(report.total_bars)}")

    if report.total_bars > 0 do
      {start_date, end_date} = report.date_range
      IO.puts("#{Colors.cyan("Date Range:")} #{start_date} to #{end_date}")

      if report.statistics.trading_days > 0 do
        IO.puts("#{Colors.cyan("Trading Days:")} #{report.statistics.trading_days}")
        avg_bars_per_day = div(report.total_bars, report.statistics.trading_days)
        IO.puts("#{Colors.cyan("Avg Bars/Day:")} #{avg_bars_per_day} (expect ~390 for 1-min bars)")
      end

      if report.statistics.avg_volume > 0 do
        avg_vol = report.statistics.avg_volume
        |> Decimal.to_integer()
        |> format_number()
        IO.puts("#{Colors.cyan("Avg Volume:")} #{avg_vol}")
      end

      # Issues
      IO.puts("\n#{Colors.cyan("Quality Checks:")}")

      if Enum.empty?(report.issues) do
        IO.puts("  #{Colors.green("✓")} No data quality issues found!")
      else
        Enum.each(report.issues, fn issue ->
          icon = severity_icon(issue.severity)
          name = issue_type_name(issue.type)
          IO.puts("  #{icon} #{name}: #{issue.count} instance(s)")

          # Print examples for critical issues
          if issue.severity in [:critical, :high] and Map.has_key?(issue, :examples) do
            examples = Enum.take(issue.examples, 3)
            Enum.each(examples, fn example ->
              IO.puts("    → #{inspect(example)}")
            end)
            if issue.count > 3 do
              IO.puts("    → ... and #{issue.count - 3} more")
            end
          end

          # Print largest gap
          if issue.type == :gaps and Map.has_key?(issue, :largest) do
            gap = issue.largest
            IO.puts("    → Largest gap: #{gap.missing_minutes} minutes at #{gap.start}")
          end
        end)
      end

      # Overall health
      IO.puts("\n#{Colors.cyan("Overall Health:")}")
      health_status = calculate_health(report)
      case health_status do
        :excellent ->
          IO.puts("  #{Colors.green("✓ EXCELLENT")} - Data quality is high")
        :good ->
          IO.puts("  #{Colors.green("✓ GOOD")} - Minor issues found")
        :fair ->
          IO.puts("  #{Colors.yellow("⚠ FAIR")} - Some quality issues present")
        :poor ->
          IO.puts("  #{Colors.red("✗ POOR")} - Significant quality issues")
      end
    else
      IO.puts(Colors.yellow("  No data available for this symbol"))
    end
  end

  defp calculate_health(report) do
    critical_issues = Enum.count(report.issues, fn i -> i.severity == :critical end)
    high_issues = Enum.count(report.issues, fn i -> i.severity == :high end)
    total_issues = length(report.issues)

    cond do
      critical_issues > 0 -> :poor
      high_issues > 0 -> :fair
      total_issues > 2 -> :fair
      total_issues > 0 -> :good
      true -> :excellent
    end
  end
end

# Get symbols to verify
symbols = case System.argv() do
  [] ->
    # No arguments - verify all configured symbols
    Application.get_env(:signal, :symbols, [])

  args ->
    # Verify specified symbols
    Enum.map(args, &String.upcase/1)
end

if Enum.empty?(symbols) do
  IO.puts(Colors.red("Error: No symbols to verify"))
  IO.puts("Usage: mix run scripts/verify_data.exs [SYMBOL1 SYMBOL2 ...]")
  IO.puts("Example: mix run scripts/verify_data.exs AAPL TSLA")
  System.halt(1)
end

IO.puts("#{Colors.cyan("Verifying:")} #{Enum.join(symbols, ", ")}")
IO.puts("")

# Verify each symbol
results = Enum.map(symbols, fn symbol ->
  case Verifier.verify_symbol(symbol) do
    {:ok, report} ->
      ReportFormatter.print_symbol_report(report)
      {symbol, :ok, report}

    {:error, reason} ->
      IO.puts(Colors.red("Error verifying #{symbol}: #{inspect(reason)}"))
      {symbol, :error, nil}
  end
end)

# Summary
IO.puts("\n" <> String.duplicate("=", 70))
IO.puts(Colors.bold("Summary"))
IO.puts(String.duplicate("=", 70))

total_bars = results
  |> Enum.filter(fn {_, status, _} -> status == :ok end)
  |> Enum.map(fn {_, _, report} -> report.total_bars end)
  |> Enum.sum()

verified_count = Enum.count(results, fn {_, status, _} -> status == :ok end)
error_count = Enum.count(results, fn {_, status, _} -> status == :error end)

IO.puts("#{Colors.cyan("Symbols Verified:")} #{verified_count}/#{length(symbols)}")
if error_count > 0 do
  IO.puts("#{Colors.red("Errors:")} #{error_count}")
end
IO.puts("#{Colors.cyan("Total Bars:")} #{ReportFormatter.format_number(total_bars)}")

# Health summary
excellent = results
  |> Enum.filter(fn {_, status, report} ->
    status == :ok and report != nil and Enum.empty?(report.issues)
  end)
  |> length()

issues_found = results
  |> Enum.filter(fn {_, status, report} ->
    status == :ok and report != nil and not Enum.empty?(report.issues)
  end)
  |> length()

IO.puts("\n#{Colors.cyan("Health Summary:")}")
IO.puts("  #{Colors.green("✓")} Excellent: #{excellent} symbol(s)")
if issues_found > 0 do
  IO.puts("  #{Colors.yellow("⚠")} With Issues: #{issues_found} symbol(s)")
end

IO.puts("\n#{Colors.cyan("Recommendations:")}")

if total_bars == 0 do
  IO.puts("  • No data loaded. Run: mix signal.load_data --year 2024")
elsif issues_found > 0 do
  IO.puts("  • Review data quality issues above")
  IO.puts("  • Consider re-loading data for symbols with critical issues")
else
  IO.puts("  #{Colors.green("• All symbols have excellent data quality!")}")
end

IO.puts("")
