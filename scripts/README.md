# Signal Scripts

This directory contains utility scripts for testing and interacting with the Signal trading system.

## Quick Reference

- `test_historical_loader.exs` - Comprehensive test suite for historical data loading
- `verify_data.exs` - Data quality verification and health checks
- `load_sample_data.exs` - Quick demo: load 1 month of sample data
- `test_alpaca_stream.exs` - Test WebSocket connection with live data
- `test_simple.exs` - Simple connectivity test

---

## test_historical_loader.exs

Comprehensive test suite for the historical data loading system.

**Usage:**
```bash
mix run scripts/test_historical_loader.exs
```

**Test Groups:**
1. **Database Connectivity** - Verifies database and TimescaleDB setup
2. **Bar Schema & Validation** - Tests OHLC validation and data structures
3. **Coverage Checking** - Tests duplicate detection and coverage tracking
4. **Alpaca API Integration** - Tests data fetching and storage (requires credentials)
5. **Data Verification** - Tests data quality checks

**Features:**
- Color-coded test results (✓ pass, ✗ fail)
- Automatic test data cleanup
- Skips Alpaca tests if credentials not configured
- Safe to run multiple times

**Example Output:**
```
Test Group 1: Database Connectivity
----------------------------------------------------------------------
→ Database connection... ✓ PASS
→ market_bars table exists... ✓ PASS
→ TimescaleDB hypertable configured... ✓ PASS
```

---

## verify_data.exs

Data quality verification and health check for loaded market data.

**Usage:**
```bash
# Verify all configured symbols
mix run scripts/verify_data.exs

# Verify specific symbols
mix run scripts/verify_data.exs AAPL TSLA NVDA
```

**What it checks:**
- OHLC relationship violations (high < open/close, etc.)
- Data gaps during market hours
- Duplicate bars
- Statistical summaries (bar counts, date ranges, trading days, average volume)
- Overall health status

**Health Ratings:**
- ✓ **EXCELLENT** - No issues found
- ✓ **GOOD** - Minor issues only
- ⚠ **FAIR** - Some quality issues
- ✗ **POOR** - Significant issues

**Example Output:**
```
AAPL
----------------------------------------------------------------------
Bars: 487.2K
Date Range: 2019-11-15 to 2024-11-15
Trading Days: 1,234
Avg Bars/Day: 395 (expect ~390 for 1-min bars)

Quality Checks:
  ✓ No data quality issues found!

Overall Health:
  ✓ EXCELLENT - Data quality is high
```

---

## load_sample_data.exs

Quick demo script to load a small amount of data for testing.

**Usage:**
```bash
mix run scripts/load_sample_data.exs
```

**What it does:**
- Loads 1 month of data for 3 symbols (AAPL, TSLA, NVDA)
- Uses the most recent complete month
- Interactive - asks for confirmation before loading
- Shows progress and detailed results
- Idempotent (safe to re-run)

**Use cases:**
- Quick testing without full historical load (5-10 minutes vs 2-4 hours)
- Demos and presentations
- Validating Alpaca credentials
- Learning the data loading process

**Requirements:**
- Alpaca credentials must be configured
- Database must be running and migrated

**Example Session:**
```
Sample Data Loader
Loading 1 month of data for quick testing...
======================================================================

Symbols: AAPL, TSLA, NVDA
Date Range: 2024-10-01 to 2024-10-31

✓ Alpaca credentials configured
Feed: iex
Paper Trading: true

Ready to load data. This may take 5-10 minutes.
Continue? [y/N]: y

Loading data...
[HistoricalLoader] AAPL: 2024 complete (8.2K bars, 3.4s)
...

✓ Load Complete!
Total new bars: 24,567
Time elapsed: 342 seconds
```

---

## test_alpaca_stream.exs

Test the Alpaca WebSocket connection using the test stream endpoint.

### Usage

1. **Set your Alpaca credentials** (required even for test stream):
   ```bash
   export ALPACA_API_KEY="your_key_here"
   export ALPACA_API_SECRET="your_secret_here"
   ```

   Or use the `.env` file:
   ```bash
   source .env
   ```

2. **Start IEx**:
   ```bash
   iex -S mix
   ```

3. **Run the script**:
   ```elixir
   Code.eval_file("scripts/test_alpaca_stream.exs")
   ```

### What It Does

- Connects to the Alpaca test WebSocket stream (`wss://stream.data.alpaca.markets/v2/test`)
- Subscribes to the `FAKEPACA` symbol (test symbol that always has data)
- Displays real-time messages in color-coded format:
  - 🟢 **Green** - Quotes (bid/ask prices)
  - 🔵 **Blue** - Bars (OHLCV data)
  - 🟡 **Yellow** - Trades
  - 🟣 **Magenta** - Status changes
  - 🔵 **Cyan** - Connection events

### Available Commands

Once the script is running, you can use these commands in IEx:

```elixir
# Check how many messages received
TestStreamHandler.message_count()

# Get all received messages
TestStreamHandler.get_messages()

# Clear message history
TestStreamHandler.clear_messages()

# Check connection status
Signal.Alpaca.Stream.status(:test_stream)

# View active subscriptions
Signal.Alpaca.Stream.subscriptions(:test_stream)

# Stop the test stream
GenServer.stop(:test_stream)
```

### Example Output

```
================================================================================
  Alpaca Test Stream Connection Script
================================================================================

This script will connect to the Alpaca test WebSocket stream and subscribe
to the FAKEPACA symbol. You should start seeing messages within a few seconds.

✓ Alpaca credentials configured

Starting WebSocket connection to test stream...
URL: wss://stream.data.alpaca.markets/v2/test
✓ Stream started successfully (PID: #PID<0.456.0>)
Connection status: connected

Waiting for messages...
(Messages will appear below as they arrive)

[1] CONNECTION: connected
[2] QUOTE: FAKEPACA - Bid: $100.25 (100) | Ask: $100.27 (200)
[3] BAR: FAKEPACA - O: $100.20 H: $100.30 L: $100.15 C: $100.25 V: 15000
[4] TRADE: FAKEPACA - Price: $100.26 Size: 50
```

### Troubleshooting

**"Alpaca credentials NOT configured"**
- Make sure you've set `ALPACA_API_KEY` and `ALPACA_API_SECRET` environment variables
- Get free credentials at https://alpaca.markets/
- Restart IEx after setting credentials: `source .env && iex -S mix`

**"Stream already running"**
- Stop the existing stream: `GenServer.stop(:test_stream)`
- Run the script again

**No messages appearing**
- Wait 10-30 seconds (sometimes takes a moment to start)
- Check status: `Signal.Alpaca.Stream.status(:test_stream)`
- Should see status change: `:connecting` → `:connected` → `:authenticated` → `:subscribed`

### Notes

- The test stream is available 24/7, even outside market hours
- Only use the `FAKEPACA` symbol with the test stream
- Real market data requires the production stream endpoint
- The script temporarily overrides the WebSocket URL configuration to use the test endpoint
