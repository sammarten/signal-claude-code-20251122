#!/usr/bin/env elixir

# Quick Sample Data Loader
# This script demonstrates loading a small amount of historical data
# Useful for: testing, demos, or getting started quickly
#
# Usage: mix run scripts/load_sample_data.exs

IO.puts("\n" <> String.duplicate("=", 70))
IO.puts("Sample Data Loader")
IO.puts("Loading 1 month of data for quick testing...")
IO.puts(String.duplicate("=", 70) <> "\n")

alias Signal.MarketData.HistoricalLoader

# Configuration
sample_symbols = ["AAPL", "TSLA", "NVDA"]  # Just a few symbols
sample_month = Date.utc_today() |> Date.beginning_of_month() |> Date.add(-30)  # Last full month
start_date = Date.beginning_of_month(sample_month)
end_date = Date.end_of_month(sample_month)

IO.puts("Symbols: #{Enum.join(sample_symbols, ", ")}")
IO.puts("Date Range: #{start_date} to #{end_date}")
IO.puts("(Approximately 1 month of 1-minute bars)\n")

# Check if Alpaca is configured
unless Signal.Alpaca.Config.configured?() do
  IO.puts(IO.ANSI.red() <> "ERROR: Alpaca credentials not configured" <> IO.ANSI.reset())
  IO.puts("\nPlease set the following environment variables:")
  IO.puts("  export ALPACA_API_KEY=\"your_key_here\"")
  IO.puts("  export ALPACA_API_SECRET=\"your_secret_here\"")
  IO.puts("\nOr create a .env file in the project root:")
  IO.puts("  cp .env.example .env")
  IO.puts("  # Edit .env with your credentials")
  IO.puts("  source .env")
  System.halt(1)
end

IO.puts(IO.ANSI.green() <> "✓ Alpaca credentials configured" <> IO.ANSI.reset())
IO.puts("Feed: #{Signal.Alpaca.Config.data_feed()}")
IO.puts("Paper Trading: #{Signal.Alpaca.Config.paper_trading?()}\n")

# Check existing data
IO.puts("Checking for existing data...")
existing_coverage = Enum.map(sample_symbols, fn symbol ->
  {:ok, coverage} = HistoricalLoader.check_coverage(symbol, {start_date, end_date})
  {symbol, coverage.bars_count}
end)

total_existing = existing_coverage |> Enum.map(fn {_, count} -> count end) |> Enum.sum()

if total_existing > 0 do
  IO.puts(IO.ANSI.yellow() <> "\nExisting data found:" <> IO.ANSI.reset())
  Enum.each(existing_coverage, fn {symbol, count} ->
    if count > 0 do
      IO.puts("  #{symbol}: #{count} bars")
    end
  end)
  IO.puts("\nNote: Loader will skip already-downloaded data (idempotent)")
end

# Ask for confirmation
IO.puts("\n" <> IO.ANSI.cyan() <> "Ready to load data. This may take 5-10 minutes." <> IO.ANSI.reset())
IO.write("Continue? [y/N]: ")

response = IO.gets("") |> String.trim() |> String.downcase()

unless response in ["y", "yes"] do
  IO.puts("Cancelled.")
  System.halt(0)
end

# Load the data
IO.puts("\n" <> String.duplicate("-", 70))
IO.puts("Loading data...\n")

start_time = System.monotonic_time(:second)

case HistoricalLoader.load_bars(sample_symbols, start_date, end_date) do
  {:ok, results} ->
    elapsed = System.monotonic_time(:second) - start_time

    IO.puts("\n" <> String.duplicate("-", 70))
    IO.puts(IO.ANSI.green() <> "✓ Load Complete!" <> IO.ANSI.reset())
    IO.puts(String.duplicate("-", 70))

    # Show results
    Enum.each(results, fn {symbol, count} ->
      status = if count > 0, do: IO.ANSI.green() <> "✓", else: IO.ANSI.yellow() <> "•"
      IO.puts("#{status <> IO.ANSI.reset()} #{symbol}: #{count} new bars")
    end)

    total_new = results |> Map.values() |> Enum.sum()

    IO.puts("\nTotal new bars: #{total_new}")
    IO.puts("Time elapsed: #{elapsed} seconds")

    if total_new > 0 do
      rate = div(total_new, max(elapsed, 1))
      IO.puts("Rate: #{rate} bars/second")
    end

    # Next steps
    IO.puts("\n" <> IO.ANSI.cyan() <> "Next Steps:" <> IO.ANSI.reset())
    IO.puts("  1. Verify data quality:")
    IO.puts("     mix run scripts/verify_data.exs #{Enum.join(sample_symbols, " ")}")
    IO.puts("\n  2. Check coverage:")
    IO.puts("     mix signal.load_data --symbols #{Enum.join(sample_symbols, ",")} --check-only")
    IO.puts("\n  3. Load more data:")
    IO.puts("     mix signal.load_data --year 2024")
    IO.puts("\n  4. Start the application to see real-time data:")
    IO.puts("     mix phx.server")

  {:error, reason} ->
    IO.puts("\n" <> IO.ANSI.red() <> "✗ Load Failed" <> IO.ANSI.reset())
    IO.puts("Error: #{inspect(reason)}")
    System.halt(1)
end

IO.puts("")
