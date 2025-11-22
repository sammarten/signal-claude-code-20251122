# Signal Trading System - Detailed Implementation Plan (Revised)

## Project Context

You are building a real-time day trading system called "Signal" using Elixir/Phoenix with event sourcing architecture. The system streams market data from Alpaca Markets, performs technical analysis, generates trading signals, and executes trades.

**Current State:**
- Phoenix 1.7+ project created at `~/signal`
- TimescaleDB running in Docker on localhost:5433
- Phoenix configured to connect to TimescaleDB
- TimescaleDB extension enabled

**Project Structure:**
```
signal/
├── lib/
│   ├── signal/
│   │   ├── alpaca/                # Alpaca integration
│   │   │   ├── client.ex          # REST API
│   │   │   ├── stream.ex          # WebSocket
│   │   │   ├── stream_handler.ex  # Callback handler
│   │   │   ├── config.ex          # Configuration
│   │   │   ├── stream_supervisor.ex
│   │   │   └── mock_stream.ex     # For testing without credentials
│   │   ├── market_data/           # Market data domain
│   │   │   ├── bar.ex
│   │   │   ├── historical_loader.ex
│   │   │   └── verifier.ex
│   │   ├── signals/               # Future
│   │   ├── portfolio/             # Future
│   │   ├── bar_cache.ex
│   │   ├── monitor.ex
│   │   ├── repo.ex
│   │   └── application.ex
│   └── signal_web/
├── config/
├── priv/
├── test/
├── docker-compose.yml
└── mix.exs
```

**Architecture Principles:**
- Event sourcing for complete audit trail
- Event-driven via Phoenix.PubSub for loose coupling
- Bars (1-minute OHLCV) for strategy decisions
- Quotes (real-time bid/ask) for monitoring and execution
- ETS for fast in-memory state access
- Single WebSocket connection to Alpaca (multiplexed for 25 symbols)
- Clean, idiomatic Elixir - vertical slice architecture

**Target Symbols:**
- 10-20 tech stocks: AAPL, TSLA, NVDA, PLTR, GOOGL, MSFT, AMZN, META, etc.
- 3-5 index ETFs: SPY, QQQ, SMH, DIA, IWM

**Historical Data:** 5 years of 1-minute bars for backtesting

**Time Zone Strategy:**
- Alpaca sends all timestamps in UTC
- Store everything in UTC (database, BarCache, events)
- Convert to ET only for display or market hours checks
- Use tz library for market hours calculations
- Market open/close configured as naive time in ET

## Phase 1: Core Infrastructure & Database

### Task 1.1: Add Required Dependencies

**Objective:** Add dependencies needed for Alpaca integration.

**Location:** `~/signal/mix.exs`

**Dependencies to Add:**
```elixir
defp deps do
  [
    # ... existing Phoenix dependencies ...
    
    # Alpaca integration
    {:websockex, "~> 0.4.3"},
    {:req, "~> 0.5"},
    
    # Timezone handling
    {:tz, "~> 0.26"}
  ]
end
```

**After updating:**
- Run `mix deps.get`
- Run `mix compile`

**Success Criteria:**
- `mix deps.get` succeeds
- All dependencies compile
- `mix compile` succeeds for entire project

### Task 1.2: Create Market Bars Hypertable Migration

**Objective:** Create TimescaleDB hypertable for storing 1-minute bar data.

**Location:** `~/signal/priv/repo/migrations/YYYYMMDDHHMMSS_create_market_bars.exs`

**Command:** `mix ecto.gen.migration create_market_bars`

**Migration Content:**

```elixir
defmodule Signal.Repo.Migrations.CreateMarketBars do
  use Ecto.Migration

  def up do
    # Create table with composite primary key
    create table(:market_bars, primary_key: false) do
      add :symbol, :string, null: false
      add :bar_time, :utc_datetime_usec, null: false
      add :open, :decimal, precision: 10, scale: 2, null: false
      add :high, :decimal, precision: 10, scale: 2, null: false
      add :low, :decimal, precision: 10, scale: 2, null: false
      add :close, :decimal, precision: 10, scale: 2, null: false
      add :volume, :bigint, null: false
      add :vwap, :decimal, precision: 10, scale: 2
      add :trade_count, :integer
    end

    # Add composite primary key
    execute """
    ALTER TABLE market_bars 
    ADD PRIMARY KEY (symbol, bar_time)
    """

    # Convert to TimescaleDB hypertable
    execute """
    SELECT create_hypertable(
      'market_bars',
      'bar_time',
      chunk_time_interval => INTERVAL '1 day'
    )
    """

    # Create index for efficient symbol queries
    create index(:market_bars, [:symbol, :bar_time])

    # Enable compression
    execute """
    ALTER TABLE market_bars SET (
      timescaledb.compress,
      timescaledb.compress_segmentby = 'symbol'
    )
    """

    # Add compression policy (compress chunks older than 7 days)
    execute """
    SELECT add_compression_policy('market_bars', INTERVAL '7 days')
    """

    # Add retention policy (keep data for 6 years)
    execute """
    SELECT add_retention_policy('market_bars', INTERVAL '6 years')
    """
  end

  def down do
    # Remove policies first
    execute """
    SELECT remove_compression_policy('market_bars')
    """
    
    execute """
    SELECT remove_retention_policy('market_bars')
    """

    # Drop the table (hypertable drops automatically)
    drop table(:market_bars)
  end
end
```

**Run Migration:**
```bash
mix ecto.migrate
```

**Verify:**
```sql
-- Connect to database
psql -U postgres -h localhost -p 5433 -d signal_dev

-- Check hypertable
SELECT * FROM timescaledb_information.hypertables WHERE hypertable_name = 'market_bars';

-- Check compression
SELECT * FROM timescaledb_information.compression_settings WHERE hypertable_name = 'market_bars';

-- Exit
\q
```

**Success Criteria:**
- Migration runs without errors
- Table shows up in hypertables view
- Compression policy is active
- Retention policy is set
- Can insert sample data successfully

### Task 1.3: Create Events Table Migration

**Objective:** Create event sourcing table for domain events (not market data).

**Location:** `~/signal/priv/repo/migrations/YYYYMMDDHHMMSS_create_events.exs`

**Command:** `mix ecto.gen.migration create_events`

**Important Note:** This table is not used in Phase 1. It's infrastructure for Phase 2+ when we implement:
- Trading signals (SignalGenerated events)
- Order execution (OrderPlaced, OrderFilled events)  
- Portfolio tracking (PositionOpened events)

Creating it now ensures schema is ready.

**Migration Content:**

```elixir
defmodule Signal.Repo.Migrations.CreateEvents do
  use Ecto.Migration

  def up do
    create table(:events) do
      add :stream_id, :string, null: false
      add :event_type, :string, null: false
      add :payload, :jsonb, null: false, default: "{}"
      add :version, :integer, null: false
      add :timestamp, :utc_datetime_usec, null: false, default: fragment("NOW()")
    end

    # Index for reading events from a stream in order
    create index(:events, [:stream_id, :version])

    # Index for querying by event type
    create index(:events, [:event_type])

    # Index for time-based queries
    create index(:events, [:timestamp])

    # Unique constraint for optimistic locking
    create unique_index(:events, [:stream_id, :version], 
      name: :events_stream_version_unique)
  end

  def down do
    drop table(:events)
  end
end
```

**Run Migration:**
```bash
mix ecto.migrate
```

**Success Criteria:**
- Migration runs without errors
- Unique constraint is created
- All indexes are present
- Can insert events
- Unique constraint prevents duplicate (stream_id, version) pairs

### Task 1.4: Create BarCache ETS Module

**Objective:** In-memory ETS cache for latest bar and quote data per symbol with O(1) access.

**Location:** `~/signal/lib/signal/bar_cache.ex`

**Requirements:**
- GenServer that creates and manages ETS table
- Table is protected (only this GenServer can write)
- Read concurrency enabled for fast concurrent reads
- Stores latest bar and quote per symbol
- Provides helper functions for common queries

**State Structure in ETS:**
```elixir
# ETS key: symbol (atom)
# ETS value: map
%{
  last_bar: %{
    open: Decimal.t(),
    high: Decimal.t(),
    low: Decimal.t(),
    close: Decimal.t(),
    volume: integer(),
    vwap: Decimal.t() | nil,
    trade_count: integer() | nil,
    timestamp: DateTime.t()
  },
  last_quote: %{
    bid_price: Decimal.t(),
    bid_size: integer(),
    ask_price: Decimal.t(),
    ask_size: integer(),
    timestamp: DateTime.t()
  }
}
```

**Public API:**

`start_link/1` - Start GenServer
- Parameters: opts (keyword list, for supervisor compatibility)
- Returns: `{:ok, pid}`
- Creates ETS table in init/1

`get/1` - Get all cached data for symbol
- Parameters: symbol (atom)
- Returns: `{:ok, data_map}` or `{:error, :not_found}`
- Direct ETS lookup, no GenServer call

`get_bar/1` - Get just latest bar
- Parameters: symbol (atom)
- Returns: bar_map or nil

`get_quote/1` - Get just latest quote
- Parameters: symbol (atom)
- Returns: quote_map or nil

`current_price/1` - Calculate current mid-point price
- Parameters: symbol (atom)
- Returns: Decimal.t() or nil
- Logic:
  1. Get cached data for symbol
  2. If has quote, return `Decimal.div(Decimal.add(bid_price, ask_price), 2)`
  3. Else if has bar, return bar.close
  4. Else return nil

