# Signal Trading System - Comprehensive Training Plan

**Purpose**: Help you understand the Signal trading system you've built, including features, architecture, data flow, and module responsibilities.

**Duration**: Self-paced (recommend 3-4 hours initial study, then reference as needed)

---

## Table of Contents

1. [System Overview](#system-overview)
2. [Architecture & Data Flow](#architecture--data-flow)
3. [Project Structure](#project-structure)
4. [Phase 1: Core Infrastructure (COMPLETE)](#phase-1-core-infrastructure-complete)
5. [Phase 2: Technical Analysis (IN PROGRESS)](#phase-2-technical-analysis-in-progress)
6. [Module Responsibilities](#module-responsibilities)
7. [Key Concepts](#key-concepts)
8. [Data Flow Examples](#data-flow-examples)
9. [Development Workflow](#development-workflow)
10. [Testing Strategy](#testing-strategy)
11. [Quick Reference](#quick-reference)

---

## System Overview

### What is Signal?

Signal is a **real-time day trading system** built with Elixir/Phoenix that:

- Streams live market data from Alpaca Markets (WebSocket)
- Performs technical analysis on price action
- Generates trading signals based on break & retest strategies
- Will eventually execute automated trades

### Current Status

- **Phase 1: COMPLETE** ✅ - Core infrastructure, real-time streaming, dashboard
- **Phase 2: IN PROGRESS** 🔨 - Technical analysis, market structure detection
- **Phase 3: PLANNED** - Backtesting, paper trading
- **Phase 4: PLANNED** - Live automated trading

### Key Features

**Real-Time Data (Phase 1)**

- WebSocket connection to Alpaca Markets
- Streams quotes, bars (OHLCV), and trades
- 17 symbols tracked (12 tech stocks + 5 ETFs)
- Updates dashboard in real-time via LiveView

**Historical Data (Phase 1)**

- 5 years of minute-bar data (7.4M bars)
- TimescaleDB hypertable with compression (~75% space savings)
- Incremental year-by-year loading
- Data quality verification

**Technical Analysis (Phase 2)**

- Key level tracking (PDH/PDL, PMH/PML, Opening Range)
- Swing detection (highs and lows)
- Market structure (BOS, ChoCh, trend)
- PD Arrays (Order Blocks, Fair Value Gaps) - planned
- Break & retest pattern detection - planned

**System Monitoring (Phase 1)**

- Health metrics (quotes/sec, bars/min)
- Connection status tracking
- Anomaly detection
- Database health checks

---

## Architecture & Data Flow

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                   PRESENTATION LAYER                        │
│  ┌────────────────────────────────────────────────┐         │
│  │  Phoenix LiveView Dashboard                    │         │
│  │  - Market Data Table                           │         │
│  │  - System Stats                                │         │
│  │  - Real-time Price Updates                     │         │
│  └────────────────────────────────────────────────┘         │
└───────────────────────┬─────────────────────────────────────┘
                        │
                        ↓
┌─────────────────────────────────────────────────────────────┐
│                   EVENT DISTRIBUTION                         │
│  ┌────────────────────────────────────────────────┐         │
│  │  Phoenix.PubSub                                 │         │
│  │  - bars:{symbol}                                │         │
│  │  - quotes:{symbol}                              │         │
│  │  - alpaca:connection                            │         │
│  │  - system:stats                                 │         │
│  │  - levels:{symbol}                              │         │
│  └────────────────────────────────────────────────┘         │
└───────────────────────┬─────────────────────────────────────┘
                        │
                        ↓
┌─────────────────────────────────────────────────────────────┐
│                   BUSINESS LOGIC LAYER                       │
│  ┌────────────┬──────────────┬────────────┬──────────────┐  │
│  │  BarCache  │   Monitor    │  Levels    │  Swings      │  │
│  │    (ETS)   │  (Metrics)   │(Key Levels)│ (Detection)  │  │
│  └────────────┴──────────────┴────────────┴──────────────┘  │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  StreamHandler (processes incoming messages)         │    │
│  └─────────────────────────────────────────────────────┘    │
└───────────────────────┬─────────────────────────────────────┘
                        │
                        ↓
┌─────────────────────────────────────────────────────────────┐
│                   DATA INTEGRATION LAYER                     │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  Alpaca.Stream (WebSocket Client)                    │    │
│  └─────────────────────────────────────────────────────┘    │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  Alpaca.Client (REST API)                            │    │
│  └─────────────────────────────────────────────────────┘    │
└───────────────────────┬─────────────────────────────────────┘
                        │
                        ↓
┌─────────────────────────────────────────────────────────────┐
│                   EXTERNAL SERVICES                          │
│  ┌──────────────────┐      ┌─────────────────────────┐      │
│  │ Alpaca Markets   │      │     TimescaleDB         │      │
│  │ (Market Data)    │      │ (Historical Storage)    │      │
│  └──────────────────┘      └─────────────────────────┘      │
└─────────────────────────────────────────────────────────────┘
```

### Data Flow (Real-Time)

**1. Market Data Arrives**

```
Alpaca WebSocket → Stream.ex receives JSON
```

**2. Message Processing**

```
Stream.ex normalizes message → Calls StreamHandler.handle_message/2
```

**3. StreamHandler Distribution**

```
StreamHandler.handle_message/2:
  ├─→ Updates BarCache (ETS)
  ├─→ Broadcasts to PubSub topics
  └─→ Tracks metrics via Monitor
```

**4. Consumption**

```
PubSub broadcasts:
  ├─→ LiveView (updates dashboard)
  ├─→ Levels module (calculates key levels)
  └─→ Strategy evaluators (generates signals) - Phase 2
```

### Data Flow (Historical Loading)

**1. User Initiates Load**

```
mix signal.load_data --year 2024
```

**2. Historical Loader**

```
HistoricalLoader:
  ├─→ Queries existing data (detect gaps)
  ├─→ Fetches from Alpaca.Client (REST API)
  ├─→ Converts to Bar schemas
  ├─→ Batch inserts (1000 bars at a time)
  └─→ Stores in TimescaleDB
```

**3. Verification**

```
Verifier.verify_symbol("AAPL"):
  ├─→ Checks OHLC relationships
  ├─→ Detects data gaps
  └─→ Generates quality report
```

---

## Project Structure

```
signal/
├── lib/
│   ├── signal/
│   │   ├── alpaca/                    # Alpaca Markets integration
│   │   │   ├── client.ex              # REST API client
│   │   │   ├── stream.ex              # WebSocket client
│   │   │   ├── stream_handler.ex      # Message processor
│   │   │   ├── stream_supervisor.ex   # Supervision
│   │   │   ├── mock_stream.ex         # Development mock
│   │   │   └── config.ex              # API credentials
│   │   │
│   │   ├── market_data/               # Market data domain
│   │   │   ├── bar.ex                 # OHLCV schema
│   │   │   ├── historical_loader.ex   # Bulk loading
│   │   │   └── verifier.ex            # Data quality
│   │   │
│   │   ├── technicals/                # Technical analysis (Phase 2)
│   │   │   ├── levels.ex              # Key levels (PDH/PDL, etc.)
│   │   │   ├── swings.ex              # Swing detection
│   │   │   ├── structure_detector.ex  # BOS/ChoCh detection
│   │   │   └── key_levels.ex          # Ecto schema
│   │   │
│   │   ├── strategies/                # Trading strategies (Phase 2)
│   │   │   ├── break_and_retest.ex    # Break & retest detector
│   │   │   └── opening_range.ex       # Opening range breakout
│   │   │
│   │   ├── bar_cache.ex               # ETS cache (O(1) lookups)
│   │   ├── monitor.ex                 # System monitoring
│   │   ├── repo.ex                    # Database connection
│   │   └── application.ex             # Supervision tree
│   │
│   └── signal_web/
│       ├── live/
│       │   ├── market_live.ex         # Market dashboard
│       │   └── components/
│       │       └── system_stats.ex    # System health display
│       ├── router.ex
│       └── endpoint.ex
│
├── test/
│   ├── signal/
│   │   ├── alpaca/
│   │   ├── market_data/
│   │   ├── technicals/
│   │   ├── integration_test.exs       # End-to-end tests
│   │   └── schema_test.exs
│   └── support/
│       └── test_callback.ex
│
├── priv/
│   └── repo/
│       └── migrations/                # Database migrations
│
├── config/
│   ├── dev.exs                        # Development config
│   ├── test.exs                       # Test config
│   └── runtime.exs                    # Production config
│
├── docs/                              # Project documentation
│   ├── PHASE_1_SUMMARY.md
│   ├── PROJECT_PLAN_PHASE_1.md
│   ├── PROJECT_PLAN_PHASE_2.md
│   ├── TASK_1_WORK_ORDERS.md
│   └── TESTING_TECHNICALS.md
│
├── CLAUDE.md                          # AI assistant context
├── AGENTS.md                          # Phoenix framework rules
├── README.md                          # Setup and usage guide
├── docker-compose.yml                 # TimescaleDB setup
└── .env                               # API credentials (gitignored)
```

---

## Phase 1: Core Infrastructure (COMPLETE)

### What Was Built

**1. TimescaleDB Hypertables**

- `market_bars` - 1-minute OHLCV data with compression
- `events` - Event sourcing log (for future phases)
- Automatic compression after 7 days (~75% space savings)
- 6-year retention policy

**2. Real-Time Data Pipeline**

- WebSocket client (`Alpaca.Stream`) with auto-reconnect
- Message normalization (quotes, bars, trades → Elixir structs)
- Quote deduplication (reduces noise by 30-40%)
- Error handling with exponential backoff

**3. BarCache (ETS)**

- In-memory cache for latest quotes and bars
- O(1) lookups by symbol
- Public ETS table with read concurrency
- `current_price/1` calculates mid-point from bid/ask

**4. System Monitor**

- Tracks message rates (quotes/sec, bars/min)
- Connection uptime and health
- Database connectivity checks
- Anomaly detection (zero messages, excessive reconnects)
- Reports every 60 seconds via PubSub

**5. LiveView Dashboard**

- Real-time price table (17 symbols)
- Color-coded price changes (green ↑, red ↓)
- Connection status badge
- System health metrics
- Relative timestamps ("3s ago")

**6. Historical Data Loading**

- Year-by-year incremental loading (resumable)
- Batch inserts (1000 bars at a time)
- Parallel loading (5 symbols concurrently)
- Coverage checking (avoid duplicates)
- Data verification (OHLC validation, gap detection)

**7. Mock Stream**

- Develop without API credentials
- Random walk price generation
- Realistic fake data for all symbols

### Key Achievements

- **7.4M bars** of historical data (5 years, 17 symbols)
- **~150-200 MB** compressed storage (from ~740 MB)
- **66 unit tests** + integration suite
- **Production-ready** documentation

---

## Phase 2: Technical Analysis (IN PROGRESS)

### What's Being Built

**Task 1: Market Structure & Key Levels** ⭐ Current Focus

**1. Key Levels Module** (`Signal.Technicals.Levels`)

- Previous Day High/Low (PDH/PDL)
- Premarket High/Low (PMH/PML)
- Opening Range High/Low (5min, 15min)
- Psychological levels (whole/half numbers)
- Level break detection

**2. Swing Detection** (`Signal.Technicals.Swings`)

- Swing high = high > N bars before/after (N=2 default)
- Swing low = low < N bars before/after
- Configurable lookback period
- Latest swing retrieval

**3. Market Structure** (`Signal.Technicals.StructureDetector`)

- Break of Structure (BOS) - trend continuation
- Change of Character (ChoCh) - trend reversal
- Trend determination (bullish/bearish/ranging)
- Structure strength (strong/weak)

**Future Tasks (Phase 2)**

**Task 2: PD Arrays**

- Fair Value Gaps (FVGs)
- Order Blocks
- Mitigation tracking

**Task 3: Strategy Engine**

- Break & retest detector
- Opening range breakout
- One candle rule

**Task 4: Signal Generation**

- Confluence analyzer (scoring)
- Signal storage and broadcasting
- Quality grading (A-F)

**Task 5: Dashboard Integration**

- Signals LiveView
- Setup visualization
- Performance metrics

**Task 6: Background Processing**

- Strategy evaluator (GenServer)
- Level calculator scheduler
- Continuous evaluation

---

## Module Responsibilities

### Phase 1 Modules

#### `Signal.Alpaca.Stream` (601 lines)

**Purpose**: WebSocket client for real-time market data

**Responsibilities**:

- Maintain persistent WebSocket connection
- Handle authentication and subscription protocol
- Normalize incoming messages (JSON → Elixir structs)
- Auto-reconnect with exponential backoff (1s → 60s max)
- Deliver messages to callback module

**Key Functions**:

- `start_link/1` - Start WebSocket client
- `subscribe/2` - Add symbol subscriptions
- `status/1` - Get connection status

**Data Flow**:

```
Alpaca WebSocket → Stream receives JSON
                 → Parse and normalize
                 → Call StreamHandler.handle_message/2
```

---

#### `Signal.Alpaca.StreamHandler` (236 lines)

**Purpose**: Process incoming WebSocket messages

**Responsibilities**:

- Update BarCache with latest data
- Deduplicate unchanged quotes
- Broadcast to PubSub topics
- Track metrics via Monitor
- Periodic throughput logging (60s)

**Key Functions**:

- `handle_message/2` - Process normalized messages

**Deduplication Logic**:

```elixir
# Only process if bid or ask changed
if price_changed?(quote, previous_quote) do
  update_cache_and_broadcast(quote)
end
```

---

#### `Signal.BarCache` (242 lines)

**Purpose**: In-memory ETS cache for latest market data

**Responsibilities**:

- Store latest bar and quote per symbol
- Provide O(1) lookup by symbol
- Calculate current mid-point price
- Atomic updates via GenServer

**Key Functions**:

- `get/1` - Get all cached data for symbol
- `get_bar/1` - Get latest bar
- `get_quote/1` - Get latest quote
- `current_price/1` - Calculate mid-point (bid+ask)/2 or bar close
- `update_bar/2` - Update bar atomically
- `update_quote/2` - Update quote atomically

**Data Structure**:

```elixir
# ETS key: symbol (atom)
# ETS value:
%{
  last_bar: %{
    open: Decimal, high: Decimal, low: Decimal, close: Decimal,
    volume: integer, timestamp: DateTime
  },
  last_quote: %{
    bid_price: Decimal, ask_price: Decimal,
    bid_size: integer, ask_size: integer,
    timestamp: DateTime
  }
}
```

---

#### `Signal.Monitor` (351 lines)

**Purpose**: System health monitoring

**Responsibilities**:

- Track message rates (quotes/sec, bars/min, trades/sec)
- Monitor connection status and uptime
- Check database health (SELECT 1 query)
- Detect anomalies (zero messages, excessive reconnects)
- Log summaries every 60s
- Broadcast stats via PubSub

**Key Functions**:

- `track_message/1` - Record message received
- `track_error/1` - Record error
- `track_connection/1` - Update connection status
- `get_stats/0` - Get current statistics

**Anomaly Detection**:

- Zero message rates during market hours → Warning
- Reconnect count > 10/hour → Error
- Disconnected > 5 minutes → Alert
- Database unhealthy → Error

---

#### `Signal.Alpaca.Client` (479 lines)

**Purpose**: REST API client for historical data

**Responsibilities**:

- Fetch historical bars (with pagination)
- Get latest bar/quote/trade
- Account and order endpoints (Phase 3)
- Rate limiting with exponential backoff
- Parse responses (DateTime, Decimal)

**Key Functions**:

- `get_bars/2` - Historical bars with date range
- `get_latest_bar/1` - Most recent bar
- `get_account/0` - Account information
- `place_order/1` - Submit order (Phase 3)

**Pagination**:

- Max 10,000 bars per request
- Automatic pagination up to 100 pages
- Respects 200 requests/min rate limit

---

#### `Signal.MarketData.HistoricalLoader` (365 lines)

**Purpose**: Bulk loading of historical data

**Responsibilities**:

- Load bars year by year (resumable)
- Check existing coverage (avoid duplicates)
- Batch inserts (1000 bars at a time)
- Parallel loading (5 symbols max)
- Progress logging
- Retry logic (3 attempts, 5s delay)

**Key Functions**:

- `load_bars/3` - Load bars for symbols and date range
- `load_all/2` - Load all configured symbols
- `check_coverage/2` - Query existing data

**Loading Strategy**:

```elixir
For each symbol:
  1. Query existing data (find loaded years)
  2. For each missing year:
     - Fetch from Alpaca (with pagination)
     - Convert to Bar structs
     - Batch insert (1000 at a time)
     - Log: "AAPL: 2020 complete (98,234 bars)"
```

---

#### `Signal.MarketData.Verifier` (323 lines)

**Purpose**: Data quality verification

**Responsibilities**:

- Validate OHLC relationships (high ≥ open/close, low ≤ open/close)
- Detect gaps during market hours
- Count duplicates (should be 0)
- Calculate statistics (bar counts, date ranges)
- Generate coverage reports

**Key Functions**:

- `verify_symbol/1` - Comprehensive verification report
- `verify_all/0` - Verify all configured symbols

**Quality Checks**:

1. OHLC violations
2. Data gaps (missing minutes)
3. Duplicate bars
4. Coverage percentage

---

### Phase 2 Modules (New)

#### `Signal.Technicals.Levels`

**Purpose**: Calculate and track daily reference levels

**Responsibilities**:

- Calculate PDH/PDL from previous day
- Calculate PMH/PML from premarket (4:00-9:30 AM)
- Calculate Opening Ranges (5min, 15min)
- Detect level breaks
- Find psychological levels (whole/half numbers)

**Key Functions**:

- `calculate_daily_levels/2` - Compute all levels for date
- `get_current_levels/1` - Retrieve today's levels
- `update_opening_range/3` - Calculate OR after 9:35/9:45 AM
- `level_broken?/3` - Detect if price broke level
- `find_nearest_psychological/1` - Round to whole/half/quarter

**Database Schema**: `key_levels` table

---

#### `Signal.Technicals.Swings`

**Purpose**: Detect swing highs and swing lows

**Responsibilities**:

- Identify swing points (N bars before/after check)
- Support configurable lookback period
- Return swing metadata (price, index, timestamp)

**Key Functions**:

- `identify_swings/2` - Find all swings in bar series
- `swing_high?/3` - Check if bar is swing high
- `swing_low?/3` - Check if bar is swing low
- `get_latest_swing/2` - Get most recent swing high/low

**Algorithm**:

```elixir
# Swing High: current.high > all(before.high) AND all(after.high)
# Swing Low: current.low < all(before.low) AND all(after.low)
# Default lookback: 2 bars
```

---

#### `Signal.Technicals.StructureDetector`

**Purpose**: Detect Break of Structure and Change of Character

**Responsibilities**:

- Determine trend (bullish/bearish/ranging)
- Detect BOS (trend continuation)
- Detect ChoCh (trend reversal)
- Classify structure strength (strong/weak)

**Key Functions**:

- `analyze/2` - Comprehensive structure analysis
- `detect_bos/3` - Break of Structure detection
- `detect_choch/3` - Change of Character detection
- `determine_trend/2` - Trend from swing pattern
- `get_structure_state/1` - Strong/weak classification

**Concepts**:

- **Bullish Trend**: Higher highs + higher lows
- **Bearish Trend**: Lower highs + lower lows
- **BOS**: Price breaks previous swing in trend direction
- **ChoCh**: Price breaks opposite swing (reversal signal)

---

## Key Concepts

### Time Zone Handling

**Critical Rule**: Store UTC everywhere, display ET only in UI

**Storage (Always UTC)**:

- Database timestamps: `TIMESTAMPTZ` (stored as UTC)
- BarCache: All DateTime values in UTC
- Events: All timestamps in UTC
- Alpaca API: Returns UTC timestamps

**Display (ET for UI)**:

- Dashboard: Convert to `"America/New_York"` before rendering
- Market hours: 9:30 AM - 4:00 PM ET
- Logs and reports: Show ET for human readability

**Implementation**:

```elixir
# Store in UTC
bar_time = ~U[2024-11-23 14:30:00Z]

# Display in ET
et_time = DateTime.shift_zone!(bar_time, "America/New_York")
```

### Decimal Precision

**Always use `Decimal` for prices, never floats**

```elixir
# Good
price = Decimal.new("175.50")
result = Decimal.add(price, Decimal.new("1.00"))

# Bad - loses precision
price = 175.50
result = price + 1.00
```

Financial calculations require exact decimal precision. Floats have rounding errors.

### Event Sourcing

**Pattern**: Append-only log of all significant events

**`events` table**:

- `event_type` - Type of event (e.g., "SignalGenerated")
- `stream_id` - Aggregate ID (e.g., "AAPL-2024-11-23")
- `version` - Event sequence number
- `payload` - JSONB event data
- Unique constraint on `(stream_id, version)` for optimistic locking

**Usage**: Phase 2+ for trading signals, orders, positions

### PubSub Topics

**Pattern**: Symbol-specific and global topics

**Naming Convention**:

- `"bars:{symbol}"` - Bar updates (e.g., "bars:AAPL")
- `"quotes:{symbol}"` - Quote updates
- `"levels:{symbol}"` - Key level updates
- `"signals:{symbol}"` - Trading signals (Phase 2)
- `"alpaca:connection"` - Connection status
- `"system:stats"` - System metrics

**Message Format**: Tuples for pattern matching

```elixir
{:bar, "AAPL", %{open: ..., high: ..., ...}}
{:quote, "AAPL", %{bid_price: ..., ask_price: ..., ...}}
{:levels_updated, "AAPL", %KeyLevels{}}
```

### Supervision Tree

**Correct Dependency Order** (from `application.ex`):

```elixir
children = [
  Signal.Repo,                       # Database first
  {Phoenix.PubSub, name: Signal.PubSub},  # PubSub before consumers
  Signal.BarCache,                   # Cache before StreamHandler
  Signal.Monitor,                    # Monitor before StreamHandler
  Signal.Alpaca.StreamSupervisor,    # Stream last (depends on all above)
  SignalWeb.Endpoint                 # Web last
]
```

**Why this order?**

- StreamHandler needs PubSub, BarCache, and Monitor
- Must start dependencies before consumers

---

## Data Flow Examples

### Example 1: Real-Time Quote Update

**1. Alpaca sends quote:**

```json
[
  {
    "T": "q",
    "S": "AAPL",
    "bp": 175.5,
    "ap": 175.52,
    "bs": 100,
    "as": 200,
    "t": "2024-11-23T14:30:00.123456Z"
  }
]
```

**2. Stream.ex receives and normalizes:**

```elixir
%{
  type: :quote,
  symbol: "AAPL",
  bid_price: Decimal.new("175.50"),
  ask_price: Decimal.new("175.52"),
  bid_size: 100,
  ask_size: 200,
  timestamp: ~U[2024-11-23 14:30:00.123456Z]
}
```

**3. StreamHandler.handle_message/2 processes:**

```elixir
# Check if price changed (deduplication)
if quote_changed?(quote, state.last_quotes["AAPL"]) do
  # Update BarCache
  BarCache.update_quote(:AAPL, quote)

  # Broadcast to PubSub
  Phoenix.PubSub.broadcast(Signal.PubSub, "quotes:AAPL", {:quote, "AAPL", quote})

  # Track metric
  Monitor.track_message(:quote)

  # Update state
  {:ok, %{state | last_quotes: Map.put(state.last_quotes, "AAPL", quote)}}
end
```

**4. LiveView receives PubSub message:**

```elixir
def handle_info({:quote, "AAPL", quote}, socket) do
  # Calculate new price
  new_price = Decimal.div(Decimal.add(quote.bid_price, quote.ask_price), 2)

  # Update assigns
  socket = update(socket, :symbol_data, fn data ->
    Map.update!(data, :AAPL, fn symbol_data ->
      %{symbol_data |
        current_price: new_price,
        bid: quote.bid_price,
        ask: quote.ask_price,
        last_update: quote.timestamp
      }
    end)
  end)

  {:noreply, socket}
end
```

**5. Dashboard updates in user's browser (automatic via LiveView)**

---

### Example 2: Level Calculation Flow

**Scenario**: Calculate opening range at 9:35 AM ET

**1. LevelCalculator scheduled job triggers:**

```elixir
# Runs at 9:35 AM ET
def calculate_opening_range_5m do
  symbols = Application.get_env(:signal, :symbols)
  today = Date.utc_today()

  for symbol <- symbols do
    Levels.update_opening_range(symbol, today, :five_min)
  end
end
```

**2. Levels.update_opening_range/3:**

```elixir
def update_opening_range(:AAPL, ~D[2024-11-23], :five_min) do
  # Query bars from 9:30:00 - 9:34:59 (5 bars)
  bars = get_opening_range_bars(:AAPL, ~D[2024-11-23], 5)

  # Calculate high/low
  {high, low} = calculate_high_low(bars)
  # high = 175.20, low = 174.60

  # Update existing KeyLevels record
  levels = get_levels_for_date(:AAPL, ~D[2024-11-23])
  updated = %{levels | opening_range_5m_high: high, opening_range_5m_low: low}

  # Store in database
  {:ok, stored} = Repo.update(updated)

  # Broadcast update
  Phoenix.PubSub.broadcast(Signal.PubSub, "levels:AAPL", {:levels_updated, :AAPL, stored})

  {:ok, stored}
end
```

**3. Strategy modules subscribe to "levels:AAPL":**

```elixir
def handle_info({:levels_updated, :AAPL, levels}, state) do
  # Check if opening range was just established
  if levels.opening_range_5m_high != nil do
    # Start watching for breakout
    evaluate_opening_range_breakout(:AAPL, levels)
  end

  {:noreply, state}
end
```

---

### Example 3: Swing Detection Flow

**Scenario**: Detect swings in last 100 bars

**1. Get bars from database:**

```elixir
bars = from(b in Bar,
         where: b.symbol == "AAPL",
         order_by: [asc: b.bar_time],
         limit: 100)
       |> Repo.all()
```

**2. Call Swings.identify_swings/2:**

```elixir
swings = Swings.identify_swings(bars, lookback: 2)
```

**3. Algorithm iterates through bars:**

```elixir
# For each bar from index 2 to 97 (need 2 bars before/after)
for idx <- 2..97 do
  bar = Enum.at(bars, idx)

  # Check swing high
  if swing_high?(bars, idx, 2) do
    # bar.high > all 2 bars before AND all 2 bars after
    swings = [%{type: :high, index: idx, price: bar.high, bar_time: bar.bar_time} | swings]
  end

  # Check swing low
  if swing_low?(bars, idx, 2) do
    # bar.low < all 2 bars before AND all 2 bars after
    swings = [%{type: :low, index: idx, price: bar.low, bar_time: bar.bar_time} | swings]
  end
end
```

**4. Return detected swings:**

```elixir
[
  %{type: :high, index: 15, price: Decimal.new("176.50"), bar_time: ~U[...]},
  %{type: :low, index: 28, price: Decimal.new("174.20"), bar_time: ~U[...]},
  %{type: :high, index: 42, price: Decimal.new("177.10"), bar_time: ~U[...]},
  # ...
]
```

**5. Structure analyzer uses swings:**

```elixir
# Determine trend
swing_highs = Enum.filter(swings, &(&1.type == :high))
swing_lows = Enum.filter(swings, &(&1.type == :low))

# Bullish if higher highs + higher lows
trend = if higher_highs?(swing_highs) and higher_lows?(swing_lows) do
  :bullish
else
  # check for bearish or ranging
end
```

---

## Development Workflow

### Starting the Application

```bash
# 1. Start TimescaleDB
docker-compose up -d

# 2. Load environment variables
source .env

# 3. Start Phoenix server
iex -S mix phx.server

# 4. Visit dashboard
open http://localhost:4000
```

### Common Development Tasks

**Load Historical Data:**

```bash
# Load most recent year (fastest validation)
mix signal.load_data --year 2024

# Load incremental (recommended)
mix signal.load_data --year 2023
mix signal.load_data --year 2022

# Load all 5 years (2-4 hours)
mix signal.load_data
```

**Testing:**

```bash
# Unit tests
mix test

# Integration tests (requires Alpaca credentials)
mix test --include integration

# Specific test file
mix test test/signal/bar_cache_test.exs
```

**Database:**

```bash
# Create and migrate
mix ecto.create
mix ecto.migrate

# Reset (drop, create, migrate)
mix ecto.reset

# Test environment
MIX_ENV=test mix ecto.drop
MIX_ENV=test mix ecto.create
MIX_ENV=test mix ecto.migrate
```

**Code Quality:**

```bash
# Format code
mix format

# Compile with warnings as errors
mix compile --warnings-as-errors

# Run precommit checks
mix precommit
```

### Interactive Testing (IEx)

**Check BarCache:**

```elixir
# Start IEx
iex -S mix phx.server

# Get cached data
Signal.BarCache.get(:AAPL)
# => {:ok, %{last_bar: %{...}, last_quote: %{...}}}

# Get current price
Signal.BarCache.current_price(:AAPL)
# => {:ok, #Decimal<175.51>}

# List all cached symbols
Signal.BarCache.all_symbols()
# => [:AAPL, :TSLA, :NVDA, ...]
```

**Check Monitor Stats:**

```elixir
Signal.Monitor.get_stats()
# => %{
#   quotes_per_sec: 137,
#   bars_per_min: 25,
#   uptime_seconds: 9240,
#   db_healthy: true,
#   ...
# }
```

**Check Stream Status:**

```elixir
Signal.Alpaca.Stream.status(Signal.Alpaca.Stream)
# => :subscribed

Signal.Alpaca.Stream.subscriptions(Signal.Alpaca.Stream)
# => %{bars: ["AAPL", "TSLA", ...], quotes: ["AAPL", ...]}
```

**Test Technical Analysis (Phase 2):**

```elixir
# Load bars
alias Signal.Repo
import Ecto.Query

bars = from(b in Signal.MarketData.Bar,
         where: b.symbol == "AAPL",
         order_by: [asc: b.bar_time],
         limit: 100)
       |> Repo.all()

# Detect swings
alias Signal.Technicals.Swings
swings = Swings.identify_swings(bars, lookback: 2)

# Analyze structure
alias Signal.Technicals.StructureDetector
structure = StructureDetector.analyze(bars)

structure.trend
# => :bullish

structure.latest_bos
# => %{type: :bullish, price: ..., bar_time: ...}
```

### Using Mock Stream (Development)

**Enable in config/dev.exs:**

```elixir
config :signal,
  use_mock_stream: true  # No Alpaca credentials needed
```

**Restart server:**

```bash
mix phx.server
```

Dashboard will show fake market data updating every 1-5 seconds.

---

## Testing Strategy

### Unit Tests (66+ tests)

**Coverage**:

- BarCache (15 tests)
- Monitor (18 tests)
- Schema validation (17 tests)
- Technicals modules (51+ tests - Phase 2)

**Example Test**:

```elixir
test "BarCache stores and retrieves bar data" do
  bar = %{
    open: Decimal.new("175.00"),
    high: Decimal.new("175.50"),
    low: Decimal.new("174.80"),
    close: Decimal.new("175.20"),
    volume: 1_000_000,
    timestamp: DateTime.utc_now()
  }

  BarCache.update_bar(:AAPL, bar)

  assert {:ok, cached} = BarCache.get(:AAPL)
  assert cached.last_bar.close == bar.close
end
```

### Integration Tests

**Tagged with @tag :integration**:

```elixir
@tag :integration
test "WebSocket connection and data flow" do
  # Requires Alpaca credentials
  {:ok, pid} = Stream.start_link(
    callback_module: TestCallback,
    initial_subscriptions: %{bars: ["FAKEPACA"]}
  )

  # Wait for connection
  Process.sleep(5000)

  # Verify data received
  assert TestCallback.received_bars?()
end
```

**Run with:**

```bash
mix test --include integration
```

### Property-Based Testing (Future)

Use StreamData for edge cases:

- Random price sequences
- Various bar patterns
- Swing detection with different lookbacks

---

## Quick Reference

### Configuration (config/dev.exs)

```elixir
# Alpaca API
config :signal, Signal.Alpaca,
  api_key: System.get_env("ALPACA_API_KEY"),
  api_secret: System.get_env("ALPACA_API_SECRET"),
  base_url: "https://paper-api.alpaca.markets",
  ws_url: "wss://stream.data.alpaca.markets/v2/sip"

# Symbol list
config :signal,
  symbols: [:AAPL, :TSLA, :NVDA, ...],
  market_open: ~T[09:30:00],
  market_close: ~T[16:00:00],
  timezone: "America/New_York"
```

### Common Mix Commands

```bash
# Development
mix phx.server              # Start server
iex -S mix phx.server       # Start with IEx

# Database
mix ecto.create             # Create database
mix ecto.migrate            # Run migrations
mix ecto.reset              # Drop, create, migrate

# Testing
mix test                    # Run tests (excludes integration)
mix test --include integration
mix test --cover            # With coverage

# Data loading
mix signal.load_data --year 2024
mix signal.load_data --check-only

# Code quality
mix format                  # Format code
mix precommit              # Run all checks
```

### Key Module APIs

**BarCache:**

```elixir
BarCache.get(:AAPL)
BarCache.current_price(:AAPL)
BarCache.update_bar(:AAPL, bar)
BarCache.all_symbols()
```

**Monitor:**

```elixir
Monitor.track_message(:quote)
Monitor.track_connection(:connected)
Monitor.get_stats()
```

**Levels (Phase 2):**

```elixir
Levels.calculate_daily_levels(:AAPL, ~D[2024-11-23])
Levels.get_current_levels(:AAPL)
Levels.level_broken?(level, current, previous)
```

**Swings (Phase 2):**

```elixir
Swings.identify_swings(bars, lookback: 2)
Swings.swing_high?(bars, index, lookback)
Swings.get_latest_swing(bars, :high)
```

**Structure (Phase 2):**

```elixir
StructureDetector.analyze(bars)
StructureDetector.detect_bos(bars, swings, :bullish)
StructureDetector.determine_trend(swing_highs, swing_lows)
```

### Database Queries

**Recent bars:**

```elixir
import Ecto.Query

bars = from(b in Signal.MarketData.Bar,
         where: b.symbol == "AAPL",
         where: b.bar_time >= ago(1, "day"),
         order_by: [desc: b.bar_time],
         limit: 100)
       |> Repo.all()
```

**Daily OHLC:**

```elixir
daily = from(b in Signal.MarketData.Bar,
          where: b.symbol == "AAPL",
          where: fragment("?::date = ?", b.bar_time, ^~D[2024-11-23]),
          select: %{
            open: first_value(b.open) |> over(order_by: b.bar_time),
            high: max(b.high),
            low: min(b.low),
            close: last_value(b.close) |> over(order_by: b.bar_time),
            volume: sum(b.volume)
          })
        |> Repo.one()
```

---

## Next Steps

### Learning Path

**1. Week 1: Understand Phase 1**

- Read Phase 1 Summary
- Explore the code (`lib/signal/alpaca/`, `lib/signal/bar_cache.ex`)
- Run the application locally
- Test BarCache in IEx
- Review dashboard functionality

**2. Week 2: Study Phase 2 Design**

- Read Phase 2 Project Plan
- Understand trading concepts (BOS, ChoCh, swings)
- Review Task 1 Work Orders
- Study existing Phase 2 modules

**3. Week 3: Hands-On Testing**

- Test Levels module (calculate daily levels)
- Test Swings module (detect swing points)
- Test Structure module (analyze trends)
- Use Inspector module for visualization

**4. Week 4: Contribute**

- Write additional unit tests
- Implement PD Arrays (Task 2)
- Build strategy engine (Task 3)
- Integrate with dashboard (Task 5)

### Resources

**Documentation**:

- `README.md` - Setup and quick start
- `CLAUDE.md` - Development guide and patterns
- `docs/PHASE_1_SUMMARY.md` - Complete Phase 1 overview
- `docs/PROJECT_PLAN_PHASE_2.md` - Phase 2 roadmap
- `docs/TESTING_TECHNICALS.md` - Testing guide for Phase 2 modules

**External Resources**:

- [Alpaca API Docs](https://docs.alpaca.markets)
- [Phoenix LiveView Guide](https://hexdocs.pm/phoenix_live_view)
- [TimescaleDB Docs](https://docs.timescale.com)
- [Elixir School](https://elixirschool.com)

---

## Summary

You've built a sophisticated real-time trading system with:

✅ **Solid Foundation (Phase 1)**

- Real-time data streaming (17 symbols)
- Historical data (7.4M bars, 5 years)
- Professional dashboard with real-time updates
- System monitoring and health checks
- 66+ unit tests with comprehensive coverage

🔨 **In Progress (Phase 2)**

- Market structure detection (swings, BOS, ChoCh)
- Key level tracking (PDH/PDL, opening ranges)
- Technical analysis infrastructure
- Strategy framework foundation

🎯 **Coming Soon**

- Break & retest signal generation
- Confluence-based quality scoring
- Backtesting engine
- Automated trade execution

**Your system is production-ready for real-time market data and ready for algorithmic trading strategy implementation.**

---

**Last Updated**: November 2024
**Version**: 2.0 (Phase 2 in progress)
