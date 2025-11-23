#!/usr/bin/env elixir

# Test Script for Historical Data Loader
# Usage: mix run scripts/test_historical_loader.exs

IO.puts("\n" <> String.duplicate("=", 70))
IO.puts("Historical Data Loader Test Suite")
IO.puts(String.duplicate("=", 70) <> "\n")

alias Signal.MarketData.{Bar, HistoricalLoader, Verifier}
alias Signal.Repo

import Ecto.Query

# Test configuration
test_symbol = "AAPL"
test_year = 2024
test_start_date = ~D[2024-01-01]
test_end_date = ~D[2024-01-31]  # Just January for quick test

# Color output helpers
defmodule Colors do
  def green(text), do: IO.ANSI.green() <> text <> IO.ANSI.reset()
  def red(text), do: IO.ANSI.red() <> text <> IO.ANSI.reset()
  def yellow(text), do: IO.ANSI.yellow() <> text <> IO.ANSI.reset()
  def blue(text), do: IO.ANSI.blue() <> text <> IO.ANSI.reset()
  def cyan(text), do: IO.ANSI.cyan() <> text <> IO.ANSI.reset()
end

defmodule TestRunner do
  def run_test(name, fun) do
    IO.write("#{Colors.cyan("→")} #{name}... ")

    try do
      result = fun.()
      IO.puts(Colors.green("✓ PASS"))
      {:ok, result}
    rescue
      error ->
        IO.puts(Colors.red("✗ FAIL"))
        IO.puts("  #{Colors.red("Error:")} #{inspect(error)}")
        {:error, error}
    catch
      :exit, reason ->
        IO.puts(Colors.red("✗ FAIL"))
        IO.puts("  #{Colors.red("Exit:")} #{inspect(reason)}")
        {:error, reason}
    end
  end

  def assert(condition, message \\ "Assertion failed") do
    unless condition do
      raise message
    end
  end

  def assert_eq(actual, expected, message \\ "") do
    unless actual == expected do
      raise "Expected #{inspect(expected)}, got #{inspect(actual)}. #{message}"
    end
  end
end

# Test 1: Database Connection
IO.puts(Colors.blue("Test Group 1: Database Connectivity"))
IO.puts(String.duplicate("-", 70))

TestRunner.run_test("Database connection", fn ->
  result = Ecto.Adapters.SQL.query!(Repo, "SELECT 1 as test")
  TestRunner.assert(result.num_rows == 1, "Database query failed")
  :ok
end)

TestRunner.run_test("market_bars table exists", fn ->
  result = Ecto.Adapters.SQL.query!(Repo, """
    SELECT EXISTS (
      SELECT FROM information_schema.tables
      WHERE table_name = 'market_bars'
    )
  """)
  [[exists]] = result.rows
  TestRunner.assert(exists, "market_bars table does not exist")
  :ok
end)

TestRunner.run_test("TimescaleDB hypertable configured", fn ->
  result = Ecto.Adapters.SQL.query!(Repo, """
    SELECT EXISTS (
      SELECT FROM timescaledb_information.hypertables
      WHERE hypertable_name = 'market_bars'
    )
  """)
  [[exists]] = result.rows
  TestRunner.assert(exists, "market_bars is not a hypertable")
  :ok
end)

IO.puts("")

# Test 2: Bar Schema
IO.puts(Colors.blue("Test Group 2: Bar Schema & Validation"))
IO.puts(String.duplicate("-", 70))

TestRunner.run_test("Create valid bar struct", fn ->
  bar = %Bar{
    symbol: "TEST",
    bar_time: ~U[2024-01-01 10:00:00Z],
    open: Decimal.new("100.00"),
    high: Decimal.new("101.00"),
    low: Decimal.new("99.00"),
    close: Decimal.new("100.50"),
    volume: 1000
  }
  TestRunner.assert(bar.symbol == "TEST")
  bar
end)

TestRunner.run_test("Validate OHLC relationships (valid)", fn ->
  changeset = Bar.changeset(%Bar{}, %{
    symbol: "TEST",
    bar_time: ~U[2024-01-01 10:00:00Z],
    open: Decimal.new("100.00"),
    high: Decimal.new("101.00"),
    low: Decimal.new("99.00"),
    close: Decimal.new("100.50"),
    volume: 1000
  })
  TestRunner.assert(changeset.valid?, "Valid bar should pass validation")
  :ok
end)

TestRunner.run_test("Validate OHLC relationships (invalid high)", fn ->
  changeset = Bar.changeset(%Bar{}, %{
    symbol: "TEST",
    bar_time: ~U[2024-01-01 10:00:00Z],
    open: Decimal.new("100.00"),
    high: Decimal.new("99.00"),  # High < open (invalid)
    low: Decimal.new("98.00"),
    close: Decimal.new("99.50"),
    volume: 1000
  })
  TestRunner.assert(!changeset.valid?, "Invalid high should fail validation")
  :ok
end)

