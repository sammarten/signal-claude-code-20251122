# Task 6: Dashboard & Integration - Implementation Plan

## Overview

Task 6 adds three new LiveView pages for backtesting, optimization, and reporting. The backend modules (Tasks 1-5) are complete and ready for integration.

## Analysis Summary

### Existing Infrastructure
- **Backtest Coordinator** (`Signal.Backtest.Coordinator`) - Runs backtests synchronously or async, supports progress callbacks
- **Optimization Runner** (`Signal.Optimization.Runner`) - Grid search and walk-forward optimization with parallel execution
- **Analytics Modules** - TradeMetrics, Drawdown, EquityCurve, TimeAnalysis, SignalAnalysis all complete
- **Database Schemas** - BacktestRun, BacktestResult, OptimizationRun, OptimizationResult, SimulatedTrade
- **Charting** - lightweight-charts v5 already integrated with TradingChart and SparkChart hooks

### Existing Patterns
- LiveView pages use dark zinc theme with gradients
- Navigation via header links with active state styling
- PubSub for real-time updates
- Phoenix LiveView hooks for JavaScript charting

---

## Implementation Tasks

### 6.1 Backtest Dashboard

**File**: `lib/signal_web/live/backtest_live.ex`

#### Features
1. **Configuration Form**
   - Symbol selection (multi-select from configured symbols)
   - Date range picker (start_date, end_date)
   - Strategy selection (checkboxes: break_and_retest, opening_range, etc.)
   - Initial capital input (default: $100,000)
   - Risk per trade input (default: 1%)
   - Parameters: min_confluence, min_rr

2. **Run Management**
   - Start backtest button (calls `Coordinator.run_async/2`)
   - Cancel button for running backtests
   - Progress display (% complete, current date, bars processed)
   - Real-time progress via PubSub broadcasts

3. **Results Display**
   - Summary metrics panel (win rate, profit factor, net P&L, sharpe, max DD)
   - Equity curve chart (line chart using new hook)
   - Trade list with filtering/sorting
   - Recent backtest runs table (from backtest_runs)

4. **Trade Details Modal**
   - Entry/exit times and prices
   - P&L and R-multiple
   - Signal details that triggered the trade

#### State Management
```elixir
assigns = %{
  # Form state
  form: to_form(backtest_params),

  # Run state
  current_run_id: nil,
  run_status: nil,  # :idle | :running | :completed | :failed
  progress: %{pct: 0, current_date: nil, bars_processed: 0},

  # Results
  result: nil,  # %{...} from Coordinator
  trades: [],

  # History
  recent_runs: [],  # list of BacktestRun records

  # UI state
  selected_trade: nil,
  trade_filter: %{status: "all", symbol: "all"}
}
```

#### PubSub Topics
- Subscribe to: `backtest:progress:{run_id}`
- Broadcast from Coordinator progress callback

---

### 6.2 Optimization Dashboard

**File**: `lib/signal_web/live/optimization_live.ex`

#### Features
1. **Configuration Form**
   - Base config (symbols, dates, strategies, capital)
   - Parameter grid builder:
     - min_confluence_score: [5, 6, 7, 8, 9] checkboxes
     - min_rr: [1.5, 2.0, 2.5, 3.0] checkboxes
     - risk_per_trade: [0.01, 0.015, 0.02] checkboxes
   - Walk-forward toggle with settings:
     - training_months: 12
     - testing_months: 3
     - step_months: 3
   - Optimization metric selector (profit_factor, sharpe, win_rate)
   - Min trades filter

2. **Run Management**
   - Display total combinations before running
   - Start optimization button
   - Progress bar (combinations completed / total)
   - Cancel button

3. **Results Display**
   - Top N parameter sets table (sortable by metric)
   - Walk-forward results summary
   - Overfitting warnings (degradation > 30%)
   - Parameter comparison heatmap (future enhancement)

4. **Detail Views**
   - Click on parameter set to see full metrics
   - Compare selected vs baseline params

#### State Management
```elixir
assigns = %{
  # Form state
  form: to_form(optimization_params),
  parameter_grid: %{
    min_confluence_score: [],
    min_rr: [],
    risk_per_trade: []
  },
  walk_forward_enabled: false,
  walk_forward_config: %{...},

  # Run state
  current_run_id: nil,
  run_status: nil,
  progress: %{completed: 0, total: 0, pct: 0},

  # Results
  results: [],
  best_params: nil,
  validation_results: nil,

  # History
  recent_runs: []
}
```

---

### 6.3 Reports View

**File**: `lib/signal_web/live/reports_live.ex`

#### Features
1. **Backtest Selector**
   - Dropdown of completed backtest runs
   - Load results on selection

2. **Performance Charts**
   - Equity curve with drawdown overlay
   - Monthly returns bar chart
   - Win rate by time slot heatmap

3. **Analysis Panels**
   - Time Analysis: performance by time slot, weekday, month
   - Signal Analysis: performance by grade, strategy, symbol
   - Strategy Comparison: side-by-side metrics
   - Symbol Breakdown: per-symbol P&L contribution

