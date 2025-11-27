# Phase 3 Project Plan: Backtesting & Strategy Validation

## Scope

**In Scope**:

- Historical data pipeline (configurable symbol list)
- Event-driven backtesting engine
- Trade simulation
- Comprehensive performance analytics
- Parameter tuning & walk-forward optimization
- Dashboard for results visualization

**Deferred to Phase 4**:

- Alpaca paper trading integration
- Live order execution
- Real-time P&L tracking

**Duration**: 5-6 weeks

---

## Task Breakdown

### **Week 1: Historical Data Pipeline**

#### Task 1.1: Symbol Configuration

**Location**: `lib/signal/config/symbols.ex`

Create a central, configurable symbol list that all modules reference.

```elixir
defmodule Signal.Config.Symbols do
  @default_symbols ~w[TSLA GOOG NVDA AAPL MSFT META AMZN SPY QQQ]

  def list, do: Application.get_env(:signal, :symbols, @default_symbols)
  def add(symbol), do: ...
  def remove(symbol), do: ...
end
```

Also add to `config/config.exs`:

```elixir
config :signal, :symbols, ~w[TSLA GOOG NVDA AAPL MSFT META AMZN SPY QQQ]
```

#### Task 1.2: Alpaca Historical Data Fetcher

**Location**: `lib/signal/data/historical_fetcher.ex`

- Fetch 5 years of 1-minute bars from Alpaca
- Handle pagination (10,000 bar limit per request)
- Rate limit compliance (200 req/min)
- Resume capability for interrupted fetches
- Progress tracking and logging

#### Task 1.3: Data Validation

**Location**: `lib/signal/data/data_validator.ex`

- Detect missing bars during market hours
- Identify suspicious data (zero volume, extreme price moves)
- Handle market holidays and early closes
- Generate data quality report

#### Task 1.4: Bulk Ingestion

**Location**: `lib/signal/data/bulk_ingester.ex`

- Efficient batch inserts to TimescaleDB
- Chunk processing to manage memory
- Progress callbacks for UI/logging

#### Task 1.5: Mix Task for Ingestion

**Location**: `lib/mix/tasks/signal.ingest_historical.ex`

```bash
mix signal.ingest_historical --symbols AAPL,TSLA --years 5
mix signal.ingest_historical --all --years 5
mix signal.ingest_historical --resume
mix signal.validate_data --symbol AAPL
```

#### Task 1.6: Database Migration

- Optimize indexes for backtest queries `(symbol, timestamp)`
- Add `historical_fetch_jobs` table for resume capability

**Deliverables**:

- [ ] Symbol configuration module
- [ ] Historical fetcher with pagination/rate limiting
- [ ] Data validator
- [ ] Bulk ingester
- [ ] Mix task
- [ ] Database migration
- [ ] Unit tests

---

### **Week 2: Event-Driven Backtesting Engine**

#### Task 2.1: Virtual Clock

**Location**: `lib/signal/backtest/virtual_clock.ex`

- Simulate time progression
- Replace system time calls during backtests
- Market hours awareness

#### Task 2.2: Bar Replayer

**Location**: `lib/signal/backtest/bar_replayer.ex`

- Stream historical bars chronologically
- Emit to existing PubSub topics (Phase 2 modules receive data unchanged)
- Multi-symbol synchronization by timestamp
- Speed control (`:instant` for optimization runs)

#### Task 2.3: State Manager

**Location**: `lib/signal/backtest/state_manager.ex`

- Isolate backtest state from live state
- Create fresh instances of BarCache, Levels, MarketStructure per run
- Clean teardown after completion
- Support parallel backtests for optimization

#### Task 2.4: Backtest Coordinator

**Location**: `lib/signal/backtest/coordinator.ex`

- Orchestrate complete backtest runs
- Initialize modules, run replay, collect signals
- Progress tracking

```elixir
{:ok, result} = Signal.Backtest.Coordinator.run(%{
  symbols: ["AAPL", "TSLA"],
  start_date: ~D[2020-01-01],
  end_date: ~D[2024-12-31],
  strategies: [:break_and_retest, :opening_range],
  parameters: %{min_confluence: 7, min_rr: 2.0},
  initial_capital: Decimal.new("100000"),
  risk_per_trade: 0.01
})
```