TestRunner.run_test("from_alpaca/2 conversion", fn ->
  alpaca_bar = %{
    timestamp: ~U[2024-01-01 10:00:00Z],
    open: Decimal.new("100.00"),
    high: Decimal.new("101.00"),
    low: Decimal.new("99.00"),
    close: Decimal.new("100.50"),
    volume: 1000,
    vwap: Decimal.new("100.25"),
    trade_count: 50
  }
  bar = Bar.from_alpaca("TEST", alpaca_bar)
  TestRunner.assert(bar.symbol == "TEST")
  TestRunner.assert(Decimal.equal?(bar.open, Decimal.new("100.00")))
  :ok
end)

TestRunner.run_test("to_map/1 conversion", fn ->
  bar = %Bar{
    symbol: "TEST",
    bar_time: ~U[2024-01-01 10:00:00Z],
    open: Decimal.new("100.00"),
    high: Decimal.new("101.00"),
    low: Decimal.new("99.00"),
    close: Decimal.new("100.50"),
    volume: 1000
  }
  map = Bar.to_map(bar)
  TestRunner.assert(is_map(map))
  TestRunner.assert(map.symbol == "TEST")
  :ok
end)

IO.puts("")

# Test 3: Coverage Checking
IO.puts(Colors.blue("Test Group 3: Coverage Checking"))
IO.puts(String.duplicate("-", 70))

TestRunner.run_test("Check coverage for symbol with no data", fn ->
  # Clean up any existing test data first
  Repo.delete_all(from b in Bar, where: b.symbol == "TESTCOV")

  {:ok, coverage} = HistoricalLoader.check_coverage("TESTCOV", {~D[2024-01-01], ~D[2024-12-31]})
  TestRunner.assert_eq(coverage.bars_count, 0, "Should have no bars")
  TestRunner.assert_eq(coverage.coverage_pct, 0.0, "Should have 0% coverage")
  TestRunner.assert_eq(length(coverage.missing_years), 1, "Should have 1 missing year")
  TestRunner.assert([2024] == coverage.missing_years, "Should be missing 2024")
  :ok
end)

TestRunner.run_test("Insert test bars and check coverage", fn ->
  # Clean up first
  Repo.delete_all(from b in Bar, where: b.symbol == "TESTCOV2")

  # Insert some test bars for 2024
  bars = for minute <- 0..99 do
    %{
      symbol: "TESTCOV2",
      bar_time: DateTime.add(~U[2024-01-01 10:00:00.000000Z], minute * 60, :second),
      open: Decimal.new("100.00"),
      high: Decimal.new("101.00"),
      low: Decimal.new("99.00"),
      close: Decimal.new("100.50"),
      volume: 1000
    }
  end

  {count, _} = Repo.insert_all(Bar, bars, on_conflict: :nothing, conflict_target: [:symbol, :bar_time])
  TestRunner.assert(count == 100, "Should insert 100 bars")

  {:ok, coverage} = HistoricalLoader.check_coverage("TESTCOV2", {~D[2024-01-01], ~D[2024-12-31]})
  TestRunner.assert(coverage.bars_count == 100, "Should have 100 bars")
  TestRunner.assert(coverage.coverage_pct == 100.0, "Should have 100% coverage for 2024")
  TestRunner.assert([2024] == coverage.years_with_data, "Should have data for 2024")

  # Clean up
  Repo.delete_all(from b in Bar, where: b.symbol == "TESTCOV2")
  :ok
end)

IO.puts("")

# Test 4: Alpaca API (if configured)
IO.puts(Colors.blue("Test Group 4: Alpaca API Integration"))
IO.puts(String.duplicate("-", 70))

alpaca_configured = Signal.Alpaca.Config.configured?()

