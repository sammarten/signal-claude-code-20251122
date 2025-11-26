# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Signal** is a real-time day trading system built with Elixir/Phoenix that streams market data from Alpaca Markets, performs technical analysis, generates trading signals, and will eventually execute trades. The system uses event sourcing architecture with TimescaleDB for time-series data storage.

**Current Status**: Phase 1 (Core Infrastructure) complete. Phase 2 (Technical Analysis) in progress.

## Common Commands

### Development

```bash
# Start the Phoenix server
mix phx.server

# Start with IEx console (recommended)
iex -S mix phx.server

# Load environment variables first (required for Alpaca API)
source .env
```

### Database

```bash
# Create and migrate database
mix ecto.create
mix ecto.migrate

# Reset database (drop, create, migrate, seed)
mix ecto.reset

# Test environment database operations
MIX_ENV=test mix ecto.drop
MIX_ENV=test mix ecto.create
MIX_ENV=test mix ecto.migrate
```

### Testing

```bash
# Run all tests (excludes integration tests by default)
mix test

# Run a specific test file
mix test test/signal/bar_cache_test.exs

# Run a specific test by line number
mix test test/signal/bar_cache_test.exs:42

# Run integration tests (requires Alpaca credentials)
mix test --include integration

# Run tests with coverage
mix test --cover

# Run only database-tagged tests
mix test --only database
```

### Code Quality

```bash
# Format code
mix format

# Check compilation with warnings as errors
mix compile --warnings-as-errors

# Run precommit checks (compile, format, test)
mix precommit
```

### Historical Data Loading

```bash
# Load most recent year (fastest validation)
mix signal.load_data --year 2024

# Load specific year (recommended incremental approach)
mix signal.load_data --year 2023

# Load specific symbols only
mix signal.load_data --symbols AAPL,TSLA,NVDA

# Load all 5 years of data (takes 2-4 hours)
mix signal.load_data

# Check data coverage without downloading
mix signal.load_data --check-only
```

### Gap Filling

```bash
# Check and fill gaps for all configured symbols
mix signal.fill_gaps

# Check and fill gaps for specific symbols
mix signal.fill_gaps --symbols AAPL,TSLA,NVDA

# Check for gaps without filling (dry run)
mix signal.fill_gaps --check-only

# Set maximum gap size to fill (in minutes, default: 1440 = 24 hours)
mix signal.fill_gaps --max-gap 720
```

**Automatic Gap Filling**: The system automatically detects and fills data gaps when the WebSocket stream reconnects (e.g., after computer sleep or network interruption). Gaps up to 24 hours are filled automatically. For larger gaps, use the manual commands above or `mix signal.load_data`.

## Architecture Overview

### Core Data Flow

```
Alpaca Markets (WebSocket)
    ↓
Signal.Alpaca.Stream (WebSocket client)
    ↓
Signal.Alpaca.StreamHandler (processes messages)
    ↓
    ├─→ Signal.BarCache (ETS - O(1) lookup for latest data)
    ├─→ Phoenix.PubSub (broadcasts to subscribers)
    └─→ Signal.Repo (persists to TimescaleDB)
```

### Key Architectural Concepts

**BarCache (ETS Table)**

- In-memory storage for latest quotes and bars
- O(1) lookups by symbol
- Managed by GenServer with public ETS table
- Survives across data pipeline restarts
- Always query BarCache for current prices, not the database

**PubSub Event Broadcasting**

- All real-time events published to Phoenix.PubSub topics
- Topic naming: `"bars:{symbol}"`, `"quotes:{symbol}"`, `"levels:{symbol}"`
- Modules subscribe to topics they need (e.g., strategies subscribe to bar updates)
- LiveView components auto-update via PubSub subscriptions

**Event Sourcing Pattern**

- `events` table stores all significant system events as JSONB
- Append-only log with event_type, stream_id, version
- Used for audit trail and potential event replay
- Never delete events, only add new ones

**TimescaleDB Hypertables**

- `market_bars` is a hypertable partitioned by time
- Automatic compression after 7 days (saves ~80% space)
- Retention policy: 5+ years of minute-bar data
- Always use UTC for storage, convert to ET for display

**Conditional Supervision Tree**

- BarCache, Monitor, and AlpacaStream can be disabled via config
- Test environment disables these by default (see `config/test.exs`)
- Use `start_bar_cache: false` in test config to prevent ETS conflicts

**Mock Stream for Development**

- Set `use_mock_stream: true` in config to simulate market data
- No Alpaca credentials required when using mock stream
- Generates realistic fake data for all configured symbols
- Perfect for testing UI and strategies without live connection

## Module Organization

### Phase 1 Modules (Complete)

**`Signal.Alpaca.*`** - Alpaca Markets integration

- `Client` - REST API calls (account info, historical data)
- `Stream` - WebSocket client (GenServer)
- `StreamHandler` - Message processing callbacks, triggers automatic gap filling on reconnect
- `StreamSupervisor` - Supervises Stream with restart strategy
- `MockStream` - Fake data generator for development
- `Config` - API credentials and endpoint configuration