**Deliverables**:

- [ ] Virtual clock
- [ ] Bar replayer with PubSub integration
- [ ] State manager for isolation
- [ ] Backtest coordinator
- [ ] Integration test: replay 1 week, verify signals match

---

### **Week 3: Trade Simulation**

#### Task 3.1: Virtual Account

**Location**: `lib/signal/backtest/virtual_account.ex`

- Track balance, equity, buying power
- Position sizing: 1% equity at risk per trade
- Record equity curve over time

```elixir
%VirtualAccount{
  initial_capital: Decimal.new("100000"),
  current_equity: Decimal.new("102500"),
  cash: Decimal.new("98000"),
  open_positions: [...],
  closed_trades: [...],
  equity_curve: [{~U[...], Decimal.new("100000")}, ...]
}
```

#### Task 3.2: Trade Simulator

**Location**: `lib/signal/backtest/trade_simulator.ex`

- Execute trades from signals
- Calculate position size from risk parameters
- Track stop loss and take profit
- Handle exits: target hit, stopped out, time-based (11:00 AM)

```elixir
%SimulatedTrade{
  signal_id: uuid,
  symbol: "AAPL",
  direction: :long,
  entry_price: Decimal.new("175.50"),
  entry_time: ~U[2024-01-15 09:45:00Z],
  position_size: 85,  # shares
  risk_amount: Decimal.new("1000"),  # 1% of 100k
  stop_loss: Decimal.new("174.50"),
  take_profit: Decimal.new("177.50"),
  status: :open | :stopped_out | :target_hit | :time_exit,
  exit_price: nil,
  exit_time: nil,
  pnl: nil,
  r_multiple: nil
}
```

#### Task 3.3: Fill Simulator

**Location**: `lib/signal/backtest/fill_simulator.ex`

- Configurable fill assumptions (signal price, next bar open)
- Optional slippage modeling
- Detect gaps through stops

#### Task 3.4: Database Schema

- `backtest_runs` - metadata for each run
- `simulated_trades` - all trades from backtests

**Deliverables**:

- [ ] Virtual account with equity tracking
- [ ] Trade simulator with full lifecycle
- [ ] Fill simulator
- [ ] Database migrations
- [ ] Unit tests for position sizing calculations
- [ ] Integration test: backtest with trades executed

---

### **Week 4: Performance Analytics**

#### Task 4.1: Trade Metrics

**Location**: `lib/signal/analytics/trade_metrics.ex`

```elixir
%TradeMetrics{
  total_trades: 450,
  winners: 295,
  losers: 155,
  win_rate: 0.656,

  gross_profit: Decimal.new("45000"),
  gross_loss: Decimal.new("18000"),
  net_profit: Decimal.new("27000"),
  profit_factor: 2.5,

  avg_win: Decimal.new("152.54"),
  avg_loss: Decimal.new("116.13"),
  expectancy: Decimal.new("60.00"),

  avg_r_multiple: 1.31,

  sharpe_ratio: 1.85,
  sortino_ratio: 2.10,

  avg_hold_time_minutes: 12,
  max_hold_time_minutes: 45
}
```

#### Task 4.2: Drawdown Analysis

**Location**: `lib/signal/analytics/drawdown.ex`

```elixir
%DrawdownAnalysis{
  max_drawdown_pct: 0.085,
  max_drawdown_dollars: Decimal.new("8500"),
  max_drawdown_duration_days: 12,
  current_drawdown: 0.02,
  max_consecutive_losses: 5,
  max_consecutive_wins: 12
}
```

#### Task 4.3: Time-Based Performance

**Location**: `lib/signal/analytics/time_analysis.ex`

```elixir
%TimeAnalysis{
  by_time_slot: %{
    "09:30-09:45" => %{trades: 120, win_rate: 0.72, profit_factor: 3.1},
    "09:45-10:00" => %{trades: 95, win_rate: 0.68, profit_factor: 2.4},
    ...
  },
  by_weekday: %{...},
  by_month: %{...}
}
```