if alpaca_configured do
  IO.puts(Colors.green("✓ Alpaca credentials configured\n"))

  TestRunner.run_test("Fetch small date range from Alpaca", fn ->
    # Test with a very small date range (1 day) - use recent date to ensure data exists
    test_date = Date.add(Date.utc_today(), -10)  # 10 days ago

    # Ensure it's a weekday (Mon-Fri)
    test_date = case Date.day_of_week(test_date) do
      6 -> Date.add(test_date, -1)  # Saturday -> Friday
      7 -> Date.add(test_date, -2)  # Sunday -> Friday
      _ -> test_date
    end

    start_time = DateTime.new!(test_date, ~T[09:30:00], "Etc/UTC")
    end_time = DateTime.new!(test_date, ~T[16:00:00], "Etc/UTC")

    result = Signal.Alpaca.Client.get_bars(
      test_symbol,
      start: start_time,
      end: end_time,
      timeframe: "1Min"
    )

    case result do
      {:ok, bars_map} ->
        bars = Map.get(bars_map, test_symbol, [])
        IO.puts("\n  #{Colors.cyan("→")} Fetched #{length(bars)} bars for #{test_symbol}")
        TestRunner.assert(is_list(bars), "Should return list of bars")

        if length(bars) > 0 do
          first_bar = List.first(bars)
          IO.puts("  #{Colors.cyan("→")} First bar: #{first_bar.timestamp}")
          IO.puts("  #{Colors.cyan("→")} OHLC: #{first_bar.open} / #{first_bar.high} / #{first_bar.low} / #{first_bar.close}")
          TestRunner.assert(is_struct(first_bar.open, Decimal), "Prices should be Decimal")
        end
        :ok

      {:error, reason} ->
        raise "Alpaca API call failed: #{inspect(reason)}"
    end
  end)

  TestRunner.run_test("Load and store bars (1 day)", fn ->
    # Use recent weekday for testing
    test_date = Date.add(Date.utc_today(), -10)
    test_date = case Date.day_of_week(test_date) do
      6 -> Date.add(test_date, -1)
      7 -> Date.add(test_date, -2)
      _ -> test_date
    end

    # Clean up existing test data
    Repo.delete_all(from b in Bar, where: b.symbol == ^test_symbol and
      b.bar_time >= ^DateTime.new!(test_date, ~T[00:00:00], "Etc/UTC") and
      b.bar_time <= ^DateTime.new!(test_date, ~T[23:59:59], "Etc/UTC"))

    # Load one day of data
    {:ok, stats} = HistoricalLoader.load_bars(
      test_symbol,
      test_date,
      test_date
    )

    count = Map.get(stats, test_symbol, 0)
    IO.puts("\n  #{Colors.cyan("→")} Loaded #{count} bars")
    TestRunner.assert(count > 0, "Should load some bars")

    # Verify data was stored
    db_count = Repo.one(
      from b in Bar,
        where: b.symbol == ^test_symbol and
          b.bar_time >= ^DateTime.new!(test_date, ~T[00:00:00], "Etc/UTC") and
          b.bar_time <= ^DateTime.new!(test_date, ~T[23:59:59], "Etc/UTC"),
        select: count(b.bar_time)
    )

    IO.puts("  #{Colors.cyan("→")} Database has #{db_count} bars")
    TestRunner.assert(db_count == count, "Database count should match loaded count")
    :ok
  end)

  TestRunner.run_test("Idempotency test (re-run should not duplicate)", fn ->
    # Use same recent weekday
    test_date = Date.add(Date.utc_today(), -10)
    test_date = case Date.day_of_week(test_date) do
      6 -> Date.add(test_date, -1)
      7 -> Date.add(test_date, -2)
      _ -> test_date
    end

    # Run the same load again
    {:ok, stats} = HistoricalLoader.load_bars(
      test_symbol,
      test_date,
      test_date
    )

    count = Map.get(stats, test_symbol, 0)
    IO.puts("\n  #{Colors.cyan("→")} Second load: #{count} new bars (should be 0)")
    TestRunner.assert(count == 0, "Should not load duplicate bars")
    :ok
  end)

else
  IO.puts(Colors.yellow("⚠ Alpaca credentials not configured - skipping API tests"))
  IO.puts(Colors.yellow("  Set ALPACA_API_KEY and ALPACA_API_SECRET to run these tests\n"))
end

IO.puts("")

# Test 5: Verification
IO.puts(Colors.blue("Test Group 5: Data Verification"))
IO.puts(String.duplicate("-", 70))

if alpaca_configured do
  TestRunner.run_test("Verify symbol data quality", fn ->
    {:ok, report} = Verifier.verify_symbol(test_symbol)

    IO.puts("\n  #{Colors.cyan("→")} Total bars: #{report.total_bars}")
    IO.puts("  #{Colors.cyan("→")} Date range: #{inspect(report.date_range)}")
    IO.puts("  #{Colors.cyan("→")} Issue types found: #{length(report.issues)}")

    if length(report.issues) > 0 do
      Enum.each(report.issues, fn issue ->
        severity_color = case issue.severity do
          :critical -> &Colors.red/1
          :high -> &Colors.red/1
          :medium -> &Colors.yellow/1
          :low -> &Colors.yellow/1
          _ -> &Colors.cyan/1
        end

        IO.puts("  #{severity_color.("→")} #{issue.type}: #{issue.count} instances (#{issue.severity})")
      end)
    else
      IO.puts("  #{Colors.green("→")} No data quality issues found!")
    end

    TestRunner.assert(is_map(report), "Should return report map")
    :ok
  end)
else
  IO.puts(Colors.yellow("⚠ Skipping verification tests (no data loaded)\n"))
end

IO.puts("")

# Summary
IO.puts(String.duplicate("=", 70))
IO.puts(Colors.green("Test Suite Complete!"))
IO.puts(String.duplicate("=", 70))

IO.puts("\n#{Colors.cyan("Next Steps:")}")
IO.puts("  1. To load more data: mix signal.load_data --symbols #{test_symbol} --year 2024")
IO.puts("  2. To check coverage: mix signal.load_data --check-only")
IO.puts("  3. To verify data: mix run scripts/verify_data.exs")

IO.puts("\n#{Colors.cyan("Notes:")}")
IO.puts("  - Use --year flag for incremental loading (recommended)")
IO.puts("  - First load of 5 years takes 2-4 hours")
IO.puts("  - Loading is idempotent (safe to re-run)")
IO.puts("  - Data is stored in TimescaleDB with compression")

IO.puts("")
