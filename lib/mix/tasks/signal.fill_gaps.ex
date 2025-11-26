defmodule Mix.Tasks.Signal.FillGaps do
  @moduledoc """
  Mix task to detect and fill gaps in market bar data.

  This task checks for missing bars in the database (e.g., from server downtime)
  and fetches them from Alpaca Markets to ensure continuous data coverage.

  ## Usage

      # Check and fill gaps for all configured symbols
      mix signal.fill_gaps

      # Check and fill gaps for specific symbols
      mix signal.fill_gaps --symbols AAPL,TSLA,NVDA

      # Check gaps without filling (dry run)
      mix signal.fill_gaps --check-only

      # Set maximum gap size to fill (in minutes)
      mix signal.fill_gaps --max-gap 720

  ## Options

      --symbols AAPL,TSLA    Comma-separated list of symbols (default: all configured)
      --max-gap MINUTES      Maximum gap to fill in minutes (default: 1440 = 24 hours)
      --check-only           Check for gaps without filling them

  ## Examples

      # Fill gaps up to 24 hours for all symbols
      mix signal.fill_gaps

      # Check gaps for a specific symbol without filling
      mix signal.fill_gaps --symbols AAPL --check-only

      # Fill gaps up to 6 hours only
      mix signal.fill_gaps --max-gap 360
  """

  use Mix.Task
  require Logger

  alias Signal.MarketData.GapFiller

  @shortdoc "Detect and fill gaps in market bar data"

  @default_max_gap_minutes 1440

  @impl Mix.Task
  def run(args) do
    # Start application
    Mix.Task.run("app.start")

    # Parse options
    {opts, _} =
      OptionParser.parse!(args,
        strict: [
          symbols: :string,
          max_gap: :integer,
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

    max_gap_minutes = opts[:max_gap] || @default_max_gap_minutes
    check_only = opts[:check_only] || false

    # Print header
    print_header(symbols, max_gap_minutes, check_only)

    # Check for gaps
    if check_only do
      check_gaps(symbols)
    else
      fill_gaps(symbols, max_gap_minutes)
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

  defp print_header(symbols, max_gap_minutes, check_only) do
    mode = if check_only, do: "Checking", else: "Filling"

    Mix.shell().info([
      :bright,
      "\n#{mode} gaps for #{length(symbols)} symbols",
      :normal,
      "\n"
    ])

    Mix.shell().info("Symbols: #{Enum.join(symbols, ", ")}")
    Mix.shell().info("Max gap: #{max_gap_minutes} minutes (#{format_duration(max_gap_minutes)})")

    if check_only do
      Mix.shell().info("Mode: Check only (no data will be downloaded)")
    end

    Mix.shell().info("\n")
  end

  defp check_gaps(symbols) do
    Mix.shell().info("Checking for gaps (scanning last 24 hours)...\n")

    Enum.each(symbols, fn symbol ->
      case GapFiller.detect_gaps(symbol, 24) do
        {:ok, []} ->
          Mix.shell().info("  #{symbol}: ✓ No gaps detected")

        {:ok, gaps} ->
          Mix.shell().info([
            :yellow,
            "  #{symbol}: Found #{length(gaps)} gap(s)",
            :normal
          ])

          Enum.each(gaps, fn {start_time, end_time} ->
            gap_minutes = DateTime.diff(end_time, start_time, :minute)

            Mix.shell().info([
              "    • #{gap_minutes}m gap: #{format_datetime(start_time)} → #{format_datetime(end_time)}"
            ])
          end)

        {:error, reason} ->
          Mix.shell().error("  #{symbol}: Error - #{inspect(reason)}")
      end
    end)

    Mix.shell().info("\n✓ Gap check complete\n")
  end

  defp fill_gaps(symbols, max_gap_minutes) do
    Mix.shell().info("Filling gaps (scanning last 24 hours)...\n")

    results =
      Enum.map(symbols, fn symbol ->
        Mix.shell().info("  #{symbol}:")

        case GapFiller.check_and_fill(symbol,
               lookback_hours: 24,
               max_gap_minutes: max_gap_minutes
             ) do
          {:ok, 0} ->
            Mix.shell().info("    ✓ No gaps or gaps too small/large\n")
            {symbol, 0}

          {:ok, count} ->
            Mix.shell().info([
              :green,
              "    ✓ Filled #{count} bars\n",
              :normal
            ])

            {symbol, count}

          {:error, reason} ->
            Mix.shell().error("    ✗ Error: #{inspect(reason)}\n")
            {symbol, {:error, reason}}
        end
      end)

    total_filled =
      results
      |> Enum.map(fn {_symbol, result} -> if is_integer(result), do: result, else: 0 end)
      |> Enum.sum()

    errors =
      results
      |> Enum.filter(fn {_symbol, result} -> match?({:error, _}, result) end)
      |> length()

    Mix.shell().info([
      :bright,
      "\n✓ Gap filling complete",
      :normal
    ])

    Mix.shell().info("  Total bars filled: #{total_filled}")

    if errors > 0 do
      Mix.shell().error("  Errors: #{errors} symbols failed")
    end

    Mix.shell().info("\n")
  end

  defp format_duration(minutes) when minutes < 60 do
    "#{minutes}m"
  end

  defp format_duration(minutes) when minutes < 1440 do
    hours = div(minutes, 60)
    mins = rem(minutes, 60)
    "#{hours}h #{mins}m"
  end

  defp format_duration(minutes) do
    days = div(minutes, 1440)
    hours = div(rem(minutes, 1440), 60)
    "#{days}d #{hours}h"
  end

  defp format_datetime(datetime) do
    datetime
    |> DateTime.shift_zone!("America/New_York")
    |> Calendar.strftime("%Y-%m-%d %H:%M:%S %Z")
  end
end
