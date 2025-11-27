defmodule Mix.Tasks.Signal.ValidateData do
  @moduledoc """
  Mix task to validate historical data quality.

  Runs data quality checks on market bar data and generates a report
  with pass/fail/warn status based on configurable thresholds.

  ## Usage

      # Validate all configured symbols
      mix signal.validate_data

      # Validate specific symbols
      mix signal.validate_data --symbols AAPL,TSLA,NVDA

      # Auto-fix detected gaps (download missing data)
      mix signal.validate_data --fix-gaps

      # Show detailed report
      mix signal.validate_data --verbose

  ## Options

      --symbols AAPL,TSLA    Comma-separated list of symbols (default: all configured)
      --fix-gaps             Attempt to fill detected gaps via Alpaca API
      --verbose              Show detailed report with all issues
      --no-filter            Don't filter gaps by market hours (show all gaps)

  ## Thresholds

  Data quality is evaluated using these default thresholds:
  - FAIL: >1% of expected bars missing
  - WARN: >0.5% of expected bars missing
  - FAIL: >10 OHLC violations
  - WARN: Any OHLC violations

  ## Examples

      # Quick check for all symbols
      mix signal.validate_data

      # Validate and fix gaps for specific symbol
      mix signal.validate_data --symbols AAPL --fix-gaps

      # Show all gaps including overnight
      mix signal.validate_data --no-filter --verbose
  """

  use Mix.Task
  require Logger

  alias Signal.MarketData.Verifier
  alias Signal.MarketData.GapFiller

  @shortdoc "Validate historical data quality"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _} =
      OptionParser.parse!(args,
        strict: [
          symbols: :string,
          fix_gaps: :boolean,
          verbose: :boolean,
          no_filter: :boolean
        ]
      )

    symbols = get_symbols(opts[:symbols])
    filter_market_hours = !opts[:no_filter]
    fix_gaps = opts[:fix_gaps] || false
    verbose = opts[:verbose] || false

    if Enum.empty?(symbols) do
      Mix.shell().error("No symbols configured or provided. Use --symbols flag.")
      exit(:normal)
    end

    Mix.shell().info([
      :bright,
      "\nValidating data quality for #{length(symbols)} symbols",
      :normal,
      "\n"
    ])

    # Generate quality reports
    {:ok, result} =
      Verifier.generate_quality_reports(symbols, filter_market_hours: filter_market_hours)

    # Print results
    print_results(result, verbose)

    # Fix gaps if requested
    if fix_gaps do
      fix_detected_gaps(result.reports)
    end
  end

  defp get_symbols(nil) do
    Application.get_env(:signal, :symbols, [])
  end

  defp get_symbols(symbols_string) do
    symbols_string
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp print_results(result, verbose) do
    # Print individual reports
    Enum.each(result.reports, fn report ->
      status_color = status_color(report.status)
      status_icon = status_icon(report.status)

      Mix.shell().info([
        status_color,
        "#{status_icon} #{report.symbol}",
        :normal,
        " - #{format_coverage(report)}"
      ])

      if verbose && length(report.issues) > 0 do
        Enum.each(report.issues, fn issue ->
          Mix.shell().info(["    ", :yellow, "• #{issue}", :normal])
        end)
      end
    end)

    # Print summary
    Mix.shell().info("")
    summary = result.summary

    Mix.shell().info([
      :bright,
      "Summary: ",
      :normal,
      "#{summary.total_symbols} symbols checked"
    ])

    Mix.shell().info([
      :green,
      "  ✓ Pass: #{summary.pass}",
      :normal
    ])

    if summary.warn > 0 do
      Mix.shell().info([
        :yellow,
        "  ⚠ Warn: #{summary.warn}",
        :normal
      ])
    end

    if summary.fail > 0 do
      Mix.shell().info([
        :red,
        "  ✗ Fail: #{summary.fail}",
        :normal
      ])
    end

    overall_color = status_color(summary.overall_status)

    Mix.shell().info([
      "\nOverall: ",
      overall_color,
      "#{String.upcase(to_string(summary.overall_status))}",
      :normal,
      "\n"
    ])
  end

  defp format_coverage(report) do
    # Use regular_hours_bars for coverage display (excludes pre/post market)
    bars = format_number(report.regular_hours_bars)
    expected = format_number(report.expected_bars)

    if report.expected_bars > 0 do
      extended_note =
        if report.total_bars > report.regular_hours_bars do
          extended_count = report.total_bars - report.regular_hours_bars
          " (+#{format_number(extended_count)} extended hours)"
        else
          ""
        end

      "#{bars}/#{expected} bars (#{report.coverage_pct}% coverage)#{extended_note}"
    else
      "#{bars} bars (no calendar data for expected count)"
    end
  end

  defp fix_detected_gaps(reports) do
    # Find reports with gaps
    reports_with_gaps =
      reports
      |> Enum.filter(fn report -> report.gap_count > 0 end)

    if Enum.empty?(reports_with_gaps) do
      Mix.shell().info("No gaps to fix.\n")
    else
      Mix.shell().info([
        :bright,
        "\nAttempting to fix gaps...",
        :normal,
        "\n"
      ])

      Enum.each(reports_with_gaps, fn report ->
        Mix.shell().info("  #{report.symbol}: #{report.gap_count} gaps")

        case GapFiller.check_and_fill(report.symbol) do
          {:ok, 0} ->
            Mix.shell().info(["    ", :yellow, "No bars filled (gaps may be too old)", :normal])

          {:ok, count} ->
            Mix.shell().info([
              "    ",
              :green,
              "✓ Filled #{count} bars",
              :normal
            ])

          {:error, reason} ->
            Mix.shell().error("    ✗ Error: #{inspect(reason)}")
        end
      end)

      Mix.shell().info("")
    end
  end

  defp status_color(:pass), do: :green
  defp status_color(:warn), do: :yellow
  defp status_color(:fail), do: :red

  defp status_icon(:pass), do: "✓"
  defp status_icon(:warn), do: "⚠"
  defp status_icon(:fail), do: "✗"

  defp format_number(num) when num >= 1_000_000 do
    "#{Float.round(num / 1_000_000, 1)}M"
  end

  defp format_number(num) when num >= 1_000 do
    "#{Float.round(num / 1_000, 1)}K"
  end

  defp format_number(num), do: "#{num}"
end
