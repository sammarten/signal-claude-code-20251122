# Signal - Real-Time Day Trading System

**Signal** is a real-time day trading system built with Elixir/Phoenix that streams market data from Alpaca Markets, performs technical analysis, generates trading signals, and executes trades.

## 🌟 Key Features

- **Real-time Market Data Streaming** - WebSocket connection to Alpaca Markets for live quotes and bars
- **Event Sourcing Architecture** - Complete audit trail of all system events
- **TimescaleDB Integration** - Efficient storage and querying of time-series data
- **LiveView Dashboard** - Real-time visualization of market data and system health
- **Historical Data Loading** - Incremental loading of 5+ years of minute-bar data
- **System Monitoring** - Health checks, anomaly detection, and performance metrics
- **Mock Stream** - Develop and test without API credentials

## 📋 Prerequisites

- **Elixir** 1.15+ and Erlang/OTP 26+
- **Docker** (for TimescaleDB)
- **Alpaca Markets Account** (free paper trading account)
  - Sign up at [alpaca.markets](https://alpaca.markets)
  - Get API credentials from dashboard

## 🚀 Quick Start

### 1. Clone and Setup

```bash
# Clone the repository
git clone <repository-url>
cd signal

# Install dependencies
mix deps.get
```

### 2. Configure Environment

```bash
# Copy environment template
cp .env.example .env

# Edit .env with your Alpaca credentials
nano .env
```

Required environment variables:
```bash
export ALPACA_API_KEY_ID="your_key_here"
export ALPACA_API_SECRET_KEY="your_secret_here"
export ALPACA_BASE_URL="https://paper-api.alpaca.markets"
export ALPACA_WS_URL="wss://stream.data.alpaca.markets/v2/sip"
```

### 3. Start Database

```bash
# Start TimescaleDB with Docker
docker-compose up -d

# Verify database is running
docker ps
```

### 4. Setup Database

```bash
# Create and migrate database
mix ecto.create
mix ecto.migrate
```

### 5. Start Application

```bash
# Load environment variables
source .env

# Start Phoenix server
mix phx.server

# Or start with IEx for interactive development
iex -S mix phx.server
```

### 6. Access Dashboard

Open [http://localhost:4000](http://localhost:4000) in your browser.

You should see:
- Real-time price updates within 10-30 seconds
- Connection status (green = connected)
- System health metrics
- Live quotes and bars for configured symbols

## ⚙️ Configuration

### Symbols

Configure which stocks to track in `config/dev.exs`:

```elixir
config :signal,
  symbols: [
    # Tech stocks
    "AAPL", "TSLA", "NVDA", "PLTR", "GOOGL", "MSFT",
    "AMZN", "META", "AMD", "NFLX", "CRM", "ADBE",
    # Index ETFs
    "SPY", "QQQ", "SMH", "DIA", "IWM"
  ],
  market_open: ~T[09:30:00],
  market_close: ~T[16:00:00],
  timezone: "America/New_York"
```

### Mock Stream (Development Mode)

Develop without Alpaca credentials by enabling mock stream:

```elixir
# In config/dev.exs
config :signal,
  use_mock_stream: true  # Set to true for development without credentials
```

The mock stream generates realistic fake market data for all configured symbols.

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `ALPACA_API_KEY_ID` | Alpaca API key | Required |
| `ALPACA_API_SECRET_KEY` | Alpaca API secret | Required |
| `ALPACA_BASE_URL` | REST API endpoint | `https://paper-api.alpaca.markets` |
| `ALPACA_WS_URL` | WebSocket endpoint | `wss://stream.data.alpaca.markets/v2/sip` |

**Note:** Use `wss://stream.data.alpaca.markets/v2/iex` for free IEx data feed (delayed quotes).

## 📊 Loading Historical Data

Signal supports incremental loading of historical data year-by-year. This approach is **recommended** for large datasets.

### Quick Validation (Load Recent Data First)

```bash
# Load most recent year first (fastest, validates setup)
mix signal.load_data --year 2024

# Verify data loaded correctly
iex -S mix
iex> Signal.MarketData.Verifier.verify_symbol("AAPL")
```

### Incremental Loading (Recommended)

```bash
# Load year by year (resumable if interrupted)
mix signal.load_data --year 2023
mix signal.load_data --year 2022
mix signal.load_data --year 2021
mix signal.load_data --year 2020

# Or load specific date range
mix signal.load_data --start-date 2020-01-01 --end-date 2020-12-31
```

### Load All Data at Once

```bash
# Load 5 years for all configured symbols (takes 2-4 hours)
mix signal.load_data

# Load specific symbols only
mix signal.load_data --symbols AAPL,TSLA,NVDA
```

### Check Data Coverage

```bash
# Check coverage without downloading
mix signal.load_data --check-only
```

**Expected data volume:**
- ~490,000 bars per symbol for 5 years
- ~7.4M bars total for 15 symbols
- ~150-200 MB with TimescaleDB compression
- Initial load time: 2-4 hours (or faster with incremental loading)

## 🏗️ Architecture

### Component Overview

```
┌─────────────────────────────────────────────────────────────┐
│                     Phoenix LiveView                         │
│                    (Real-time Dashboard)                     │
└─────────────────┬───────────────────────────────────────────┘
                  │
                  ├─> Phoenix.PubSub (Event Distribution)
                  │
┌─────────────────┴───────────────────────────────────────────┐
│                                                               │
│  ┌──────────────┐    ┌─────────────┐    ┌──────────────┐   │
│  │   BarCache   │    │   Monitor   │    │ StreamHandler│   │
│  │     (ETS)    │<───│  (Metrics)  │<───│  (Callback)  │   │
│  └──────────────┘    └─────────────┘    └──────┬───────┘   │
│                                                  │            │
│                                         ┌────────┴────────┐  │
│                                         │ Alpaca.Stream   │  │
│                                         │   (WebSocket)   │  │
│                                         └────────┬────────┘  │
│                                                  │            │
└──────────────────────────────────────────────────┼───────────┘
                                                   │
                                         ┌─────────┴─────────┐
                                         │  Alpaca Markets   │
                                         │   (Data Feed)     │
                                         └───────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                       TimescaleDB                            │
│                  (Historical Bar Storage)                    │
└─────────────────────────────────────────────────────────────┘
```

### Key Components

- **Alpaca.Stream** - WebSocket client for real-time market data
- **StreamHandler** - Processes incoming messages, updates cache, publishes events
- **BarCache** - ETS table for O(1) access to latest quotes and bars
- **Monitor** - Tracks system health, message rates, and anomalies
- **MarketLive** - LiveView dashboard with real-time updates
- **HistoricalLoader** - Incremental loading of historical bar data
- **TimescaleDB** - Hypertable storage with compression and retention policies

## 👨‍💻 Development

### Running Tests

```bash
# Run all tests (skips integration tests by default)
mix test

# Run integration tests (requires Alpaca credentials)
mix test --include integration

# Run only integration tests
mix test --only integration

# Run with coverage
mix test --cover
```

### Using Mock Stream

Enable mock stream for development without credentials:

```elixir
# config/dev.exs
config :signal, use_mock_stream: true
```

Restart the server:
```bash
mix phx.server
```

The dashboard will show fake market data that updates every 1-5 seconds.

### Adding New Symbols

1. Update `config/dev.exs`:
```elixir
config :signal,
  symbols: ["AAPL", "NEW_SYMBOL", ...]
```

2. Restart the server:
```bash
mix phx.server
```

3. Load historical data for new symbol:
```bash
mix signal.load_data --symbols NEW_SYMBOL --year 2024
```

### Code Quality

```bash
# Check compilation with warnings as errors
mix compile --warnings-as-errors

# Format code
mix format

# Run static analysis (if configured)
mix credo
```

## 🔧 Troubleshooting

### Dashboard Shows No Data

**Symptoms:** Dashboard loads but shows "Loading..." or "-" for all symbols

**Solutions:**
1. Check Alpaca credentials are set:
   ```bash
   source .env
   echo $ALPACA_API_KEY_ID  # Should print your key
   ```

2. Check connection status in dashboard (top of page)
   - Should show "Connected" (green)
   - If "Disconnected" (red), check logs for errors

3. Verify configuration in IEx:
   ```elixir
   iex -S mix
   iex> Signal.Alpaca.Config.configured?()  # Should return true
   ```

4. Check logs for connection errors:
   ```bash
   tail -f log/dev.log
   ```

5. Wait 10-30 seconds for first data to arrive

### Stream Keeps Disconnecting

**Symptoms:** Connection status alternates between "Connected" and "Reconnecting"

**Solutions:**
1. Check network connection
2. Check Alpaca status: [status.alpaca.markets](https://status.alpaca.markets)
3. Verify not hitting rate limits (200 requests/minute for REST API)
4. Check logs for specific error messages
5. Try restarting the application

### Historical Load is Slow

**Symptoms:** `mix signal.load_data` takes very long or appears stuck

**Solutions:**
1. **Expected behavior:** Initial 5-year load takes 2-4 hours
2. Use incremental loading approach:
   ```bash
   # Load one year at a time
   mix signal.load_data --year 2024
   mix signal.load_data --year 2023
   ```
3. Reduce number of symbols if testing
4. Check network connection quality
5. Verify TimescaleDB is running:
   ```bash
   docker ps | grep timescale
   ```

### BarCache is Empty

**Symptoms:** `Signal.BarCache.get(:AAPL)` returns `{:error, :not_found}`

**Solutions:**
1. **Just started:** Wait 10-30 seconds for first messages from stream
2. Check WebSocket connection status:
   ```elixir
   Signal.Alpaca.Stream.status(Signal.Alpaca.Stream)
   ```
3. Verify symbols are configured correctly
4. Check if using mock stream (should still populate)
5. Review logs for errors during message processing

### Database Connection Errors

**Symptoms:** Errors mentioning Postgres or database connection

**Solutions:**
1. Ensure TimescaleDB is running:
   ```bash
   docker-compose up -d
   docker ps
   ```

2. Check database configuration in `config/dev.exs`
3. Verify port 5433 is not in use
4. Try recreating the database:
   ```bash
   mix ecto.drop
   mix ecto.create
   mix ecto.migrate
   ```

### Authentication Errors

**Symptoms:** "401 Unauthorized" or "403 Forbidden" in logs

**Solutions:**
1. Verify API credentials are correct
2. Check credentials have proper permissions in Alpaca dashboard
3. Ensure using paper trading credentials (not live)
4. Try regenerating API keys in Alpaca dashboard

## ⏰ Time Zone Handling

Signal follows a strict time zone strategy:

### Storage (UTC Everywhere)
- **Database:** All timestamps stored in UTC
- **BarCache:** All timestamps in UTC
- **Events:** All timestamps in UTC
- **Alpaca API:** Sends all timestamps in UTC

### Display (ET for User Interface)
- **Dashboard:** Converts to ET for display
- **Market Hours:** Calculations use ET (9:30 AM - 4:00 PM)
- **Reports:** Show times in ET

### Implementation
```elixir
# Store in UTC
bar_time = ~U[2024-11-15 14:30:00Z]

# Display in ET
et_time = DateTime.shift_zone!(bar_time, "America/New_York")
```

## 🗺️ Roadmap

### ✅ Phase 1: Core Infrastructure & Real-Time System (COMPLETE)
- Real-time market data streaming
- TimescaleDB hypertables
- LiveView dashboard
- Historical data loading
- System monitoring

### 📍 Phase 2: Technical Analysis (NEXT)
- Market regime detection
- Technical indicators (SMA, EMA, RSI, MACD, Bollinger Bands)
- Strategy signals
- Signal backtesting framework

### 🔜 Phase 3: Portfolio & Risk Management
- Portfolio tracking
- Position management
- Risk calculations
- Order execution

### 🚀 Phase 4: Trading Strategies
- Break & retest strategy
- Mean reversion strategies
- Trend following strategies
- Strategy optimization

## 📝 Project Structure

```
signal/
├── lib/
│   ├── signal/
│   │   ├── alpaca/              # Alpaca integration
│   │   │   ├── client.ex        # REST API client
│   │   │   ├── stream.ex        # WebSocket stream
│   │   │   ├── stream_handler.ex
│   │   │   ├── stream_supervisor.ex
│   │   │   ├── mock_stream.ex   # Mock for development
│   │   │   └── config.ex
│   │   ├── market_data/         # Market data domain
│   │   │   ├── bar.ex
│   │   │   ├── historical_loader.ex
│   │   │   └── verifier.ex
│   │   ├── bar_cache.ex         # ETS cache
│   │   ├── monitor.ex           # System monitoring
│   │   ├── repo.ex
│   │   └── application.ex
│   └── signal_web/
│       ├── live/                # LiveView pages
│       │   ├── market_live.ex
│       │   └── components/
│       │       └── system_stats.ex
│       └── router.ex
├── test/
│   ├── signal/
│   │   └── integration_test.exs  # Integration tests
│   └── support/
│       └── test_callback.ex      # Test helpers
├── config/
│   ├── dev.exs
│   ├── test.exs
│   └── runtime.exs
├── docker-compose.yml            # TimescaleDB
├── .env.example                  # Environment template
└── README.md
```

## 🤝 Contributing

Contributions are welcome! Please follow these guidelines:

1. **Fork the repository**
2. **Create a feature branch:** `git checkout -b feature/my-feature`
3. **Write tests** for new functionality
4. **Ensure all tests pass:** `mix test`
5. **Format code:** `mix format`
6. **Commit changes:** `git commit -am 'Add new feature'`
7. **Push to branch:** `git push origin feature/my-feature`
8. **Submit pull request**

### Code Style
- Follow [Elixir Style Guide](https://github.com/christopheradams/elixir_style_guide)
- Use pattern matching over conditionals
- Keep functions small (<20 lines ideal)
- Add @doc and @spec for all public functions
- Write comprehensive tests

## 📄 License

This project is licensed under the MIT License - see the LICENSE file for details.

## 🙏 Acknowledgments

- [Alpaca Markets](https://alpaca.markets) for market data API
- [Phoenix Framework](https://phoenixframework.org) for real-time web capabilities
- [TimescaleDB](https://www.timescale.com) for time-series database
- Elixir community for excellent libraries and support

## 📧 Support

- **Issues:** [GitHub Issues](https://github.com/your-username/signal/issues)
- **Discussions:** [GitHub Discussions](https://github.com/your-username/signal/discussions)
- **Documentation:** [Project Wiki](https://github.com/your-username/signal/wiki)

---

**Happy Trading! 📈**
