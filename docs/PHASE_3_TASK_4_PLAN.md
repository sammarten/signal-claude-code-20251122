# Phase 3 Task 4: Performance Analytics - Implementation Plan

## Overview

This task implements comprehensive performance analytics for backtesting. The analytics modules will process closed trades and equity curves from `VirtualAccount` to calculate key trading metrics, drawdown analysis, time-based performance, signal quality analysis, and equity curve statistics.

## Existing Infrastructure

### Data Sources
- **`VirtualAccount.closed_trades`**: List of closed trade maps with:
  - `pnl`, `pnl_pct`, `r_multiple`
  - `entry_time`, `exit_time`
  - `symbol`, `direction`, `status`
  - `position_size`, `risk_amount`, `entry_price`, `exit_price`

- **`VirtualAccount.equity_curve`**: List of `{DateTime.t(), Decimal.t()}` tuples

- **`SimulatedTrade` schema**: Persisted trades with same fields + `signal_id`, `strategy`, etc.

### Integration Points
- `Coordinator.run/2` returns result with `closed_trades` and `equity_curve`
- Analytics will be called at end of backtest to generate comprehensive report

---

## Implementation Tasks

### Task 4.1: Trade Metrics Module

**File**: `lib/signal/analytics/trade_metrics.ex`

Calculate core trading performance metrics:

```elixir
%TradeMetrics{
  total_trades: 450,
  winners: 295,
  losers: 155,
  win_rate: Decimal.new("65.56"),  # percentage

  gross_profit: Decimal.new("45000"),
  gross_loss: Decimal.new("18000"),
  net_profit: Decimal.new("27000"),
  profit_factor: Decimal.new("2.50"),  # gross_profit / gross_loss

  avg_win: Decimal.new("152.54"),
  avg_loss: Decimal.new("116.13"),
  expectancy: Decimal.new("60.00"),  # (win_rate * avg_win) - (loss_rate * avg_loss)

  avg_r_multiple: Decimal.new("1.31"),
  max_r_multiple: Decimal.new("5.20"),
  min_r_multiple: Decimal.new("-1.50"),

  avg_hold_time_minutes: 12,
  max_hold_time_minutes: 45,
  min_hold_time_minutes: 2
}
```

**Key Functions**:
- `calculate/1` - Takes list of trades, returns `%TradeMetrics{}`
- `profit_factor/1` - Calculates gross_profit / gross_loss
- `expectancy/1` - Calculates expected value per trade
- `sharpe_ratio/2` - Takes equity returns, risk-free rate
- `sortino_ratio/2` - Like Sharpe but only penalizes downside volatility

**Implementation Notes**:
- All monetary values as `Decimal`
- Handle edge cases: zero trades, all winners/losers
- Hold time calculated from `entry_time` to `exit_time`

---

### Task 4.2: Drawdown Analysis Module

**File**: `lib/signal/analytics/drawdown.ex`

Calculate drawdown and streak metrics:

```elixir
%DrawdownAnalysis{
  max_drawdown_pct: Decimal.new("8.50"),
  max_drawdown_dollars: Decimal.new("8500"),
  max_drawdown_start: ~U[2024-02-15 10:00:00Z],
  max_drawdown_end: ~U[2024-02-27 14:30:00Z],
  max_drawdown_duration_days: 12,

  current_drawdown_pct: Decimal.new("2.00"),
  current_drawdown_dollars: Decimal.new("2050"),

  max_consecutive_losses: 5,
  max_consecutive_wins: 12,
  current_streak: 3,  # positive = wins, negative = losses

  recovery_factor: Decimal.new("3.18")  # net_profit / max_drawdown
}
```

**Key Functions**:
- `calculate/2` - Takes equity curve and initial capital
- `find_max_drawdown/1` - Finds peak-to-trough decline
- `calculate_streaks/1` - Analyzes win/loss sequences
- `recovery_factor/2` - Net profit divided by max drawdown

**Implementation Notes**:
- Drawdown calculated from equity curve high-water marks
- Track both percentage and absolute dollar drawdown
- Duration calculated in trading days (exclude weekends)

---

### Task 4.3: Time-Based Performance Module

**File**: `lib/signal/analytics/time_analysis.ex`

Analyze performance by time of day, day of week, and month:

```elixir
%TimeAnalysis{
  by_time_slot: %{
    "09:30-09:45" => %TimeSlotStats{
      trades: 120,
      winners: 86,
      losers: 34,
      win_rate: Decimal.new("71.67"),
      profit_factor: Decimal.new("3.10"),
      net_pnl: Decimal.new("5400"),
      avg_r: Decimal.new("1.85")
    },
    "09:45-10:00" => %TimeSlotStats{...},
    ...
  },

  by_weekday: %{
    :monday => %DayStats{trades: 90, win_rate: ...},
    :tuesday => %DayStats{...},
    ...
  },

  by_month: %{
    "2024-01" => %MonthStats{trades: 45, ...},
    "2024-02" => %MonthStats{...},
    ...
  },

  best_time_slot: "09:30-09:45",
  worst_time_slot: "10:30-10:45",
  best_weekday: :tuesday,
  worst_weekday: :friday
}
```

