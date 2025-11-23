#!/usr/bin/env elixir

# Test raw Alpaca API responses
IO.puts("\n=== Testing Raw Alpaca API ===\n")

alias Signal.Alpaca.Config

api_key = Config.api_key!()
api_secret = Config.api_secret!()
base_url = Config.base_url()

IO.puts("Base URL: #{base_url}")
IO.puts("API Key: #{String.slice(api_key, 0..10)}...")
IO.puts("")

# Test 1: Account endpoint (should always work)
IO.puts("1. Testing /v2/account...")
account_url = "#{base_url}/v2/account"

case Req.get(
  url: account_url,
  headers: [
    {"APCA-API-KEY-ID", api_key},
    {"APCA-API-SECRET-KEY", api_secret}
  ]
) do
  {:ok, %{status: 200, body: body}} ->
    IO.puts(IO.ANSI.green() <> "   ✓ SUCCESS" <> IO.ANSI.reset())
    IO.puts("   Account ID: #{body["id"]}")
    IO.puts("   Status: #{body["status"]}")
  {:ok, %{status: status, body: body}} ->
    IO.puts(IO.ANSI.red() <> "   ✗ FAILED: HTTP #{status}" <> IO.ANSI.reset())
    IO.puts("   Body: #{inspect(body)}")
  {:error, error} ->
    IO.puts(IO.ANSI.red() <> "   ✗ ERROR: #{inspect(error)}" <> IO.ANSI.reset())
end

IO.puts("")

# Test 2: Latest bar endpoint
IO.puts("2. Testing /v2/stocks/AAPL/bars/latest...")

# Try data.alpaca.markets (the correct endpoint for market data)
data_urls = [
  {"paper-api.alpaca.markets", "#{base_url}/v2/stocks/AAPL/bars/latest"},
  {"data.alpaca.markets", "https://data.alpaca.markets/v2/stocks/AAPL/bars/latest"}
]

Enum.each(data_urls, fn {host, url} ->
  IO.puts("\n   Trying #{host}...")

  case Req.get(
    url: url,
    headers: [
      {"APCA-API-KEY-ID", api_key},
      {"APCA-API-SECRET-KEY", api_secret}
    ]
  ) do
    {:ok, %{status: 200, body: body}} ->
      IO.puts(IO.ANSI.green() <> "   ✓ SUCCESS" <> IO.ANSI.reset())
      if body["bar"] do
        bar = body["bar"]
        IO.puts("   Timestamp: #{bar["t"]}")
        IO.puts("   Close: $#{bar["c"]}")
      end
    {:ok, %{status: status, body: body}} ->
      IO.puts(IO.ANSI.red() <> "   ✗ FAILED: HTTP #{status}" <> IO.ANSI.reset())
      IO.puts("   Body: #{inspect(body, pretty: true)}")
    {:error, error} ->
      IO.puts(IO.ANSI.red() <> "   ✗ ERROR: #{inspect(error)}" <> IO.ANSI.reset())
  end
end)

IO.puts("\n\n=== Analysis ===")
IO.puts("""
If you see:
- ✓ Account endpoint works: Your credentials are valid
- ✗ Market data fails with 404: Your account doesn't have market data access

Alpaca Market Data requires:
1. A funded live account (not just paper trading)
2. Market data subscription (separate from trading)
3. Or use Alpaca's free IEX feed (limited to real-time only)

Note: paper-api.alpaca.markets is for TRADING, not market data.
Market data comes from data.alpaca.markets regardless of paper/live trading.
""")