`update_bar/2` - Update bar for symbol
- Parameters: symbol (atom), bar (map)
- Returns: :ok
- GenServer.call to ensure atomic update

`update_quote/2` - Update quote for symbol
- Parameters: symbol (atom), quote (map)
- Returns: :ok
- GenServer.call to ensure atomic update

`all_symbols/0` - Get list of all cached symbols
- Returns: list of atoms
- Direct ETS query

`clear/0` - Clear all cached data (for testing)
- Returns: :ok
- GenServer.call

**GenServer Callbacks:**

`init/1`
- Create ETS table with options:
  - `:named_table` - reference by name `:bar_cache`
  - `:protected` - only this process can write, all can read
  - `read_concurrency: true` - optimize for concurrent reads
- Return `{:ok, %{table: :bar_cache}}`

`handle_call({:update_bar, symbol, bar}, _from, state)`
- Get existing data or initialize empty
- Update :last_bar field
- Insert into ETS
- Return `:ok`

`handle_call({:update_quote, symbol, quote}, _from, state)`
- Get existing data or initialize empty
- Update :last_quote field
- Insert into ETS
- Return `:ok`

`handle_call(:clear, _from, state)`
- Delete all objects from ETS
- Return `:ok`

**Success Criteria:**
- ETS table created on start
- Only BarCache GenServer can write (protected)
- Multiple processes can read concurrently
- Updates are atomic via GenServer
- `current_price/1` correctly calculates mid-point
- Falls back to bar close if no quote
- Returns nil if no data

### Task 1.5: Create Monitor Module

**Objective:** Track system health metrics and detect anomalies.

**Location:** `~/signal/lib/signal/monitor.ex`

**Requirements:**
- GenServer tracking metrics
- Periodic logging and stats publishing
- Expose metrics via API
- Detect anomalies
- Monitor database health

**Tracked Metrics:**
- Quote messages per second
- Bar messages per minute
- Trade messages per second
- Connection uptime
- Last message timestamp per type
- Reconnection count
- Message processing errors
- Database health

**GenServer State:**
```elixir
%{
  counters: %{quotes: 0, bars: 0, trades: 0, errors: 0},
  connection_status: :connected,
  connection_start: DateTime.utc_now(),
  last_message: %{
    quote: nil,  # DateTime or nil
    bar: nil,
    trade: nil
  },
  reconnect_count: 0,
  window_start: DateTime.utc_now(),
  db_healthy: true,
  last_db_check: DateTime.utc_now()
}
```

**Public API:**

`start_link/1` - Start monitor
- Parameters: opts (for supervisor compatibility)
- Returns: `{:ok, pid}`

`track_message/1` - Record message received
- Parameters: type (:quote | :bar | :trade)
- Returns: :ok
- GenServer.cast for non-blocking

`track_error/1` - Record error
- Parameters: error details (any)
- Returns: :ok
- GenServer.cast

`track_connection/1` - Update connection status
- Parameters: status (:connected | :disconnected | :reconnecting)
- Returns: :ok
- GenServer.cast

`get_stats/0` - Get current statistics
- Returns: stats map
- GenServer.call

**Behavior:**

Periodic timer (every 60 seconds):
1. Calculate rates:
   - quotes_per_sec = counters.quotes / 60
   - bars_per_min = counters.bars
   - trades_per_sec = counters.trades / 60
2. Check database health (SELECT 1 query)
3. Check for anomalies
4. Log summary
5. Publish stats to PubSub "system:stats" topic
6. Reset counters
7. Update window_start

**Anomaly Detection:**
- If quote_per_sec = 0 for 60s during market hours → log warning
- If bars_per_min = 0 for 5 minutes during market hours → log warning  
- If reconnect_count > 10 in last hour → log error
- If connection_status = :disconnected for > 5 minutes → alert
- If database unhealthy → log error

**Database Health Check:**
```elixir
try do
  Ecto.Adapters.SQL.query!(Signal.Repo, "SELECT 1")
  true
rescue
  _ -> false
end
```

**Logging Example:**
```
[Monitor] Stats (60s): quotes=8,234 (137/s), bars=1,485 (25/min), errors=0, uptime=2h34m, db=healthy
[Monitor] WARNING: Quote rate is 0 during market hours
```

**PubSub Message Format:**
```elixir
%{
  quotes_per_sec: 137,
  bars_per_min: 25,
  trades_per_sec: 5,
  uptime_seconds: 9240,
  connection_status: :connected,
  db_healthy: true,
  reconnect_count: 0,
  last_message: %{
    quote: ~U[2024-11-15 14:30:45Z],
    bar: ~U[2024-11-15 14:30:00Z],
    trade: ~U[2024-11-15 14:30:43Z]
  }
}
```

**Success Criteria:**
- Tracks metrics accurately
- Logs periodic summaries
- Detects connection issues
- Publishes to PubSub
- Anomaly detection works
- Database health monitoring works
- Non-blocking message tracking

## Phase 2: Alpaca Integration

### Task 2.1: Create Alpaca Config Module

**Objective:** Configuration management for Alpaca API credentials and endpoints.

**Location:** `~/signal/lib/signal/alpaca/config.ex`

**Expected Configuration Format (in config/dev.exs):**
```elixir
config :signal, Signal.Alpaca,
  api_key: System.get_env("ALPACA_API_KEY"),
  api_secret: System.get_env("ALPACA_API_SECRET"),
  base_url: "https://paper-api.alpaca.markets",
  ws_url: "wss://stream.data.alpaca.markets/v2/iex"
```

**Public API:**

`api_key!/0` - Get API key, raise if not configured
- Returns: String
- Raises: RuntimeError with message "Alpaca API key not configured. Set ALPACA_API_KEY environment variable."

`api_secret!/0` - Get API secret, raise if not configured
- Returns: String
- Raises: RuntimeError with message "Alpaca API secret not configured. Set ALPACA_API_SECRET environment variable."

`base_url/0` - Get REST API base URL with default
- Returns: String
- Default: "https://paper-api.alpaca.markets"

`ws_url/0` - Get WebSocket URL with default
- Returns: String
- Default: "wss://stream.data.alpaca.markets/v2/iex"

`data_feed/0` - Extract feed type from ws_url
- Returns: :iex | :sip | :test
- Parses from URL path (v2/iex → :iex, v2/sip → :sip, v2/test → :test)

`configured?/0` - Check if credentials exist
- Returns: boolean
- True if both api_key and api_secret are set and non-empty

`paper_trading?/0` - Check if using paper trading URL
- Returns: boolean
- Checks if base_url contains "paper"

**Implementation Notes:**
- Read from `Application.get_env(:signal, Signal.Alpaca, [])`
- Use `Keyword.get/3` with defaults where appropriate
- Internal `validate!/0` helper function to check both credentials

**Success Criteria:**
- Can read config from application environment
- Raises informative errors when credentials missing
- Returns correct URLs with defaults
- Helper functions work correctly
- `configured?/0` returns accurate status

### Task 2.2: Create Alpaca Client Module (REST API)

**Objective:** HTTP client for Alpaca REST API for historical data and trading operations.

**Location:** `~/signal/lib/signal/alpaca/client.ex`

**Requirements:**
- Use Req library for HTTP requests
- Authentication via headers
- Automatic pagination handling
- Automatic retry on rate limiting (429)
- Parse responses to Elixir data structures
- Convert timestamps to DateTime
- Convert prices to Decimal
- Comprehensive error handling

**Rate Limiting Note:**
Alpaca free tier limits:
- REST API: 200 requests/minute
- Each pagination request counts
- For 500k bars with 10k per page = 50 requests per symbol
- With 15 symbols and parallel loading (5 concurrent), should stay under limit
- Initial 5-year load will take 2-4 hours total

**Public API - Market Data:**

`get_bars/2` - Get historical bars
- Parameters:
  - symbols: string or list of strings
  - opts: keyword list
    - `:start` (required) - DateTime
    - `:end` (required) - DateTime
    - `:timeframe` - string, default "1Min"
    - `:limit` - integer, max 10000
    - `:adjustment` - string, default "raw"
- Returns: `{:ok, %{symbol_string => [bar_map]}}` or `{:error, reason}`
- Bar map structure:
  ```elixir
  %{
    timestamp: ~U[2024-11-15 14:30:00Z],
    open: Decimal.new("185.20"),
    high: Decimal.new("185.60"),
    low: Decimal.new("184.90"),
    close: Decimal.new("185.45"),
    volume: 2_300_000,
    vwap: Decimal.new("185.32"),
    trade_count: 150
  }
  ```
- Handles pagination automatically (max 100 pages to prevent infinite loops)

`get_latest_bar/1` - Get most recent bar
- Parameters: symbol string
- Returns: `{:ok, bar_map}` or `{:error, reason}`

`get_latest_quote/1` - Get most recent quote
- Parameters: symbol string
- Returns: `{:ok, quote_map}` or `{:error, reason}`

`get_latest_trade/1` - Get most recent trade
- Parameters: symbol string
- Returns: `{:ok, trade_map}` or `{:error, reason}`

**Public API - Account:**

`get_account/0` - Get account information
- Returns: `{:ok, account_map}` or `{:error, reason}`

`get_positions/0` - Get all open positions
- Returns: `{:ok, [position_map]}` or `{:error, reason}`

`get_position/1` - Get position for specific symbol
- Parameters: symbol string
- Returns: `{:ok, position_map}` or `{:error, reason}`

**Public API - Orders:**

