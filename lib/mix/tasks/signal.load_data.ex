defmodule Mix.Tasks.Signal.LoadData do
  @moduledoc """
  Mix task to load historical market data from Alpaca Markets.

  ## Usage

      # Load all symbols for 5 years (default)
      mix signal.load_data

      # Load specific symbols
      mix signal.load_data --symbols AAPL,TSLA,NVDA

      # Load custom date range
      mix signal.load_data --symbols AAPL --start-date 2020-01-01 --end-date 2020-12-31

      # Load specific year only (incremental approach)
      mix signal.load_data --year 2024

      # Load one year for specific symbols
      mix signal.load_data --symbols AAPL,TSLA --year 2023

      # Check coverage without downloading
      mix signal.load_data --check-only

      # Check coverage for specific symbols
      mix signal.load_data --symbols AAPL,TSLA --check-only

  ## Options

      --symbols AAPL,TSLA    Comma-separated list of symbols (default: all configured)
      --start-date DATE      Start date in YYYY-MM-DD format (default: 5 years ago)
      --end-date DATE        End date in YYYY-MM-DD format (default: today)
      --year YYYY            Load specific year only (overrides start/end dates)
      --check-only           Check coverage without downloading data
  """

  use Mix.Task
  require Logger

  alias Signal.MarketData.HistoricalLoader

  @shortdoc "Load historical market data from Alpaca"

  @default_years_back 5

  @impl Mix.Task
  def run(args) do
    # Start application
    Mix.Task.run("app.start")

    # Parse options
    {opts, _} =
      OptionParser.parse!(args,
        strict: [
          symbols: :string,
          start_date: :string,
          end_date: :string,
          year: :integer,
          check_only: :boolean
        ]
      )

    # Get symbol list
    symbols = get_symbols(opts[:symbols])

    if Enum.empty?(symbols) do
      Mix.shell().error(
        "No symbols configured or provided. Set symbols in config or use --symbols flag."
      )

      exit(:normal)
    end

    # Get date range
    {start_date, end_date} = get_date_range(opts)

    # Print header
    print_header(symbols, start_date, end_date)

    # Execute task
    if opts[:check_only] do
      check_coverage(symbols, start_date, end_date)
    else
      load_data(symbols, start_date, end_date)
    end
  end

  # Private Functions

  defp get_symbols(nil) do
    Application.get_env(:signal, :symbols, [])
  end

  defp get_symbols(symbols_str) do
    symbols_str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.upcase/1)
  end

  defp get_date_range(opts) do
    cond do
      opts[:year] ->
        year = opts[:year]
        {Date.new!(year, 1, 1), Date.new!(year, 12, 31)}

      opts[:start_date] && opts[:end_date] ->
        start_date = parse_date!(opts[:start_date])
        end_date = parse_date!(opts[:end_date])
        {start_date, end_date}

      opts[:start_date] ->
        start_date = parse_date!(opts[:start_date])
        {start_date, Date.utc_today()}

      true ->
        # Default: 5 years ago to today
        start_date = Date.add(Date.utc_today(), -365 * @default_years_back)
        {start_date, Date.utc_today()}
    end
  end

  defp parse_date!(date_str) do
    case Date.from_iso8601(date_str) do
      {:ok, date} ->
        date

      {:error, _} ->
        Mix.shell().error("Invalid date format: #{date_str}. Use YYYY-MM-DD format.")
        exit(:normal)
    end
  end

  defp print_header(symbols, start_date, end_date) do
    Mix.shell().info("\nSignal Historical Data Loader")
    Mix.shell().info(String.duplicate("=", 50))
    Mix.shell().info("Symbols: #{Enum.join(symbols, ", ")} (#{length(symbols)} total)")

    years = end_date.year - start_date.year + 1

    Mix.shell().info(
      "Date Range: #{start_date} to #{end_date} (#{years} #{pluralize("year", years)})"
    )

    Mix.shell().info("")
  end

  defp check_coverage(symbols, start_date, end_date) do
    Mix.shell().info("Checking data coverage...\n")

    reports =
      symbols
      |> Enum.map(fn symbol ->
        {:ok, report} = HistoricalLoader.check_coverage(symbol, {start_date, end_date})
        {symbol, report}
      end)

    # Print coverage table
    Mix.shell().info("Coverage Report:")
    Mix.shell().info(String.duplicate("-", 80))

    Mix.shell().info(
      String.pad_trailing("Symbol", 10) <>
        String.pad_trailing("Bars", 12) <>
        String.pad_trailing("Coverage", 12) <>
        "Status"
    )

    Mix.shell().info(String.duplicate("-", 80))

    reports
    |> Enum.each(fn {symbol, report} ->
      bars = format_number(report.bars_count)
      coverage = "#{report.coverage_pct}%"

      status =
        cond do
          report.coverage_pct == 100.0 -> "✓ Complete"
          report.coverage_pct >= 80.0 -> "~ Partial"
          report.bars_count == 0 -> "✗ Empty"
          true -> "✗ Incomplete"
        end

      Mix.shell().info(
        String.pad_trailing(symbol, 10) <>
          String.pad_trailing(bars, 12) <>
          String.pad_trailing(coverage, 12) <>
          status
      )

      # Show details if incomplete
      if report.coverage_pct < 100.0 && report.coverage_pct > 0.0 do
        Mix.shell().info("  → Has data: #{inspect(report.years_with_data)}")
        Mix.shell().info("  → Missing: #{inspect(report.missing_years)}")
      end
    end)

    total_bars = reports |> Enum.map(fn {_, r} -> r.bars_count end) |> Enum.sum()
    Mix.shell().info(String.duplicate("-", 80))
    Mix.shell().info("Total bars: #{format_number(total_bars)}\n")
  end

  defp load_data(symbols, start_date, end_date) do
    Mix.shell().info("Loading data...\n")

    start_time = System.monotonic_time(:second)

    case HistoricalLoader.load_bars(symbols, start_date, end_date) do
      {:ok, results} ->
        elapsed = System.monotonic_time(:second) - start_time

        # Print results table
        Mix.shell().info("\nSummary:")
        Mix.shell().info(String.duplicate("=", 50))

        results
        |> Enum.sort_by(fn {symbol, _} -> symbol end)
        |> Enum.with_index(1)
        |> Enum.each(fn {{symbol, count}, index} ->
          Mix.shell().info(
            "[#{String.pad_leading("#{index}", 2)}/#{String.pad_leading("#{length(symbols)}", 2)}] " <>
              "#{String.pad_trailing(symbol, 6)}: #{String.pad_leading(format_number(count), 8)} new bars loaded"
          )
        end)

        total_bars = results |> Map.values() |> Enum.sum()
        rate = if elapsed > 0, do: div(total_bars, elapsed), else: 0

        Mix.shell().info(String.duplicate("=", 50))
        Mix.shell().info("Total bars loaded: #{format_number(total_bars)}")
        Mix.shell().info("Total time: #{format_duration(elapsed)}")
        Mix.shell().info("Average: #{format_number(rate)} bars/second")
        Mix.shell().info("")

      {:error, reason} ->
        Mix.shell().error("Load failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp format_number(num) when num >= 1_000_000 do
    millions = Float.round(num / 1_000_000, 1)
    "#{millions}M"
  end

  defp format_number(num) when num >= 1_000 do
    thousands = Float.round(num / 1_000, 1)
    "#{thousands}K"
  end

  defp format_number(num), do: "#{num}"

  defp format_duration(seconds) when seconds >= 3600 do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    secs = rem(seconds, 60)
    "#{hours}h #{minutes}m #{secs}s"
  end

  defp format_duration(seconds) when seconds >= 60 do
    minutes = div(seconds, 60)
    secs = rem(seconds, 60)
    "#{minutes}m #{secs}s"
  end

  defp format_duration(seconds), do: "#{seconds}s"

  defp pluralize(word, 1), do: word
  defp pluralize(word, _), do: "#{word}s"
end