**`Signal.MarketData.*`** - Market data domain

- `Bar` - Ecto schema for minute bars (OHLCV)
- `HistoricalLoader` - Bulk loading of historical data (years at a time)
- `GapFiller` - Detects and fills small gaps in real-time data (up to 24 hours)
- `Verifier` - Data quality checks and gap detection

**`Signal.BarCache`** - ETS-based in-memory cache

- GenServer managing ETS table for latest quotes/bars
- `get/1`, `update_bar/1`, `update_quote/1` public API
- `current_price/1` - smart price lookup (quote → bar fallback)

**`Signal.Monitor`** - System health monitoring

- Tracks message rates, connection status, errors
- Anomaly detection for unusual patterns
- Reports stats every 60 seconds via PubSub

### Phase 2 Modules (In Progress)

**`Signal.Technicals.*`** - Technical analysis

- `Levels` - Key level calculation (PDH/PDL, PMH/PML, opening ranges)
- `Swings` - Swing high/low detection (configurable lookback)
- `StructureDetector` - BOS (Break of Structure) and ChoCh detection
- `MarketStructure` - Ecto schema for storing structure data
- `KeyLevels` - Ecto schema for daily reference levels

### Database Schemas

**`market_bars`** (TimescaleDB hypertable)

- Primary key: `(symbol, bar_time)`
- Columns: symbol, bar_time, open, high, low, close, volume, vwap
- Partitioned by bar_time, compressed after 7 days
- Use date range queries for efficient scans

**`events`** (Event sourcing log)

- Unique constraint: `(stream_id, version)`
- Columns: event_type, stream_id, version, data (JSONB), inserted_at
- Append-only, never update or delete

**`key_levels`** (Phase 2)

- Primary key: `(symbol, date)`
- Stores daily reference levels for trading strategies
- Updated incrementally (PDH/PDL at 4am, opening ranges at 9:35/9:45)

**`market_structure`** (Phase 2)

- Primary key: `(symbol, timeframe, bar_time)`
- Stores swing points, BOS, ChoCh detections
- Used for strategy confluence analysis

## Testing Patterns

### Test Environment Setup

Tests automatically:

- Create/migrate test database
- Disable BarCache, Monitor, AlpacaStream supervision
- Use in-memory data structures where possible

### Test Organization

```elixir
# Unit tests - no external dependencies
describe "some_function/2" do
  test "calculates correctly with valid input" do
    # Arrange, Act, Assert
  end
end

# Database tests - require Repo
@tag :database
test "stores levels correctly" do
  # Insert test data, query, assert
end

# Integration tests - require Alpaca API
@tag :integration
test "fetches real market data" do
  # Requires ALPACA_API_KEY_ID and ALPACA_API_SECRET_KEY
end
```

### Common Test Helpers

```elixir
# Create test bars
defp create_test_bars(count) do
  Enum.map(1..count, fn i ->
    %Signal.MarketData.Bar{
      symbol: "AAPL",
      bar_time: ~U[2024-11-23 14:30:00Z],
      high: Decimal.new("175.#{i}"),
      low: Decimal.new("174.#{i}"),
      open: Decimal.new("175.00"),
      close: Decimal.new("175.20"),
      volume: 1000
    }
  end)
end

# Database cleanup in tests
setup do
  :ok = Ecto.Adapters.SQL.Sandbox.checkout(Signal.Repo)
  on_exit(fn -> :ok end)
end
```

## Time Zone Handling

**Critical Rule**: Store UTC everywhere, display ET only in UI

**Storage (Always UTC)**

- Database timestamps: `TIMESTAMPTZ` (stored as UTC)
- BarCache: All DateTime values in UTC
- Events: All timestamps in UTC
- Alpaca API: Returns UTC timestamps

**Display (ET for UI)**

- Dashboard: Convert to `"America/New_York"` before rendering
- Market hours calculations: Use ET (9:30 AM - 4:00 PM ET)
- Logs and reports: Show ET for human readability

**Implementation**

```elixir
# Store in UTC
bar_time = ~U[2024-11-15 14:30:00Z]

# Display in ET
et_time = DateTime.shift_zone!(bar_time, "America/New_York")
```

## Common Patterns

### Querying Recent Bars

```elixir
# Get bars from the last N minutes
def get_recent_bars(symbol, minutes) do
  cutoff = DateTime.add(DateTime.utc_now(), -minutes * 60, :second)

  from(b in Bar,
    where: b.symbol == ^symbol,
    where: b.bar_time >= ^cutoff,
    order_by: [asc: b.bar_time]
  )
  |> Repo.all()
end
```

### Broadcasting Events

```elixir
# Broadcast to symbol-specific topic
Phoenix.PubSub.broadcast(
  Signal.PubSub,
  "bars:#{symbol}",
  {:bar_update, bar}
)

# Broadcast to global topic
Phoenix.PubSub.broadcast(
  Signal.PubSub,
  "market:all",
  {:signal_generated, signal}
)
```