`list_orders/1` - Get orders with optional filters
- Parameters: opts keyword list
  - `:status` - "open", "closed", "all"
  - `:limit` - integer (max 500)
  - `:symbols` - list of strings
- Returns: `{:ok, [order_map]}` or `{:error, reason}`

`get_order/1` - Get specific order by ID
- Parameters: order_id string
- Returns: `{:ok, order_map}` or `{:error, reason}`

`place_order/1` - Submit new order
- Parameters: order map with required keys:
  - `:symbol` - string
  - `:qty` - integer
  - `:side` - "buy" or "sell"
  - `:type` - "market", "limit", "stop", etc.
  - `:time_in_force` - "day", "gtc", etc.
- Returns: `{:ok, order_map}` or `{:error, reason}`

`cancel_order/1` - Cancel order by ID
- Parameters: order_id string
- Returns: `{:ok, %{}}` or `{:error, reason}`

`cancel_all_orders/0` - Cancel all open orders
- Returns: `{:ok, [order_map]}` or `{:error, reason}`

**Implementation Details:**

Build Req request with:
- Base URL from Config.base_url/0
- Headers:
  - "APCA-API-KEY-ID": Config.api_key!/0
  - "APCA-API-SECRET-KEY": Config.api_secret!/0
  - "Content-Type": "application/json"
- Retry logic for 429 with exponential backoff (1s, 2s, 4s), max 3 attempts

**Response Processing:**
- Parse JSON to maps with atom keys
- Convert ISO8601 timestamps to DateTime using `DateTime.from_iso8601/1`
- Convert numeric strings to Decimal for prices
- Convert numeric strings to integers for quantities
- Normalize nested structures

**Pagination for get_bars/2:**
- Check for `next_page_token` in response
- Make additional requests with `page_token` parameter
- Accumulate results
- Max 100 pages to prevent infinite loops
- Log warning if hit max pages

**Error Handling:**
- HTTP 401: `{:error, :unauthorized}`
- HTTP 403: `{:error, :forbidden}`
- HTTP 404: `{:error, :not_found}`
- HTTP 422: `{:error, {:unprocessable, message}}`
- HTTP 429: Retry with backoff, then `{:error, :rate_limited}`
- HTTP 500+: `{:error, {:server_error, details}}`
- Network errors: `{:error, {:network_error, details}}`
- Invalid JSON: `{:error, {:invalid_response, details}}`

**Success Criteria:**
- Can authenticate with Alpaca
- Can download historical bars
- Pagination works correctly
- Parses responses correctly (DateTime, Decimal)
- Retries on rate limits appropriately
- All error cases handled
- Account and order endpoints work

### Task 2.3: Create Alpaca Stream Module (WebSocket)

**Objective:** WebSocket client for real-time market data streaming.

**Location:** `~/signal/lib/signal/alpaca/stream.ex`

**Requirements:**
- GenServer using WebSockex behavior
- Single persistent WebSocket connection
- Handle Alpaca authentication and subscription protocol
- Process batched messages
- Automatic reconnection with exponential backoff
- Callback mechanism for message delivery
- Accept initial subscriptions to avoid race conditions

**Alpaca WebSocket Protocol:**
1. Connect to ws_url
2. Receive: `[{"T":"success","msg":"connected"}]`
3. Send: `{"action":"auth","key":"KEY","secret":"SECRET"}`
4. Receive: `[{"T":"success","msg":"authenticated"}]`
5. Send: `{"action":"subscribe","bars":["AAPL"],"quotes":["AAPL"]}`
6. Receive: `[{"T":"subscription",...}]`
7. Receive data: `[{"T":"q",...},{"T":"b",...}]`

**GenServer State:**
```elixir
%{
  ws_conn: pid() | nil,
  status: :disconnected | :connecting | :connected | :authenticated | :subscribed,
  subscriptions: %{
    bars: ["AAPL", ...],
    quotes: ["AAPL", ...],
    trades: [],
    statuses: ["*"]
  },
  pending_subscriptions: %{bars: [], quotes: [], ...},
  reconnect_attempt: non_neg_integer(),
  reconnect_timer: reference() | nil,
  callback_module: module(),
  callback_state: any()
}
```

**Public API:**

`start_link/1` - Start stream GenServer
- Parameters: keyword list
  - `:callback_module` (required) - Module implementing `handle_message/2`
  - `:callback_state` (optional) - Initial state for callback, default: %{}
  - `:initial_subscriptions` (optional) - Map like `%{bars: ["AAPL"], quotes: ["AAPL"]}`
  - `:name` (optional) - GenServer registration name
- Returns: `{:ok, pid}` or `{:error, reason}`
- If initial_subscriptions provided, subscribes automatically after authentication

`subscribe/2` - Add subscriptions dynamically
- Parameters:
  - pid or name
  - subscriptions map: `%{bars: ["AAPL"], quotes: ["AAPL"]}`
- Returns: `:ok`
- Queues if not yet connected

`unsubscribe/2` - Remove subscriptions
- Parameters:
  - pid or name
  - subscriptions map: `%{bars: ["AAPL"]}`
- Returns: `:ok`

`status/1` - Get connection status
- Parameters: pid or name
- Returns: :disconnected | :connecting | :connected | :authenticated | :subscribed

`subscriptions/1` - Get active subscriptions
- Parameters: pid or name
- Returns: `%{bars: [...], quotes: [...], ...}`

**Callback Module Behavior:**

Consumers implement:
```elixir
@callback handle_message(message :: map(), state :: any()) :: {:ok, new_state}
```

**Normalized Message Formats:**

Quote:
```elixir
%{
  type: :quote,
  symbol: "AAPL",
  bid_price: Decimal.new("185.50"),
  bid_size: 100,
  ask_price: Decimal.new("185.52"),
  ask_size: 200,
  timestamp: ~U[2024-11-15 14:30:00.123456Z]
}
```

Bar:
```elixir
%{
  type: :bar,
  symbol: "AAPL",
  open: Decimal.new("185.20"),
  high: Decimal.new("185.60"),
  low: Decimal.new("184.90"),
  close: Decimal.new("185.45"),
  volume: 2_300_000,
  timestamp: ~U[2024-11-15 14:30:00Z],
  vwap: Decimal.new("185.32"),
  trade_count: 150
}
```

Trade:
```elixir
%{
  type: :trade,
  symbol: "AAPL",
  price: Decimal.new("185.50"),
  size: 100,
  timestamp: ~U[2024-11-15 14:30:00.123456Z]
}
```

Status:
```elixir
%{
  type: :status,
  symbol: "AAPL",
  status_code: "T",
  status_message: "Trading",
  timestamp: ~U[2024-11-15 14:30:00Z]
}
```

Connection:
```elixir
%{
  type: :connection,
  status: :connected | :disconnected | :reconnecting,
  attempt: 0
}
```

**Reconnection Logic:**
- Exponential backoff: 1s, 2s, 4s, 8s, 16s, 32s, max 60s
- Reset backoff on successful connection
- Re-authenticate and re-subscribe on reconnect
- Deliver connection events to callback

**Message Processing:**
1. Receive JSON array: `[{msg1}, {msg2}]`
2. Parse JSON
3. For each message:
   - Check "T" field for type
   - Control messages: handle internally, log
   - Data messages: normalize and deliver to callback
4. Convert timestamps to DateTime
5. Convert prices to Decimal
6. Call `callback_module.handle_message/2`

**Subscription Error Handling:**
- If Alpaca returns error for invalid symbol
- Log warning: "Failed to subscribe to XYZ: invalid symbol"
- Remove from active subscriptions
- Continue with valid symbols
- Don't crash the Stream