**Key Functions**:
- `calculate/1` - Takes list of trades
- `by_time_slot/2` - Group by customizable time intervals (default 15 min)
- `by_weekday/1` - Group by day of week
- `by_month/1` - Group by calendar month
- `find_best_worst/1` - Identify optimal/suboptimal periods

**Implementation Notes**:
- Use ET (America/New_York) for time calculations
- Time slots: 15-minute intervals from 9:30 to 16:00
- Calculate full metrics for each grouping

---

### Task 4.4: Signal Quality Analysis Module

**File**: `lib/signal/analytics/signal_analysis.ex`

Analyze performance by signal characteristics:

```elixir
%SignalAnalysis{
  by_grade: %{
    "A" => %GradeStats{
      count: 85,
      win_rate: Decimal.new("78.00"),
      avg_r: Decimal.new("2.10"),
      profit_factor: Decimal.new("4.20"),
      net_pnl: Decimal.new("12500")
    },
    "B" => %GradeStats{count: 180, ...},
    "C" => %GradeStats{count: 120, ...},
    "D" => %GradeStats{count: 50, ...},
    "F" => %GradeStats{count: 15, ...}
  },

  by_strategy: %{
    "break_and_retest" => %StrategyStats{
      count: 320,
      win_rate: Decimal.new("68.50"),
      avg_r: Decimal.new("1.45"),
      profit_factor: Decimal.new("2.80")
    },
    "opening_range_breakout" => %StrategyStats{...}
  },

  by_symbol: %{
    "AAPL" => %SymbolStats{count: 75, win_rate: ..., sharpe: ...},
    "TSLA" => %SymbolStats{count: 120, ...},
    ...
  },

  by_direction: %{
    :long => %DirectionStats{count: 280, win_rate: ...},
    :short => %DirectionStats{count: 170, win_rate: ...}
  },

  by_exit_type: %{
    :target_hit => %ExitStats{count: 295, avg_r: Decimal.new("2.0")},
    :stopped_out => %ExitStats{count: 130, avg_r: Decimal.new("-1.0")},
    :time_exit => %ExitStats{count: 25, avg_r: Decimal.new("0.35")}
  }
}
```

**Key Functions**:
- `calculate/1` - Takes list of trades (with signal info)
- `by_grade/1` - Group by quality grade
- `by_strategy/1` - Group by strategy
- `by_symbol/1` - Group by symbol
- `by_direction/1` - Long vs short analysis
- `by_exit_type/1` - Analyze exit reasons

**Implementation Notes**:
- Signal quality info may need to be joined with trade data
- For backtest, signal info passed through `signal_id` field
- Calculate full metrics for each grouping

---

### Task 4.5: Equity Curve Analysis Module

**File**: `lib/signal/analytics/equity_curve.ex`

Process and analyze equity curve data:

```elixir
%EquityCurveAnalysis{
  data_points: [
    %{timestamp: ~U[...], equity: Decimal.new("100000"), drawdown_pct: Decimal.new("0")},
    %{timestamp: ~U[...], equity: Decimal.new("101500"), drawdown_pct: Decimal.new("0")},
    ...
  ],

  initial_equity: Decimal.new("100000"),
  final_equity: Decimal.new("127000"),
  peak_equity: Decimal.new("128500"),
  trough_equity: Decimal.new("91500"),

  total_return_pct: Decimal.new("27.00"),
  annualized_return_pct: Decimal.new("54.00"),

  volatility: Decimal.new("15.20"),  # annualized std dev of returns
  sharpe_ratio: Decimal.new("1.85"),
  sortino_ratio: Decimal.new("2.10"),
  calmar_ratio: Decimal.new("3.18"),  # annualized return / max drawdown

  # Rolling metrics (e.g., 20-trade rolling window)
  rolling_sharpe: [...],
  rolling_win_rate: [...]
}
```

**Key Functions**:
- `analyze/2` - Takes equity curve and initial capital
- `calculate_returns/1` - Convert equity to period returns
- `sharpe_ratio/2` - (avg_return - risk_free) / std_dev
- `sortino_ratio/2` - Uses downside deviation
- `calmar_ratio/2` - Annualized return / max drawdown
- `rolling_metrics/2` - Calculate metrics over rolling window
- `to_chart_data/1` - Format for charting libraries

**Implementation Notes**:
- Equity curve may be sparse (only on trade close)
- Handle annualization based on actual trading period
- Risk-free rate configurable (default 0)

---

### Task 4.6: Comprehensive Analytics Facade

**File**: `lib/signal/analytics.ex`

Main entry point that combines all analytics:

```elixir
%BacktestAnalytics{
  trade_metrics: %TradeMetrics{...},
  drawdown: %DrawdownAnalysis{...},
  time_analysis: %TimeAnalysis{...},
  signal_analysis: %SignalAnalysis{...},
  equity_curve: %EquityCurveAnalysis{...},

  # Summary stats
  summary: %{
    total_trades: 450,
    win_rate: Decimal.new("65.56"),
    profit_factor: Decimal.new("2.50"),
    net_profit: Decimal.new("27000"),
    max_drawdown_pct: Decimal.new("8.50"),
    sharpe_ratio: Decimal.new("1.85"),
    best_strategy: "break_and_retest",
    best_time_slot: "09:30-09:45"
  }
}
```