### BarCache Lookups

```elixir
# Get latest bar for a symbol
{:ok, bar} = Signal.BarCache.get(:AAPL)

# Get current price (tries quote first, falls back to bar)
{:ok, price} = Signal.BarCache.current_price(:AAPL)

# Update cache (called by StreamHandler)
Signal.BarCache.update_bar(bar)
Signal.BarCache.update_quote(quote)
```

## Configuration

### Symbol Configuration

Edit `config/dev.exs`:

```elixir
config :signal,
  symbols: ["AAPL", "TSLA", "NVDA", "SPY", "QQQ"],
  market_open: ~T[09:30:00],
  market_close: ~T[16:00:00],
  timezone: "America/New_York"
```

After changing symbols, restart the server to reconnect WebSocket with new subscriptions.

### Environment Variables

Required for production/development with real data:

```bash
export ALPACA_API_KEY_ID="your_key_here"
export ALPACA_API_SECRET_KEY="your_secret_here"
export ALPACA_BASE_URL="https://paper-api.alpaca.markets"
export ALPACA_WS_URL="wss://stream.data.alpaca.markets/v2/sip"
```

For development without credentials:

```elixir
# config/dev.exs
config :signal, use_mock_stream: true
```

## Project Roadmap

**Phase 1 (Complete)**: Core Infrastructure

- Real-time market data streaming
- TimescaleDB integration with hypertables
- LiveView dashboard
- Historical data loading
- System monitoring

**Phase 2 (Current)**: Technical Analysis

- Market structure detection (BOS, ChoCh, swings)
- Key level tracking (PDH/PDL, opening ranges)
- PD Arrays (Order Blocks, Fair Value Gaps)
- Strategy signals with confluence scoring

**Phase 3 (Planned)**: Backtesting & Paper Trading

- Historical signal generation
- Strategy performance metrics
- Trade simulation engine
- Paper trading with Alpaca

**Phase 4 (Future)**: Live Trading

- Order execution
- Position management
- Risk management
- Trade journal

## Development Workflow

### Adding a New Technical Analysis Module

1. Create module in `lib/signal/technicals/`
2. Write comprehensive tests in `test/signal/technicals/`
3. If storing data, create migration and Ecto schema
4. If subscribing to events, add PubSub subscription in `init/1`
5. If running continuously, add to supervision tree in `application.ex`
6. Update this CLAUDE.md with module description

### Adding a New Database Table

1. Generate migration: `mix ecto.gen.migration create_table_name`
2. Define schema with proper indexes
3. For time-series data, consider TimescaleDB hypertable
4. Create Ecto schema in `lib/signal/*/schema_name.ex`
5. Add schema tests in `test/signal/schema_test.exs`

### Adding Real-Time Features to LiveView

1. Subscribe to PubSub topics in `mount/3`
2. Handle messages in `handle_info/2`
3. Update assigns and return `{:noreply, socket}`
4. LiveView automatically pushes updates to client
5. No JavaScript required for simple real-time updates

## Common Pitfalls

**Don't query the database for current prices** - Use BarCache instead

- Database has historical data, BarCache has latest prices
- Database queries are slower and unnecessary for real-time

**Don't mix time zones** - Always store UTC

- Convert to ET only for display purposes
- Market hours logic uses ET but store timestamps as UTC

**Don't forget to broadcast events** - Other modules depend on PubSub

- After updating BarCache, broadcast to PubSub
- After generating signals, broadcast to PubSub
- LiveView won't update without broadcasts

**Don't use `String.to_atom/1` on user input** - Atoms aren't garbage collected

- Use existing atoms or `String.to_existing_atom/1`
- Symbol strings stay as strings, only convert to atoms internally

**Test with realistic data** - Edge cases matter in trading

- Test with gaps in data (missing bars)
- Test with extreme prices (prevent divide by zero)
- Test timezone boundaries (market open/close)
- Test weekend/holiday dates

## Decimal Precision

**Always use `Decimal` for prices, never floats**

```elixir
# Good
price = Decimal.new("175.50")
result = Decimal.add(price, Decimal.new("1.00"))

# Bad - loses precision
price = 175.50
result = price + 1.00
```

Financial calculations require exact decimal precision. Floats have rounding errors that accumulate.

## MCP Servers

### context7

Always use context7 when I need code generation, setup or configuration steps, or
library/API documentation. This means you should automatically use the Context7 MCP
tools to resolve library id and get library docs without me having to explicitly ask.

## Additional Resources

- **Project Docs**: See `docs/` directory for detailed Phase 1 and Phase 2 plans
- **README.md**: Setup instructions and troubleshooting guide
- **Alpaca API Docs**: https://docs.alpaca.markets
- **Phoenix LiveView Guide**: https://hexdocs.pm/phoenix_live_view
- **TimescaleDB Docs**: https://docs.timescale.com