**Error Handling:**
- WebSocket errors: log and reconnect
- Auth failures (401/403): log error and stop (bad credentials, don't retry indefinitely)
- Parse errors: log warning, skip message, continue
- Callback errors: log error, keep current callback_state, continue
- Subscription errors: log warning, remove invalid symbols

**Logging:**
- Info level: connection events
- Debug level: message flow
- Warn level: errors
- Examples:
  - "AlpacaStream connected to wss://..."
  - "AlpacaStream authenticated"
  - "AlpacaStream subscribed to bars: [AAPL, TSLA, ...], quotes: [...]"
  - "AlpacaStream disconnected: {reason}, reconnecting in 4s (attempt 3)"
  - "AlpacaStream authentication failed: {reason}"

**Success Criteria:**
- Connects and authenticates successfully
- Subscribes to channels
- Receives and parses messages correctly
- Normalizes messages (DateTime, Decimal)
- Delivers to callback module
- Reconnects automatically
- Restores subscriptions after reconnect
- Handles batched messages
- Initial subscriptions work without race conditions
- Handles subscription errors gracefully

### Task 2.4: Create Stream Handler Module

**Objective:** Implement callback module for Alpaca stream that updates BarCache, publishes to PubSub, and tracks metrics.

**Location:** `~/signal/lib/signal/alpaca/stream_handler.ex`

**Requirements:**
- Implements callback for Signal.Alpaca.Stream
- Receives normalized messages
- Updates BarCache
- Publishes to Phoenix.PubSub
- Deduplicates quotes (skip if bid/ask unchanged)
- Tracks metrics via Monitor
- Periodic throughput logging

**Handler State:**
```elixir
%{
  last_quotes: %{
    "AAPL" => %{bid_price: Decimal.t(), ask_price: Decimal.t()},
    "TSLA" => %{...},
    ...
  },
  counters: %{quotes: 0, bars: 0, trades: 0, statuses: 0},
  last_log: DateTime.utc_now()
}
```

**Message Processing Logic:**

For quotes (type: :quote):
1. Get previous quote for symbol from state.last_quotes
2. Check if bid_price or ask_price changed:
   - Compare using `Decimal.equal?/2`
   - If both unchanged: return state (skip, don't process)
3. If changed:
   - Update BarCache.update_quote/2
   - Broadcast to `"quotes:#{symbol}"` topic: `{:quote, symbol, quote}`
   - Track with `Signal.Monitor.track_message(:quote)`
   - Update last_quotes in state with new values
   - Increment quote counter

For bars (type: :bar):
1. Update BarCache.update_bar/2
2. Broadcast to `"bars:#{symbol}"` topic: `{:bar, symbol, bar}`
3. Track with `Signal.Monitor.track_message(:bar)`
4. Increment bar counter

For trades (type: :trade):
1. Broadcast to `"trades:#{symbol}"` topic: `{:trade, symbol, trade}`
2. Track with `Signal.Monitor.track_message(:trade)`
3. Increment trade counter

For statuses (type: :status):
1. Broadcast to `"statuses:#{symbol}"` topic: `{:status, symbol, status}`
2. Log trading halts/resumes at warn level
3. Increment status counter

For connection (type: :connection):
1. Broadcast to `"alpaca:connection"` topic: `{:connection, status, details}`
2. Track with `Signal.Monitor.track_connection(status)`
3. Log connection status changes at info level
4. If status is :connected, reset counters

**Periodic Logging:**
- Check if `DateTime.diff(DateTime.utc_now(), state.last_log, :second) >= 60`
- If yes:
  - Calculate rates from counters
  - Log: "StreamHandler stats (60s): quotes=X, bars=Y, trades=Z, statuses=W"
  - Reset all counters to 0
  - Update last_log to current time

**PubSub Topics:**
- `"quotes:#{symbol}"` - Quote updates (only if price changed)
- `"bars:#{symbol}"` - Bar updates (always)
- `"trades:#{symbol}"` - Trade updates
- `"statuses:#{symbol}"` - Status changes (halts, resumes)
- `"alpaca:connection"` - Connection events

**PubSub Message Format:**
All messages are tuples for pattern matching:
- Quote: `{:quote, symbol_string, quote_map}`
- Bar: `{:bar, symbol_string, bar_map}`
- Trade: `{:trade, symbol_string, trade_map}`
- Status: `{:status, symbol_string, status_map}`
- Connection: `{:connection, status_atom, details_map}`

**Success Criteria:**
- Implements callback correctly
- Deduplicates unchanged quotes effectively
- Updates BarCache correctly
- Publishes to all appropriate PubSub topics
- Tracks metrics with Monitor module
- Logs throughput periodically
- Handles all message types
- State management works correctly

### Task 2.5: Create Alpaca Stream Supervisor

**Objective:** Supervisor to start and manage Alpaca.Stream with StreamHandler.

**Location:** `~/signal/lib/signal/alpaca/stream_supervisor.ex`

**Requirements:**
- Supervisor for Alpaca.Stream
- Starts with StreamHandler as callback
- Passes initial subscriptions to avoid race condition
- Only starts if credentials configured
- Handles startup failures gracefully

**Implementation:**

Get configured symbols:
- Read from `Application.get_env(:signal, :symbols, [])`
- Convert atoms to strings: `Enum.map(symbols, &Atom.to_string/1)`

**Child Specification:**
```elixir
{Signal.Alpaca.Stream,
  callback_module: Signal.Alpaca.StreamHandler,
  callback_state: %{
    last_quotes: %{},
    counters: %{quotes: 0, bars: 0, trades: 0, statuses: 0},
    last_log: DateTime.utc_now()
  },
  initial_subscriptions: %{
    bars: symbol_strings,
    quotes: symbol_strings,
    statuses: ["*"]
  },
  name: Signal.Alpaca.Stream
}
```

**Conditional Start:**
- In `init/1`, check `Signal.Alpaca.Config.configured?/0`
- If false:
  - Log warning: "Alpaca credentials not configured. Stream will not start. Set ALPACA_API_KEY and ALPACA_API_SECRET environment variables."
  - Return `:ignore`
- If true:
  - Proceed with normal supervision

**Startup Resilience Note:**
- If Alpaca is down on startup, Stream will retry indefinitely with exponential backoff
- Application still starts successfully
- Dashboard will show "disconnected" status
- Once Alpaca available, Stream connects automatically
- This is expected and correct behavior

**Success Criteria:**
- Starts Alpaca.Stream on application start
- Passes initial subscriptions correctly
- Stream subscribes automatically after authentication
- Connects to Alpaca and starts receiving data
- Skips gracefully if not configured (returns :ignore)
- Can be tested without credentials
- No subscription race conditions

### Task 2.6: Update Application Supervision Tree

**Objective:** Add new components to application supervision tree in correct order.

**Location:** `~/signal/lib/signal/application.ex`

**Requirements:**
- Add BarCache, Monitor, and Alpaca.StreamSupervisor
- Correct ordering for dependencies

**Children List:**
```elixir
children = [
  SignalWeb.Telemetry,
  Signal.Repo,
  {DNSCluster, query: Application.get_env(:signal, :dns_cluster_query) || :ignore},
  {Phoenix.PubSub, name: Signal.PubSub},
  
  # ETS cache for latest market data (must be before StreamSupervisor)
  Signal.BarCache,
  
  # System monitoring (must be before StreamSupervisor)
  Signal.Monitor,
  
  # Alpaca integration (depends on BarCache, Monitor, PubSub)
  Signal.Alpaca.StreamSupervisor,
  
  {Finch, name: Signal.Finch},
  SignalWeb.Endpoint
]
```

**Dependency Order:**
1. PubSub must start before StreamSupervisor (StreamHandler publishes to it)
2. BarCache must start before StreamSupervisor (StreamHandler writes to it)
3. Monitor must start before StreamSupervisor (StreamHandler tracks metrics)

**Success Criteria:**
- Application starts successfully
- All GenServers are running
- Correct startup order maintained
- Application handles missing Alpaca config gracefully
- Can verify with: `Supervisor.which_children(Signal.Supervisor)`

### Task 2.7: Configure Alpaca Credentials and Symbols

**Objective:** Set up environment-based configuration.

**Location:** `~/signal/config/dev.exs` and `~/signal/config/runtime.exs`

**In config/dev.exs:**
```elixir
# Alpaca configuration
config :signal, Signal.Alpaca,
  api_key: System.get_env("ALPACA_API_KEY"),
  api_secret: System.get_env("ALPACA_API_SECRET"),
  base_url: System.get_env("ALPACA_BASE_URL") || "https://paper-api.alpaca.markets",
  ws_url: System.get_env("ALPACA_WS_URL") || "wss://stream.data.alpaca.markets/v2/iex"

# Signal application config
config :signal,
  symbols: [
    # Tech stocks
    :AAPL, :TSLA, :NVDA, :PLTR, :GOOGL, :MSFT, :AMZN, :META,
    :AMD, :NFLX, :CRM, :ADBE,
    # Index ETFs
    :SPY, :QQQ, :SMH, :DIA, :IWM
  ],
  market_open: ~T[09:30:00],
  market_close: ~T[16:00:00],
  timezone: "America/New_York"
```

**In config/runtime.exs (for production):**
```elixir
if config_env() == :prod do
  config :signal, Signal.Alpaca,
    api_key: System.fetch_env!("ALPACA_API_KEY"),
    api_secret: System.fetch_env!("ALPACA_API_SECRET"),
    base_url: System.get_env("ALPACA_BASE_URL", "https://paper-api.alpaca.markets"),
    ws_url: System.get_env("ALPACA_WS_URL", "wss://stream.data.alpaca.markets/v2/iex")
end
```

**Environment Variables:**

Create `.env` file in project root (add to .gitignore):
```bash
export ALPACA_API_KEY="your_key_here"
export ALPACA_API_SECRET="your_secret_here"
export ALPACA_BASE_URL="https://paper-api.alpaca.markets"
export ALPACA_WS_URL="wss://stream.data.alpaca.markets/v2/iex"
```

To use: `source .env` before running `mix phx.server`

**Update .gitignore:**
```
# Environment variables
.env
```

**Success Criteria:**
- Config reads from environment variables
- Application starts successfully with credentials
- Application fails gracefully if credentials missing (shows warning, continues)
- Can switch between paper and live easily
- Symbol list is configurable
- .env is gitignored

## CHECKPOINT: Real-Time System Complete

**At this point, you have a working real-time trading system!**

Before proceeding to historical data loading (which takes 2-4 hours), verify:
- ✅ Application starts: `mix phx.server`
- ✅ Connects to Alpaca WebSocket
- ✅ BarCache populates with data
- ✅ Monitor tracks metrics
- ✅ Can query BarCache from IEx: `Signal.BarCache.get(:AAPL)`
- ✅ Logs show message flow

**Test the system:**
```bash
# Start the app
mix phx.server

# In another terminal, connect to IEx
iex -S mix

# Check BarCache
Signal.BarCache.get(:AAPL)

# Check Monitor stats
Signal.Monitor.get_stats()

# Check Stream status
GenServer.call(Signal.Alpaca.Stream, :status)
```

**Expected behavior:**
- See log messages about connecting, authenticating, subscribing
- BarCache fills with data within 1 minute
- Monitor shows message rates > 0
- No crashes or errors

Once verified, proceed to building the dashboard and then loading historical data.

## Phase 3: LiveView Dashboard

### Task 3.1: Create Market Data LiveView

**Objective:** Real-time dashboard showing live market data.

**Location:** `~/signal_web/live/market_live.ex`

**Requirements:**
- LiveView with real-time updates
- Subscribe to PubSub topics
- Display table of all symbols
- Connection status indicator
- System stats display
- Handle empty BarCache gracefully on startup

**Mount Behavior:**
1. Get configured symbols from `Application.get_env(:signal, :symbols, [])`
2. For each symbol, load initial data from BarCache:
   - If BarCache.get(symbol) returns `{:ok, data}`, use it
   - If returns `{:error, :not_found}`, set to nil (no data yet)
   - Don't crash or show error - data will arrive when stream connects
3. Subscribe to PubSub topics:
   - `"quotes:#{symbol}"` for each symbol (convert atom to string)
   - `"bars:#{symbol}"` for each symbol
   - `"alpaca:connection"` for connection status
   - `"system:stats"` for monitor stats
4. Set up initial assigns

**Assigns Structure:**
```elixir
%{
  symbols: [:AAPL, :TSLA, :NVDA, ...],
  symbol_data: %{
    AAPL: %{
      symbol: "AAPL",
      current_price: Decimal.new("185.50") | nil,
      previous_price: Decimal.new("185.40"),  # For change calculation
      bid: Decimal.new("185.48") | nil,
      ask: Decimal.new("185.52") | nil,
      spread: Decimal.new("0.04") | nil,
      last_bar: %{
        open: Decimal.new("185.20"),
        high: Decimal.new("185.60"),
        low: Decimal.new("184.90"),
        close: Decimal.new("185.45"),
        volume: 2_300_000,
        timestamp: ~U[2024-11-15 14:30:00Z]
      } | nil,
      last_update: ~U[2024-11-15 14:30:45Z] | nil,
      price_change: :up | :down | :unchanged | :no_data
    },
    ...
  },
  connection_status: :connected | :disconnected | :reconnecting,
  connection_details: %{attempt: 0},
  system_stats: %{
    quotes_per_sec: 137,
    bars_per_min: 25,
    uptime_seconds: 9240,
    db_healthy: true,
    last_quote: ~U[...] | nil,
    last_bar: ~U[...] | nil
  }
}
```

**Handle Info Callbacks:**

For `{:quote, symbol_string, quote}`:
1. Convert symbol string to atom
2. Get current data for symbol from assigns
3. Calculate new price: `Decimal.div(Decimal.add(quote.bid_price, quote.ask_price), 2)`
4. Compare to previous_price to determine change direction:
   - If `Decimal.gt?(new_price, previous_price)` → :up
   - If `Decimal.lt?(new_price, previous_price)` → :down
   - If `Decimal.equal?(new_price, previous_price)` → :unchanged
5. Update symbol_data with:
   - current_price: new_price
   - previous_price: old current_price (for next comparison)
   - bid, ask, spread
   - last_update: quote.timestamp
   - price_change: direction
6. Assign and render

For `{:bar, symbol_string, bar}`:
1. Convert symbol to atom
2. Update symbol_data.last_bar
3. If no quote data yet, use bar.close as current_price
4. Assign and render

For `{:connection, status, details}`:
1. Update connection_status
2. Update connection_details
3. Assign and render

For system stats from PubSub "system:stats":
1. Update system_stats assign
2. Render

**Template Structure:**

Header:
- Connection status badge with details (attempt number if reconnecting)
- Last message timestamp ("2s ago")

System Stats Panel:
- Use SystemStats component (Task 3.3)
- Show message rates, uptime, health

Symbol Table:
- Columns:
  - Symbol name
  - Current Price (with color based on change direction)
  - Bid / Ask / Spread
  - Last Bar: O/H/L/C
  - Volume
  - Last Update (time ago, e.g., "3s ago")
- Handle nil values gracefully:
  - Show "Loading..." or "-" for missing data
  - Don't show prices until data arrives
- Responsive layout
- Sticky header for scrolling

**Styling with Tailwind:**
- Price changes:
  - :up → text-green-600
  - :down → text-red-600
  - :unchanged → text-gray-600
  - :no_data → text-gray-400
- Connection status:
  - :connected → green dot + "Connected"
  - :disconnected → red dot + "Disconnected"
  - :reconnecting → yellow dot + "Reconnecting (attempt X)"
- Monospace font for all prices: `font-mono`
- Table zebra striping: `even:bg-gray-50`
- Sticky header: `sticky top-0 bg-white`

**Decimal Formatting Helper:**
Create helper function for displaying Decimals:
```elixir
defp format_price(nil), do: "-"
defp format_price(decimal) do
  decimal
  |> Decimal.round(2)
  |> Decimal.to_string(:normal)
end
```

Use in template: `$<%= format_price(@symbol_data[symbol].current_price) %>`

**Performance Optimization:**
- Debounce rapid updates if needed (max 10 updates/sec per symbol)
- Use minimal assigns updates (only update changed symbol)
- Consider using `Phoenix.LiveView.JS` for client-side price animations

**Success Criteria:**
- Dashboard loads with or without initial data
- Shows "Loading..." or "-" for symbols without data yet
- Real-time price updates appear within seconds of stream connecting
- Connection status reflects actual state (color-coded)
- Table is readable and responsive
- No crashes when BarCache is empty
- No UI lag with frequent updates
- Works on mobile and desktop
- Decimal values display correctly formatted

### Task 3.2: Add Dashboard Route

**Objective:** Route to access market dashboard.

**Location:** `~/signal_web/router.ex`

**Route Configuration:**
```elixir
scope "/", SignalWeb do
  pipe_through :browser

  live "/", MarketLive, :index
  # Other routes...
end
```

**Success Criteria:**
- Can access dashboard at http://localhost:4000/
- LiveView mounts successfully
- Page title shows "Market Data · Signal"
- Live navigation works

### Task 3.3: Create System Stats Component

**Objective:** Reusable function component for system statistics display.

**Location:** `~/signal_web/live/components/system_stats.ex`

**Requirements:**
- Function component (not LiveComponent)
- Shows connection status, message rates, uptime, health
- Color-coded indicators
- Uses Heroicons for visual appeal

**Component Signature:**
```elixir
attr :connection_status, :atom, required: true
attr :connection_details, :map, default: %{}
attr :stats, :map, required: true

def system_stats(assigns)
```

**Displays:**
- WebSocket connection status badge
- Message rates:
  - Quotes/sec
  - Bars/min
  - Trades/sec (if > 0)
- System health:
  - Database status
  - Overall health indicator
- Uptime (formatted as "2h 34m")
- Last message timestamps
- Active subscriptions count (from stats if provided)

**Layout:**
- Card with shadow
- Grid layout for stats
- Each stat: icon + label + value
- Color-coded health badges
- Responsive (stacks on mobile)

**Heroicons to use:**
- Connection: wifi or signal icon
- Messages: chat-bubble-left-right
- Database: circle-stack
- Time: clock
- Health: check-circle (green) or exclamation-circle (red/yellow)

**Health Calculation (in component):**
```elixir
defp calculate_health(stats, connection_status) do
  cond do
    connection_status == :disconnected -> :error
    not stats.db_healthy -> :error
    stats.quotes_per_sec == 0 and market_open?() -> :degraded
    connection_status == :reconnecting -> :degraded
    true -> :healthy
  end
end
```

**Styling:**
- Health badges:
  - :healthy → green background + "System Healthy"
  - :degraded → yellow background + "Degraded Performance"
  - :error → red background + "System Error"
- Stat cards with hover effects
- Smooth transitions

**Success Criteria:**
- Component is reusable
- Shows accurate stats
- Updates in real-time via LiveView
- Color-coded indicators are clear
- Responsive design
- Professional appearance
- Easy to understand at a glance

## Phase 4: Historical Data Loading

### Task 4.1: Create Market Bar Ecto Schema

**Objective:** Ecto schema for market_bars table with validations.

**Location:** `~/signal/lib/signal/market_data/bar.ex`

**Schema Definition:**
```elixir
defmodule Signal.MarketData.Bar do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "market_bars" do
    field :symbol, :string, primary_key: true
    field :bar_time, :utc_datetime_usec, primary_key: true
    field :open, :decimal
    field :high, :decimal
    field :low, :decimal
    field :close, :decimal
    field :volume, :integer
    field :vwap, :decimal
    field :trade_count, :integer
  end
end
```

**Changeset Function:**
```elixir
def changeset(bar, attrs) do
  bar
  |> cast(attrs, [:symbol, :bar_time, :open, :high, :low, :close, :volume, :vwap, :trade_count])
  |> validate_required([:symbol, :bar_time, :open, :high, :low, :close, :volume])
  |> validate_ohlc_relationships()
  |> validate_number(:volume, greater_than_or_equal_to: 0)
  |> validate_number(:trade_count, greater_than_or_equal_to: 0)
end

defp validate_ohlc_relationships(changeset) do
  open = get_field(changeset, :open)
  high = get_field(changeset, :high)
  low = get_field(changeset, :low)
  close = get_field(changeset, :close)

  cond do
    is_nil(open) or is_nil(high) or is_nil(low) or is_nil(close) ->
      changeset
    
    Decimal.lt?(high, open) or Decimal.lt?(high, close) ->
      add_error(changeset, :high, "must be >= open and close")
    
    Decimal.gt?(low, open) or Decimal.gt?(low, close) ->
      add_error(changeset, :low, "must be <= open and close")
    
    true ->
      changeset
  end
end
```

**Helper Functions:**

`from_alpaca/2` - Convert Alpaca bar to schema
- Parameters: symbol (string), bar (map from Alpaca.Client)
- Returns: Bar struct
- Maps Alpaca fields to schema fields
```elixir
def from_alpaca(symbol, alpaca_bar) do
  %__MODULE__{
    symbol: symbol,
    bar_time: alpaca_bar.timestamp,
    open: alpaca_bar.open,
    high: alpaca_bar.high,
    low: alpaca_bar.low,
    close: alpaca_bar.close,
    volume: alpaca_bar.volume,
    vwap: alpaca_bar.vwap,
    trade_count: alpaca_bar.trade_count
  }
end
```

`to_map/1` - Convert schema to plain map
- Parameters: Bar struct
- Returns: map
```elixir
def to_map(%__MODULE__{} = bar) do
  Map.from_struct(bar)
end
```

**Success Criteria:**
- Schema compiles
- Can create changesets
- Validations work correctly (OHLC relationships)
- Can insert via Ecto
- from_alpaca/2 handles Alpaca data correctly
- Changeset catches invalid data

### Task 4.2: Create Historical Loader Module

**Objective:** Download and store historical bar data from Alpaca with incremental/resumable loading.

**Location:** `~/signal/lib/signal/market_data/historical_loader.ex`

**Requirements:**
- Use Signal.Alpaca.Client to fetch bars
- Store in market_bars table via Ecto
- Support incremental loading (year by year)
- Batch inserts for efficiency (1000 bars per insert)
- Check for existing data to avoid duplicates
- Progress tracking and logging
- Resumable if interrupted

**Public API:**

`load_bars/3` - Load bars for symbols and date range
- Parameters:
  - symbols: list of strings or single string
  - start_date: Date or DateTime
  - end_date: Date or DateTime (default: today)
- Returns: `{:ok, %{symbol => count}}` or `{:error, reason}`
- Loads incrementally year by year
- Logs progress every 10,000 bars

`load_all/2` - Load bars for all configured symbols
- Parameters:
  - start_date: Date or DateTime
  - end_date: Date or DateTime (default: today)
- Returns: `{:ok, total_count}` or `{:error, reason}`
- Gets symbols from Application config
- Calls load_bars/3 for each symbol with parallel loading

`check_coverage/2` - Check data coverage for symbol
- Parameters:
  - symbol: string
  - date_range: {start_date, end_date}
- Returns: `{:ok, %{bars_count: int, missing_years: [integer], coverage_pct: float}}`

**Implementation Strategy:**

**Incremental Loading by Year:**
For each symbol:
1. Query existing data to find which years are already loaded
2. For each missing year:
   - Call Alpaca.Client.get_bars/2 for that year
   - Pagination handled by Client
   - Convert to Bar structs
   - Batch insert 1000 bars at a time
   - Log: "AAPL: 2020 complete (98,234 bars)"
3. Return summary

**Why year-by-year:**
- Resumable - if fails mid-load, already-loaded years remain
- Clear progress tracking
- Easier to fill gaps later
- Better error handling

**Coverage Check:**
```sql
SELECT 
  COUNT(*) as total_bars,
  EXTRACT(YEAR FROM bar_time) as year,
  COUNT(*) as bars_in_year
FROM market_bars
WHERE symbol = ?
  AND bar_time BETWEEN ? AND ?
GROUP BY year
ORDER BY year
```

**Batch Insert Implementation:**
```elixir
bars
|> Enum.chunk_every(1000)
|> Enum.each(fn batch ->
  maps = Enum.map(batch, &Map.from_struct/1)
  Signal.Repo.insert_all(Signal.MarketData.Bar, maps, 
    on_conflict: :nothing,
    conflict_target: [:symbol, :bar_time]
  )
end)
```

**Parallel Loading:**
```elixir
symbols
|> Task.async_stream(
  fn symbol -> load_bars(symbol, start_date, end_date) end,
  max_concurrency: 5,
  timeout: :infinity
)
|> Enum.map(fn {:ok, result} -> result end)
```

Max concurrency: 5 to stay under Alpaca rate limits

**Error Handling:**
- Network errors: retry up to 3 times with 5s delay
- Invalid data: log warning with bar details, skip that bar, continue
- Database errors: stop and return error
- Partial success: return what was loaded with details

**Progress Logging:**
```
[HistoricalLoader] Loading AAPL from 2019-11-15 to 2024-11-15...
[HistoricalLoader] AAPL: Checking existing coverage...
[HistoricalLoader] AAPL: Found 245,123 bars (2022-2024), missing: 2019-2021
[HistoricalLoader] AAPL: Loading 2019... 98,234 bars (12.3s)
[HistoricalLoader] AAPL: Loading 2020... 97,456 bars (11.8s)
[HistoricalLoader] AAPL: Loading 2021... 98,567 bars (12.1s)
[HistoricalLoader] AAPL: Complete - 294,257 new bars loaded in 36.2s
```

**Success Criteria:**
- Can download 5 years of data for one symbol
- Loads incrementally year by year
- Handles large datasets (500k+ bars)
- Batch inserts work efficiently
- Doesn't re-download existing data
- Logs progress clearly with year-by-year updates
- Works for multiple symbols in parallel
- Idempotent (safe to re-run)
- Resumable if interrupted

### Task 4.3: Create Mix Task for Data Loading

**Objective:** CLI task to load historical data with flexible options.

**Location:** `~/signal/lib/mix/tasks/signal.load_data.ex`

**Options:**
- `--symbols AAPL,TSLA` - Comma-separated list (default: all configured)
- `--start-date 2019-11-15` - YYYY-MM-DD format (default: 5 years ago)
- `--end-date 2024-11-15` - YYYY-MM-DD format (default: today)
- `--year 2024` - Load specific year only
- `--check-only` - Check coverage without downloading

**Usage Examples:**
```bash
# Load all symbols for 5 years (default)
mix signal.load_data

# Load specific symbols
mix signal.load_data --symbols AAPL,TSLA,NVDA

# Load custom date range
mix signal.load_data --symbols AAPL --start-date 2020-01-01 --end-date 2020-12-31

# Load specific year only
mix signal.load_data --year 2024

# Check coverage without downloading
mix signal.load_data --check-only

# Load one year for all symbols (incremental approach)
mix signal.load_data --year 2023
```

**Output Format:**
```
Signal Historical Data Loader
=============================
Symbols: AAPL, TSLA, NVDA, PLTR, ... (15 total)
Date Range: 2019-11-15 to 2024-11-15 (5 years)

Checking existing coverage...

Loading data...
[1/15] AAPL: 294,257 new bars loaded (2019-2021) in 36s
[2/15] TSLA: 289,123 new bars loaded (2019-2021) in 34s
[3/15] NVDA: 301,234 new bars loaded (2019-2021) in 37s
...

Summary:
========
Total bars loaded: 4,234,567
Total time: 12 minutes 34 seconds
Average: 5,615 bars/second
```

**Implementation:**
- Use OptionParser to parse arguments
- Validate dates (parse with Date.from_iso8601!)
- Get symbol list (from args or config)
- Ensure Repo started: `Mix.Task.run("app.start")`
- Call HistoricalLoader.load_all or load_bars
- Display results with nice formatting
- Handle errors gracefully with helpful messages

**For --year option:**
- Convert to date range: Jan 1 - Dec 31 of that year
- Useful for incremental loading

**For --check-only:**
- Call HistoricalLoader.check_coverage for each symbol
- Display coverage report:
  ```
  Coverage Report:
  AAPL: 487,234 bars (2019-2024) - 99.8% coverage
  Missing: 234 bars in 2020-03-15 to 2020-03-17
  ```

**Success Criteria:**
- Task runs from command line
- Parses all options correctly
- Shows clear progress
- Displays helpful summary
- Handles errors with clear messages
- --year option enables incremental loading
- --check-only shows coverage without downloading

### Task 4.4: Create Data Verification Module

**Objective:** Verify data quality and identify issues.

**Location:** `~/signal/lib/signal/market_data/verifier.ex`

**Public API:**

`verify_symbol/1` - Verify data for one symbol
- Parameters: symbol string
- Returns: `{:ok, report_map}` or `{:error, reason}`

`verify_all/0` - Verify all configured symbols
- Returns: `{:ok, [report_map]}`

**Checks to Perform:**

1. **OHLC Relationships:**
   ```sql
   SELECT COUNT(*) FROM market_bars
   WHERE symbol = ?
     AND (high < open OR high < close OR low > open OR low > close)
   ```
   - Count violations
   - Return first 5 examples with details

2. **Gaps in Data:**
   - Find missing minutes during market hours (9:30-16:00 ET on weekdays)
   - Exclude weekends using tz library date functions
   - Exclude market holidays (use tz library or simple holiday list)
   - Query for missing minute gaps:
   ```sql
   SELECT bar_time, 
          LEAD(bar_time) OVER (ORDER BY bar_time) as next_bar,
          EXTRACT(EPOCH FROM (LEAD(bar_time) OVER (ORDER BY bar_time) - bar_time))/60 as gap_minutes
   FROM market_bars
   WHERE symbol = ?
     AND gap_minutes > 1
   ```
   - Report gap count, largest gap

3. **Duplicate Bars:**
   - Should be 0 (enforced by primary key)
   - But check anyway:
   ```sql
   SELECT symbol, bar_time, COUNT(*) 
   FROM market_bars 
   WHERE symbol = ?
   GROUP BY symbol, bar_time 
   HAVING COUNT(*) > 1
   ```

4. **Statistics:**
   ```sql
   SELECT 
     COUNT(*) as total_bars,
     MIN(bar_time) as earliest,
     MAX(bar_time) as latest,
     AVG(volume) as avg_volume,
     COUNT(DISTINCT DATE(bar_time)) as trading_days
   FROM market_bars
   WHERE symbol = ?
   ```

**Report Format:**
```elixir
%{
  symbol: "AAPL",
  total_bars: 487_234,
  date_range: {~D[2019-11-15], ~D[2024-11-15]},
  issues: [
    %{
      type: :ohlc_violation,
      count: 3,
      examples: [
        %{bar_time: ~U[...], open: 100, high: 99, ...}
      ]
    },
    %{
      type: :gaps,
      count: 12,
      largest: %{
        start: ~U[2020-03-15 14:30:00Z],
        end: ~U[2020-03-15 15:00:00Z],
        missing_minutes: 30
      }
    },
    %{type: :duplicate_bars, count: 0}
  ],
  coverage: %{
    expected_bars: 487_500,  # Based on trading days * 390 min/day
    actual_bars: 487_234,
    coverage_pct: 99.95
  }
}
```

**Expected Trading Days Calculation:**
- Use tz library to count weekdays between dates
- Subtract known market holidays
- Multiply by 390 minutes (6.5 hours)
- Compare to actual bar count

**Success Criteria:**
- Identifies OHLC violations
- Finds gaps in data (considering market hours and holidays)
- Reports accurate statistics
- Clear output format
- Helps validate data integrity
- Can identify specific problematic dates

## Phase 5: Monitoring, Testing & Documentation

### Task 5.1: Add Monitoring to Dashboard

**Objective:** Display system metrics in LiveView dashboard.

**Location:** Update `~/signal_web/live/market_live.ex`

**Requirements:**
- Subscribe to "system:stats" PubSub topic in mount
- Handle incoming stats messages
- Pass to SystemStats component
- Calculate and display health status

**Additional Handle Info:**

For system stats from "system:stats" PubSub:
```elixir
def handle_info(stats_map, socket) do
  {:noreply, assign(socket, :system_stats, stats_map)}
end
```

**Health Calculation:**
```elixir
defp calculate_overall_health(stats, connection_status) do
  cond do
    connection_status == :disconnected -> :error
    not stats.db_healthy -> :error
    stats.quotes_per_sec == 0 and market_open?() -> :degraded
    stats.bars_per_min == 0 and market_open?() -> :degraded
    connection_status == :reconnecting -> :degraded
    true -> :healthy
  end
end

defp market_open? do
  now = DateTime.now!("America/New_York")
  time = DateTime.to_time(now)
  day = Date.day_of_week(DateTime.to_date(now))
  
  # Monday-Friday, 9:30am-4:00pm ET
  day >= 1 and day <= 5 and 
    Time.compare(time, ~T[09:30:00]) != :lt and 
    Time.compare(time, ~T[16:00:00]) != :gt
end
```

**Template Update:**
Add SystemStats component at top of page:
```heex
<.system_stats 
  connection_status={@connection_status}
  connection_details={@connection_details}
  stats={@system_stats}
/>
```

**Success Criteria:**
- System stats display correctly in dashboard
- Updates every 60 seconds
- Health status accurate based on current conditions
- Shows connection attempt count when reconnecting
- Integrated seamlessly with symbol table
- Time ago displays work ("Last quote: 2s ago")

### Task 5.2: Create Integration Tests

**Objective:** Test end-to-end data flow.

**Location:** `~/signal/test/signal/integration_test.exs`

**Requirements:**
- Test with Alpaca test stream (wss://stream.data.alpaca.markets/v2/test)
- Use FAKEPACA symbol
- Verify complete data flow
- Can be skipped if no credentials

**Tests:**

`@tag :integration` on all tests (requires credentials)

**Test 1: WebSocket Connection and Data Flow**
```elixir
test "connects to Alpaca test stream and receives data" do
  # Start test stream to test endpoint
  {:ok, pid} = Signal.Alpaca.Stream.start_link(
    callback_module: TestCallback,
    callback_state: %{messages: []},
    initial_subscriptions: %{bars: ["FAKEPACA"], quotes: ["FAKEPACA"]}
  )
  
  # Wait for connection
  Process.sleep(5000)
  
  # Should have received messages
  state = TestCallback.get_state(pid)
  assert length(state.messages) > 0
  
  # Should have quotes and bars
  assert Enum.any?(state.messages, fn m -> m.type == :quote end)
  assert Enum.any?(state.messages, fn m -> m.type == :bar end)
end
```

**Test 2: BarCache Integration**
```elixir
test "updates BarCache with incoming data" do
  # Subscribe a test symbol
  # ... start stream ...
  
  # Wait for data
  Process.sleep(5000)
  
  # Check BarCache was updated
  {:ok, data} = Signal.BarCache.get(:FAKEPACA)
  assert data.last_quote != nil
  assert data.last_bar != nil
end
```

**Test 3: PubSub Message Flow**
```elixir
test "broadcasts messages to PubSub" do
  # Subscribe to PubSub topics
  Phoenix.PubSub.subscribe(Signal.PubSub, "quotes:FAKEPACA")
  Phoenix.PubSub.subscribe(Signal.PubSub, "bars:FAKEPACA")
  
  # ... start stream ...
  
  # Should receive PubSub messages
  assert_receive {:quote, "FAKEPACA", _quote}, 10_000
  assert_receive {:bar, "FAKEPACA", _bar}, 60_000
end
```

**Test 4: Bar Storage and Retrieval**
```elixir
test "stores and retrieves bars from database" do
  # Create test bar
  bar = %Signal.MarketData.Bar{
    symbol: "TEST",
    bar_time: ~U[2024-11-15 14:30:00Z],
    open: Decimal.new("100.00"),
    high: Decimal.new("101.00"),
    low: Decimal.new("99.00"),
    close: Decimal.new("100.50"),
    volume: 1000
  }
  
  # Insert
  {:ok, _} = Signal.Repo.insert(bar)
  
  # Query back
  result = Signal.Repo.get_by(Signal.MarketData.Bar, 
    symbol: "TEST", 
    bar_time: ~U[2024-11-15 14:30:00Z]
  )
  
  assert result.symbol == "TEST"
  assert Decimal.equal?(result.open, Decimal.new("100.00"))
end
```

**Test 5: Historical Loader (with mocked Client)**
```elixir
test "loads historical bars" do
  # This would use mocked Alpaca.Client
  # Or test with real API in integration mode
  # ...
end
```

**Test Helpers:**

`test/support/test_callback.ex`:
```elixir
defmodule Signal.TestCallback do
  @behaviour Signal.Alpaca.Stream
  
  def start_link(initial_state) do
    Agent.start_link(fn -> initial_state end, name: __MODULE__)
  end
  
  def handle_message(message, state) do
    new_messages = [message | state.messages]
    {:ok, %{state | messages: new_messages}}
  end
  
  def get_state(_pid) do
    Agent.get(__MODULE__, & &1)
  end
end
```

**Run Commands:**
```bash
# Skip integration tests (default)
mix test

# Run integration tests (needs credentials)
mix test --include integration

# Run only integration tests
mix test --only integration
```

**Success Criteria:**
- Integration tests pass with real Alpaca test stream
- Tests verify complete data flow
- Can test WebSocket without affecting real subscriptions
- Tests are isolated and repeatable
- Clear instructions for running with credentials

### Task 5.3: Create Mock Stream for Testing

**Objective:** Allow UI development and testing without Alpaca credentials.

**Location:** `~/signal/lib/signal/alpaca/mock_stream.ex`

**Requirements:**
- Implements same interface as Alpaca.Stream
- Generates fake quotes and bars on timer
- Configurable symbol list
- Useful for development without credentials

**Implementation:**

GenServer that:
- Accepts same start_link/1 parameters as real Stream
- On init, starts timer to generate fake data every 1-5 seconds
- Generates random price movements
- Calls callback_module.handle_message/2 with fake data

**Configuration (in config/dev.exs):**
```elixir
config :signal,
  use_mock_stream: false  # Set to true to use mock
```

**In Application.ex:**
```elixir
# Conditionally choose which stream to start
stream_module = if Application.get_env(:signal, :use_mock_stream, false) do
  Signal.Alpaca.MockStream
else
  Signal.Alpaca.Stream
end

children = [
  # ...
  {stream_module, stream_config}
]
```

**Mock Data Generation:**
```elixir
defp generate_fake_quote(symbol, last_price) do
  # Random walk
  change = :rand.uniform() * 2 - 1  # -1 to +1
  new_price = Decimal.add(last_price, Decimal.new(Float.to_string(change)))
  
  %{
    type: :quote,
    symbol: symbol,
    bid_price: Decimal.sub(new_price, Decimal.new("0.02")),
    ask_price: Decimal.add(new_price, Decimal.new("0.02")),
    bid_size: :rand.uniform(500),
    ask_size: :rand.uniform(500),
    timestamp: DateTime.utc_now()
  }
end
```

**Success Criteria:**
- Can develop UI without Alpaca credentials
- Mock generates realistic data
- Dashboard works with mock stream
- Easy to toggle between mock and real
- Useful for testing and demos

### Task 5.4: Create Comprehensive README

**Objective:** Complete project documentation.

**Location:** `~/signal/README.md`

**Content Sections:**

**1. Project Overview**
- What Signal does
- Key features (real-time streaming, historical data, event sourcing)
- Architecture diagram (simple ASCII or link to diagram)

**2. Prerequisites**
- Elixir 1.15+
- Docker (for TimescaleDB)
- Alpaca Markets account (paper trading free)

**3. Quick Start**
```bash
# Clone and setup
git clone ...
cd signal
mix deps.get

# Set up environment
cp .env.example .env
# Edit .env with your Alpaca credentials

# Start database
docker-compose up -d

# Create and migrate database
mix ecto.create
mix ecto.migrate

# Start the application
source .env
mix phx.server

# Visit http://localhost:4000
```

**4. Configuration**

Environment variables:
```
ALPACA_API_KEY=your_key
ALPACA_API_SECRET=your_secret
ALPACA_BASE_URL=https://paper-api.alpaca.markets
ALPACA_WS_URL=wss://stream.data.alpaca.markets/v2/iex
```

Symbols (in config/dev.exs):
```elixir
config :signal, symbols: [:AAPL, :TSLA, ...]
```

**5. Loading Historical Data**

Recommended incremental approach:
```bash
# Load most recent year first (fast validation)
mix signal.load_data --year 2024

# Then load remaining years
mix signal.load_data --year 2023
mix signal.load_data --year 2022
# etc.

# Or load all at once (takes 2-4 hours)
mix signal.load_data
```

**6. Architecture**

Brief explanation:
- Alpaca integration (WebSocket + REST)
- BarCache (ETS for fast access)
- Event sourcing (events table)
- LiveView dashboard (real-time UI)
- TimescaleDB (time-series storage)
- Monitor (health tracking)

**7. Development**

Running tests:
```bash
mix test
mix test --include integration  # With Alpaca credentials
```

Mock stream for development:
```elixir
# In config/dev.exs
config :signal, use_mock_stream: true
```

Adding new symbols:
```elixir
# In config/dev.exs
config :signal, symbols: [:AAPL, :NEW_SYMBOL, ...]
```

**8. Project Structure**
```
lib/signal/
  alpaca/           - Alpaca integration
  market_data/      - Market data domain
  bar_cache.ex      - ETS cache
  monitor.ex        - System monitoring
lib/signal_web/
  live/             - LiveView pages
```

**9. Troubleshooting**

Common issues:
- **"Dashboard shows no data"**
  - Check Alpaca credentials are set
  - Check connection status on dashboard
  - Verify `Signal.Alpaca.Config.configured?()` returns true
  - Check logs for connection errors

- **"Stream keeps disconnecting"**
  - Check network connection
  - Check Alpaca status page: status.alpaca.markets
  - Check rate limits not exceeded
  - Review logs for error messages

- **"Historical load is slow"**
  - Expected: 2-4 hours for 5 years of data
  - Use incremental loading with `--year` flag
  - Can load in background while system runs

- **"BarCache is empty"**
  - System just started, wait 10-30 seconds for first messages
  - Check WebSocket connection status
  - Verify symbols are configured correctly

- **"Seeing duplicate bars"**
  - Check system clock is correct
  - Verify timezone configuration

**10. Time Zone Handling**

All times stored in UTC:
- Database: UTC timestamps
- BarCache: UTC timestamps
- Events: UTC timestamps

Convert to ET only for:
- Display in dashboard
- Market hours calculations

**11. Roadmap**

Phase 2 (Next):
- Market regime detection
- Technical indicators
- Strategy signals

Phase 3:
- Portfolio management
- Risk management
- Order execution

Phase 4:
- Break & retest strategy
- Signal generation
- Backtesting engine

**12. Contributing**
- Code style guide
- PR process
- Testing requirements

**13. License**
MIT (or your choice)

**Success Criteria:**
- Another developer can set up from README alone
- All steps are clear and tested
- Troubleshooting covers common issues
- Architecture is explained
- Examples are copy-pasteable
- Professional and complete

### Task 5.5: Add Module Documentation

**Objective:** Complete @moduledoc, @doc, and @spec for all modules.

**Location:** All modules in lib/signal/ and lib/signal_web/

**Standards:**

Every module needs:
```elixir
@moduledoc """
Brief description of module purpose.

## Examples

    iex> MyModule.my_function("arg")
    {:ok, result}
"""
```

Every public function needs:
```elixir
@doc """
One-line summary.

Longer description if needed.

## Parameters

  - `param1` - Description of param1
  - `param2` - Description of param2

## Returns

  - `{:ok, result}` on success
  - `{:error, reason}` on failure

## Examples

    iex> MyModule.my_function(param1, param2)
    {:ok, result}
"""
@spec my_function(String.t(), integer()) :: {:ok, any()} | {:error, atom()}
def my_function(param1, param2) do
  # ...
end
```

**Priority modules to document:**
- Signal.Alpaca.Config
- Signal.Alpaca.Client
- Signal.Alpaca.Stream
- Signal.BarCache
- Signal.Monitor
- Signal.MarketData.Bar
- Signal.MarketData.HistoricalLoader
- Signal.MarketData.Verifier

**Success Criteria:**
- All public APIs have @doc
- All public functions have @spec
- Examples are runnable and accurate
- Can generate docs: `mix docs` (requires ex_doc dependency)
- Documentation is helpful and clear

## Expected Behavior Notes

### Gap Handling
WebSocket disconnects cause brief data gaps (seconds to minutes). This is expected:
- System designed for real-time trading, not perfect historical replay
- Gaps during reconnection are acceptable
- Historical data from database is gap-free for backtesting
- Real-time data from stream may have small gaps

### Startup Behavior
- If Alpaca unavailable on startup, Stream retries indefinitely with exponential backoff
- Application still starts successfully
- Dashboard shows "disconnected" status
- Once Alpaca available, Stream connects automatically
- This is correct and expected behavior

### Data Flow Timing
- First data appears 10-30 seconds after application start
- BarCache populates as messages arrive
- Dashboard updates in real-time
- If no data after 1 minute, check connection status and credentials

## Implementation Order (Revised)

Execute in this sequence:

**Week 1: Core Infrastructure & Real-Time System**
1. Task 1.1: Add dependencies
2. Task 1.2: Market bars migration
3. Task 1.3: Events table migration
4. Task 1.4: BarCache module
5. Task 1.5: Monitor module
6. Task 2.1: Alpaca config
7. Task 2.2: Alpaca client (REST)
8. Task 2.3: Alpaca stream (WebSocket)
9. Task 2.4: Stream handler
10. Task 2.5: Stream supervisor
11. Task 2.6: Update supervision tree
12. Task 2.7: Configure credentials

**⭐ CHECKPOINT: Test real-time system works**

**Week 2: Dashboard & Verification**
13. Task 3.1: Market LiveView
14. Task 3.2: Add route
15. Task 3.3: System stats component
16. Task 5.1: Add monitoring to dashboard

**⭐ CHECKPOINT: Dashboard shows live data, looks good**

**Week 2-3: Historical Data**
17. Task 4.1: Bar schema
18. Task 4.2: Historical loader
19. Task 4.3: Mix task
20. Task 4.4: Verifier

**Week 3: Testing & Polish**
21. Task 5.2: Integration tests
22. Task 5.3: Mock stream
23. Task 5.4: README
24. Task 5.5: Module docs

## Success Criteria for Phase 1 Completion

System should:
- ✅ Connect to Alpaca WebSocket and receive live data
- ✅ Display real-time prices in professional dashboard
- ✅ Store bars in TimescaleDB hypertable with compression
- ✅ Load 5 years of historical data incrementally
- ✅ Deduplicate unchanged quotes (reduce noise)
- ✅ Monitor system health with database checks
- ✅ Handle reconnections gracefully with exponential backoff
- ✅ Track metrics and detect anomalies
- ✅ Run stably for extended periods
- ✅ Have comprehensive documentation
- ✅ Support testing without Alpaca credentials (mock stream)
- ✅ Provide clear troubleshooting guidance

## Historical Data Volume

Expected for 5 years:
- 5 years × 252 trading days/year × 390 min/day ≈ 490,800 bars per symbol
- 15 symbols × 490,800 ≈ 7.4M bars total
- ~740 MB uncompressed
- TimescaleDB compression reduces to ~150-200 MB
- Initial load time: 2-4 hours (or faster with incremental loading)

## Important Implementation Notes

**Code Quality:**
- Follow Elixir conventions (snake_case, pattern matching)
- Pattern matching over conditionals where possible
- Tagged tuples for errors `{:ok, result}` or `{:error, reason}`
- Pure functions where possible
- Comprehensive @spec and @doc for public APIs
- Keep functions small (<20 lines ideal)
- One clear purpose per module

**Testing:**
- Unit tests for pure functions
- Integration tests for external APIs (tagged :integration)
- Mock external dependencies
- Test error cases
- Use ExUnit async: true where safe
- Aim for >80% test coverage

**Performance:**
- Trust modern Elixir/BEAM to handle message volume
- Use ETS for frequently accessed data (BarCache)
- Batch database operations (1000 rows at a time)
- Use read_concurrency for ETS
- Don't premature optimize - measure first

**Security:**
- Never commit API credentials
- Use environment variables exclusively
- Keep secrets out of logs
- Sanitize error messages sent to users
- Validate all external data

This completes the comprehensive Phase 1 implementation plan with all improvements integrated!
