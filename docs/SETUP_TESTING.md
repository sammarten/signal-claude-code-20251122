# Setup and Testing Guide for Phase 1

## Prerequisites

You'll need to install Elixir in an environment with network access. Here are the options:

### Option 1: Local Development (Recommended)

Install Elixir using asdf (version manager):

```bash
# Install asdf
git clone https://github.com/asdf-vm/asdf.git ~/.asdf --branch v0.14.0
echo '. "$HOME/.asdf/asdf.sh"' >> ~/.bashrc
source ~/.bashrc

# Install Erlang and Elixir
asdf plugin add erlang
asdf plugin add elixir
asdf install erlang 26.2.5
asdf install elixir 1.17.3-otp-26
asdf global erlang 26.2.5
asdf global elixir 1.17.3-otp-26
```

### Option 2: Using Docker

```bash
# Pull Elixir image
docker pull elixir:1.17.3

# Run interactive shell in project directory
docker run -it --rm -v $(pwd):/app -w /app elixir:1.17.3 bash
```

### Option 3: Direct Installation (Ubuntu/Debian)

```bash
sudo apt-get update
sudo apt-get install -y elixir
```

## Step-by-Step Testing

Once Elixir is installed:

### 1. Install Dependencies

```bash
cd /home/user/signal-claude-code-20251122
mix deps.get
```

Expected output: All dependencies should download successfully, including:
- `websockex ~> 0.4.3`
- `tz ~> 0.26`
- All Phoenix dependencies

### 2. Compile the Project

```bash
mix compile
```

Expected output:
- All modules should compile without errors
- `lib/signal/bar_cache.ex` compiles
- `lib/signal/monitor.ex` compiles
- No warnings or errors

### 3. Start TimescaleDB

```bash
docker-compose up -d
```

Verify it's running:
```bash
docker-compose ps
# Should show timescaledb as "Up"
```

### 4. Run Database Migrations

```bash
mix ecto.create
mix ecto.migrate
```

Expected output:
- Database `signal_dev` created
- Migration `20251122221434_create_market_bars.exs` runs successfully
- Migration `20251122221504_create_events.exs` runs successfully

### 5. Verify Database Schema

Connect to the database:
```bash
docker exec -it signal_timescaledb psql -U postgres -d signal_dev
```

Check hypertables:
```sql
SELECT * FROM timescaledb_information.hypertables WHERE hypertable_name = 'market_bars';
```

Expected: One row showing the `market_bars` hypertable

Check compression settings:
```sql
SELECT * FROM timescaledb_information.compression_settings WHERE hypertable_name = 'market_bars';
```

Expected: Compression enabled with `segmentby = 'symbol'`

Exit psql:
```sql
\q
```

### 6. Test in IEx

Start interactive Elixir:
```bash
iex -S mix
```

Test BarCache:
```elixir
# BarCache should be running
{:ok, data} = Signal.BarCache.get(:AAPL)
# Expected: {:error, :not_found} (no data yet)

# Update a bar
bar = %{
  open: Decimal.new("185.20"),
  high: Decimal.new("185.60"),
  low: Decimal.new("184.90"),
  close: Decimal.new("185.45"),
  volume: 2_300_000,
  vwap: Decimal.new("185.32"),
  trade_count: 150,
  timestamp: DateTime.utc_now()
}
:ok = Signal.BarCache.update_bar(:AAPL, bar)

# Retrieve it
{:ok, data} = Signal.BarCache.get(:AAPL)
# Expected: {:ok, %{last_bar: %{...}, last_quote: nil}}

# Test current_price
price = Signal.BarCache.current_price(:AAPL)
# Expected: #Decimal<185.45>

# Get all symbols
Signal.BarCache.all_symbols()
# Expected: [:AAPL]
```

Test Monitor:
```elixir
# Monitor should be running
Signal.Monitor.track_message(:quote)
Signal.Monitor.track_message(:bar)

# Get current stats
stats = Signal.Monitor.get_stats()
# Expected: Map with counters, connection_status, etc.
```

Test database insertion:
```elixir
# Insert a test bar
alias Signal.Repo
alias Signal.MarketData.Bar

bar = %Bar{
  symbol: "TEST",
  bar_time: ~U[2024-11-15 14:30:00Z],
  open: Decimal.new("100.00"),
  high: Decimal.new("101.00"),
  low: Decimal.new("99.00"),
  close: Decimal.new("100.50"),
  volume: 1000,
  vwap: Decimal.new("100.25"),
  trade_count: 50
}

{:ok, _} = Repo.insert(bar)
# Expected: {:ok, %Bar{...}}

# Query it back
Repo.get_by(Bar, symbol: "TEST", bar_time: ~U[2024-11-15 14:30:00Z])
# Expected: %Bar{symbol: "TEST", ...}
```

## Success Criteria Checklist

- [ ] Dependencies install without errors
- [ ] Project compiles without warnings
- [ ] TimescaleDB container starts successfully
- [ ] Migrations run successfully
- [ ] `market_bars` hypertable is created with compression
- [ ] `events` table is created with proper indexes
- [ ] BarCache GenServer starts and responds to calls
- [ ] Monitor GenServer starts and tracks metrics
- [ ] Can insert and query bars from database
- [ ] No compilation warnings or errors
- [ ] All tests pass (when added in future phases)

## Common Issues and Solutions

### "mix: command not found"
- Elixir is not installed or not in PATH
- Run `elixir --version` to verify installation
- Source your shell config: `source ~/.bashrc`

### "could not compile dependency :decimal"
- Missing C compiler
- Install: `apt-get install build-essential` (Ubuntu)

### "connection refused" when running migrations
- TimescaleDB is not running
- Start it: `docker-compose up -d`
- Check: `docker-compose ps`

### "hypertable already exists"
- Running migrations twice
- Check migration status: `mix ecto.migrations`
- Rollback if needed: `mix ecto.rollback`

### BarCache or Monitor not starting
- Check Application supervision tree in `lib/signal/application.ex`
- These will be added in Task 2.6 (not yet implemented)
- For now, start manually in IEx: `Signal.BarCache.start_link([])`

## Next Steps

Once Phase 1 is verified, proceed to:
- **Phase 2**: Alpaca Integration (Tasks 2.1-2.7)
  - Alpaca Config module
  - Alpaca Client (REST API)
  - Alpaca Stream (WebSocket)
  - Stream Handler
  - Update supervision tree

All code is committed and pushed to branch: `claude/plan-project-task-one-01SZrw84CgRT7J8haabxNUrJ`