**Key Functions**:
- `analyze_backtest/1` - Takes backtest result, returns full analytics
- `summary/1` - Returns condensed key metrics
- `to_report/1` - Generates formatted report

---

### Task 4.7: Database Schema for Persisting Results

**Migration**: `priv/repo/migrations/TIMESTAMP_create_backtest_results.exs`

```elixir
create table(:backtest_results, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :backtest_run_id, references(:backtest_runs, type: :binary_id, on_delete: :delete_all)

  # Trade metrics
  add :total_trades, :integer
  add :winners, :integer
  add :losers, :integer
  add :win_rate, :decimal
  add :gross_profit, :decimal
  add :gross_loss, :decimal
  add :net_profit, :decimal
  add :profit_factor, :decimal
  add :expectancy, :decimal
  add :avg_r_multiple, :decimal
  add :avg_hold_time_minutes, :integer

  # Drawdown
  add :max_drawdown_pct, :decimal
  add :max_drawdown_dollars, :decimal
  add :max_drawdown_duration_days, :integer
  add :max_consecutive_losses, :integer
  add :max_consecutive_wins, :integer
  add :recovery_factor, :decimal

  # Risk-adjusted returns
  add :sharpe_ratio, :decimal
  add :sortino_ratio, :decimal
  add :calmar_ratio, :decimal

  # Detailed breakdowns stored as JSONB
  add :time_analysis, :map
  add :signal_analysis, :map
  add :equity_curve_data, :map

  timestamps(type: :utc_datetime_usec)
end

create index(:backtest_results, [:backtest_run_id])
```

**Schema**: `lib/signal/analytics/backtest_result.ex`

---

### Task 4.8: Integration with Coordinator

Update `Signal.Backtest.Coordinator` to:
1. Call analytics after backtest completes
2. Persist results to `backtest_results` table
3. Return analytics in result map

---

## Test Plan

### Unit Tests

**`test/signal/analytics/trade_metrics_test.exs`**:
- Test with empty trade list
- Test with all winners
- Test with all losers
- Test with mixed results
- Test edge cases (single trade, zero P&L trades)
- Verify all calculations against known values

**`test/signal/analytics/drawdown_test.exs`**:
- Test max drawdown calculation
- Test consecutive win/loss streaks
- Test recovery factor
- Test with monotonically increasing equity
- Test with monotonically decreasing equity

**`test/signal/analytics/time_analysis_test.exs`**:
- Test time slot grouping
- Test weekday grouping
- Test month grouping
- Test timezone handling (UTC to ET conversion)

**`test/signal/analytics/signal_analysis_test.exs`**:
- Test grouping by grade
- Test grouping by strategy
- Test grouping by symbol
- Test grouping by exit type

**`test/signal/analytics/equity_curve_test.exs`**:
- Test return calculations
- Test Sharpe ratio calculation
- Test Sortino ratio (verify only downside counted)
- Test Calmar ratio
- Test with sparse data points

### Integration Tests

**`test/signal/analytics/analytics_integration_test.exs`**:
- Run a full backtest and verify analytics generated
- Verify persistence to `backtest_results` table
- Verify coordinator returns complete analytics

---

## File Structure

```
lib/signal/analytics/
├── trade_metrics.ex      # Core trade performance metrics
├── drawdown.ex           # Drawdown and streak analysis
├── time_analysis.ex      # Time-based performance
├── signal_analysis.ex    # Signal quality analysis
├── equity_curve.ex       # Equity curve processing
├── backtest_result.ex    # Ecto schema for persisted results
└── analytics.ex          # Facade module (optional)

test/signal/analytics/
├── trade_metrics_test.exs
├── drawdown_test.exs
├── time_analysis_test.exs
├── signal_analysis_test.exs
├── equity_curve_test.exs
└── analytics_integration_test.exs

priv/repo/migrations/
└── TIMESTAMP_create_backtest_results.exs
```

---

## Implementation Order

1. **Trade Metrics** (4.1) - Foundation module, simplest calculations
2. **Drawdown Analysis** (4.2) - Depends on equity curve understanding
3. **Equity Curve** (4.5) - Processes raw equity data
4. **Time Analysis** (4.3) - Groups trades by time
5. **Signal Analysis** (4.4) - Groups trades by signal properties
6. **Database Schema** (4.7) - Migration and Ecto schema
7. **Coordinator Integration** (4.8) - Wire everything together
8. **Comprehensive Tests** - Unit and integration tests throughout

---

## Dependencies

- No new external dependencies required
- Uses existing `Decimal` library for precision
- Uses existing `DateTime` and timezone handling patterns

---

## Success Criteria

1. All analytics modules calculate correct values (verified by tests)
2. Analytics integrate seamlessly with existing backtest flow
3. Results persist correctly to database
4. Analytics can handle edge cases without crashing
5. Performance acceptable for large backtests (10,000+ trades)