4. **Trade Explorer**
   - Full trade list with all columns
   - Export to CSV functionality

#### Data Sources
- `BacktestResult` schema has `time_analysis` and `signal_analysis` JSONB fields
- `SimulatedTrade` table for full trade list
- `EquityCurve` data for charts

---

### 6.4 Chart Components

#### New JavaScript Hook: EquityCurveChart

**File**: `assets/js/hooks/equity_curve_chart.js`

```javascript
// Uses lightweight-charts LineSeries
// Features:
// - Equity line (green when above initial, red when below)
// - Drawdown area (semi-transparent red fill)
// - Horizontal line at initial capital
// - Tooltips showing date, equity, drawdown %
```

#### New JavaScript Hook: BarChartHook

**File**: `assets/js/hooks/bar_chart.js`

```javascript
// Simple bar chart for monthly returns
// Green for positive, red for negative
// Labels on x-axis (month names)
```

---

### 6.5 Router Updates

**File**: `lib/signal_web/router.ex`

Add routes:
```elixir
live "/backtest", BacktestLive, :index
live "/optimization", OptimizationLive, :index
live "/reports", ReportsLive, :index
```

---

### 6.6 Navigation Updates

Update header navigation in all LiveView pages:
- Market (/)
- Signals (/signals)
- Backtest (/backtest) **NEW**
- Optimization (/optimization) **NEW**
- Reports (/reports) **NEW**

Create shared navigation component to avoid duplication.

---

### 6.7 Shared Components

**File**: `lib/signal_web/live/components/backtest_components.ex`

Components:
- `metrics_summary/1` - Key metrics display panel
- `progress_bar/1` - Backtest/optimization progress
- `trade_row/1` - Single trade in table
- `parameter_badge/1` - Parameter value display

**File**: `lib/signal_web/live/components/navigation.ex`

- `main_nav/1` - Shared header navigation

---

## Implementation Order

### Phase 1: Foundation (Subtask 6.1a)
1. Create shared navigation component
2. Update router with new routes
3. Create stub LiveView pages
4. Update all existing pages to use shared nav

### Phase 2: Backtest Dashboard (Subtask 6.1b)
1. Configuration form with validation
2. Run backtest integration with Coordinator
3. Progress tracking via PubSub
4. Basic results display
5. Recent runs history

### Phase 3: Backtest Charts (Subtask 6.1c)
1. Create EquityCurveChart JavaScript hook
2. Integrate equity curve into backtest results
3. Trade list with filtering
4. Trade details modal

### Phase 4: Optimization Dashboard (Subtask 6.2)
1. Parameter grid configuration UI
2. Walk-forward toggle and settings
3. Run optimization integration
4. Results table with sorting
5. Overfitting warnings

### Phase 5: Reports View (Subtask 6.3)
1. Backtest selector
2. Time analysis panels (by_time_slot, by_weekday, by_month)
3. Signal analysis panels (by_grade, by_strategy, by_symbol)
4. Trade explorer with CSV export

### Phase 6: Polish
1. Loading states and error handling
2. Empty state messaging
3. Responsive design adjustments
4. Performance optimization (lazy loading large trade lists)

---

## Database Queries Needed

### BacktestLive
```elixir
# Recent runs
from(r in BacktestRun, order_by: [desc: r.inserted_at], limit: 10)

# Trades for a run
from(t in SimulatedTrade, where: t.backtest_run_id == ^run_id, order_by: [desc: t.entry_time])

# Results for a run
Repo.get_by(BacktestResult, backtest_run_id: run_id)
```

### OptimizationLive
```elixir
# Recent runs
from(r in OptimizationRun, order_by: [desc: r.inserted_at], limit: 10)

# Top results
from(r in OptimizationResult,
  where: r.optimization_run_id == ^run_id,
  order_by: [desc: r.profit_factor],
  limit: 20)
```

### ReportsLive
```elixir
# All completed backtests
from(r in BacktestRun, where: r.status == :completed, order_by: [desc: r.completed_at])

# Full results with nested data
Repo.get_by(BacktestResult, backtest_run_id: run_id) |> Repo.preload(:backtest_run)
```

---

## Testing Strategy

1. **Unit Tests**
   - Form validation
   - Progress calculation helpers
   - Trade filtering logic

2. **Integration Tests**
   - Full backtest run from UI
   - Optimization with small parameter grid
   - Results display accuracy

3. **Manual Testing**
   - Progress updates in real-time
   - Chart rendering
   - Navigation flow

---

## Estimated Effort

| Subtask | Estimated Size |
|---------|---------------|
| 6.1a Foundation | Small |
| 6.1b Backtest Config & Run | Medium |
| 6.1c Backtest Charts & Trades | Medium |
| 6.2 Optimization | Medium |
| 6.3 Reports | Medium |
| Polish | Small |

---

## Dependencies

- All Phase 3 Tasks 1-5 modules complete
- `lightweight-charts` npm package (already installed)
- No new external dependencies needed