#### Task 4.4: Signal Quality Analysis

**Location**: `lib/signal/analytics/signal_analysis.ex`

```elixir
%SignalAnalysis{
  by_grade: %{
    "A" => %{count: 85, win_rate: 0.78, avg_r: 2.1},
    "B" => %{count: 180, win_rate: 0.68, avg_r: 1.6},
    ...
  },
  by_strategy: %{...},
  by_symbol: %{...}
}
```

#### Task 4.5: Equity Curve

**Location**: `lib/signal/analytics/equity_curve.ex`

- Generate equity curve data from trades
- Calculate rolling metrics
- Export for charting

**Deliverables**:

- [ ] Trade metrics calculator
- [ ] Drawdown analysis
- [ ] Time-based performance analysis
- [ ] Signal quality analysis
- [ ] Equity curve generator
- [ ] `backtest_results` table for persisting metrics
- [ ] Unit tests for all calculations

---

### **Week 5: Optimization Framework**

#### Task 5.1: Parameter Grid

**Location**: `lib/signal/optimization/parameter_grid.ex`

```elixir
%ParameterGrid{
  min_confluence_score: [5, 6, 7, 8, 9],
  min_risk_reward: [1.5, 2.0, 2.5, 3.0],
  signal_grade_filter: [:all, :c_and_above, :b_and_above, :a_only],
  entry_model: [:conservative, :aggressive],
  risk_per_trade: [0.01, 0.015, 0.02]
}
```

#### Task 5.2: Walk-Forward Engine

**Location**: `lib/signal/optimization/walk_forward.ex`

```elixir
%WalkForwardConfig{
  training_months: 12,
  testing_months: 3,
  step_months: 3,
  optimization_metric: :profit_factor,
  min_trades: 30
}
```

- Split data into rolling train/test windows
- Optimize on training, validate on test
- Aggregate out-of-sample results

#### Task 5.3: Optimization Runner

**Location**: `lib/signal/optimization/runner.ex`

- Run backtests across parameter combinations
- Parallel execution (Task.async_stream)
- Progress tracking
- Results ranking

#### Task 5.4: Overfitting Detection

**Location**: `lib/signal/optimization/validation.ex`

- Compare in-sample vs out-of-sample performance
- Flag parameters with >30% degradation
- Calculate walk-forward efficiency

#### Task 5.5: Database Schema

- `optimization_runs` - metadata
- `optimization_results` - per-parameter-set results

**Deliverables**:

- [ ] Parameter grid definition
- [ ] Walk-forward engine
- [ ] Parallel optimization runner
- [ ] Overfitting detection
- [ ] Database migrations
- [ ] Sample optimization run

---

### **Week 6: Dashboard & Integration**

#### Task 6.1: Backtest Dashboard

**Location**: `lib/signal_web/live/backtest_live.ex`

- Configure and run backtests
- View results with all metrics
- Equity curve chart
- Trade list with filtering

#### Task 6.2: Optimization Dashboard

**Location**: `lib/signal_web/live/optimization_live.ex`

- Configure parameter grid
- Run optimization with progress
- Compare parameter sets
- View walk-forward results

#### Task 6.3: Reports View

**Location**: `lib/signal_web/live/reports_live.ex`

- Time-of-day performance charts
- Signal grade analysis
- Strategy comparison
- Symbol breakdown

**Deliverables**:

- [ ] Backtest configuration and results UI
- [ ] Optimization UI with progress
- [ ] Performance reports and charts
- [ ] Chart components (equity curve, drawdown, heatmaps)

---

## Summary Checklist

| Week | Focus            | Key Deliverable                                  |
| ---- | ---------------- | ------------------------------------------------ |
| 1    | Historical Data  | 5 years of 1-min data ingested                   |
| 2    | Backtest Engine  | Event-driven replay through Phase 2 modules      |
| 3    | Trade Simulation | Position sizing, stops, targets, equity tracking |
| 4    | Analytics        | Full metrics suite calculated                    |
| 5    | Optimization     | Walk-forward parameter tuning                    |
| 6    | Dashboard        | Visualize and run everything from UI             |

---

This feel right? Ready to start on Week 1?
