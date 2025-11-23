#!/usr/bin/env elixir

# Diagnostic script to investigate Alpaca API issues
# Usage: mix run scripts/diagnose_alpaca_api.exs

IO.puts("\n" <> String.duplicate("=", 70))
IO.puts("Alpaca API Diagnostic Script")
IO.puts(String.duplicate("=", 70) <> "\n")

alias Signal.Alpaca.{Client, Config}

# Check credentials
IO.puts("1. Checking Alpaca Configuration...")
IO.puts("   Configured: #{Config.configured?()}")
IO.puts("   Paper Trading: #{Config.paper_trading?()}")
IO.puts("   Data Feed: #{Config.data_feed()}")
IO.puts("   Base URL: #{Config.base_url()}")
IO.puts("")

unless Config.configured?() do
  IO.puts(IO.ANSI.red() <> "ERROR: Alpaca credentials not configured" <> IO.ANSI.reset())
  System.halt(1)
end

# Test 1: Get latest bar (should always work)
IO.puts("2. Testing get_latest_bar for AAPL...")
case Client.get_latest_bar("AAPL") do
  {:ok, bar} ->
    IO.puts(IO.ANSI.green() <> "   ✓ SUCCESS" <> IO.ANSI.reset())
    IO.puts("   Timestamp: #{bar.timestamp}")
    IO.puts("   Close: $#{bar.close}")
  {:error, reason} ->
    IO.puts(IO.ANSI.red() <> "   ✗ FAILED: #{inspect(reason)}" <> IO.ANSI.reset())
end
IO.puts("")

# Test 2: Try different dates to find what works
IO.puts("3. Testing historical data access...")

test_dates = [
  {"Yesterday", Date.add(Date.utc_today(), -1)},
  {"3 days ago", Date.add(Date.utc_today(), -3)},
  {"1 week ago", Date.add(Date.utc_today(), -7)},
  {"2 weeks ago", Date.add(Date.utc_today(), -14)},
  {"Nov 17, 2025", ~D[2025-11-17]},
  {"1 month ago", Date.add(Date.utc_today(), -30)},
  {"3 months ago", Date.add(Date.utc_today(), -90)}
]

Enum.each(test_dates, fn {label, test_date} ->
  # Skip weekends
  day_of_week = Date.day_of_week(test_date)
  if day_of_week in [6, 7] do
    IO.puts("   #{label} (#{test_date}): WEEKEND - skipping")
  else
    start_time = DateTime.new!(test_date, ~T[09:30:00], "Etc/UTC")
    end_time = DateTime.new!(test_date, ~T[09:31:00], "Etc/UTC")

    case Client.get_bars("AAPL", start: start_time, end: end_time, timeframe: "1Min") do
      {:ok, bars_map} ->
        bars = Map.get(bars_map, "AAPL", [])
        if length(bars) > 0 do
          IO.puts(IO.ANSI.green() <> "   ✓ #{label} (#{test_date}): #{length(bars)} bars" <> IO.ANSI.reset())
        else
          IO.puts(IO.ANSI.yellow() <> "   ⚠ #{label} (#{test_date}): 0 bars (might be holiday)" <> IO.ANSI.reset())
        end
      {:error, :not_found} ->
        IO.puts(IO.ANSI.red() <> "   ✗ #{label} (#{test_date}): NOT FOUND (404)" <> IO.ANSI.reset())
      {:error, reason} ->
        IO.puts(IO.ANSI.red() <> "   ✗ #{label} (#{test_date}): #{inspect(reason)}" <> IO.ANSI.reset())
    end
  end
end)

IO.puts("")

# Test 3: Check what data feed allows
IO.puts("4. Data Feed Information:")
case Config.data_feed() do
  :iex ->
    IO.puts("   Feed: IEX (Free)")
    IO.puts("   " <> IO.ANSI.yellow() <> "Note: IEX free feed has limited historical data" <> IO.ANSI.reset())
    IO.puts("   - Real-time data: ✓")
    IO.puts("   - Historical data: Limited (typically last 15 minutes)")
    IO.puts("   - For full historical data, upgrade to SIP feed")
  :sip ->
    IO.puts("   Feed: SIP (Premium)")
    IO.puts("   - Full historical data access")
  :test ->
    IO.puts("   Feed: Test")
    IO.puts("   - Use FAKEPACA symbol for testing")
end

IO.puts("")

# Recommendations
IO.puts(String.duplicate("=", 70))
IO.puts("Recommendations:")
IO.puts(String.duplicate("=", 70))

case Config.data_feed() do
  :iex ->
    IO.puts(IO.ANSI.yellow() <> """

    The IEX free feed has LIMITED historical data access:
    - Real-time and recent data (last ~15 minutes): Available
    - Historical data (days/weeks old): NOT AVAILABLE on free tier

    To test historical data loading:
    1. Use get_latest_bar() which works on free tier
    2. Upgrade to SIP feed for full historical access
    3. Or use the test stream with FAKEPACA symbol

    For production historical data loading (5 years), you need:
    - Alpaca Markets account with SIP data feed subscription
    - Or use a different data source
    """ <> IO.ANSI.reset())
  _ ->
    IO.puts("Your data feed should support historical data access.")
    IO.puts("If tests are still failing, verify:")
    IO.puts("  - The date is not a market holiday")
    IO.puts("  - The date is not a weekend")
    IO.puts("  - Your subscription includes historical data")
end

IO.puts("")
