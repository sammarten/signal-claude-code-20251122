# Options Trading Integration - Usage Guide

This document describes how to use the options trading integration with Signal's backtesting infrastructure.

## Overview

The options integration allows you to:
- Run backtests using options instead of equity trades
- Compare options vs equity performance on the same signals
- Optimize options parameters (expiration, strike selection, etc.)
- Analyze options-specific metrics (premium capture, exit reasons, etc.)

## Quick Start

### Running an Options Backtest

```elixir
alias Signal.Backtest.OptionsBacktestRunner
alias Signal.Instruments.Config

# Create options configuration
config = Config.options(
  expiration_preference: :weekly,
  strike_selection: :atm,
  risk_percentage: Decimal.new("0.01"),
  slippage_pct: Decimal.new("0.01")
)

# Run backtest
{:ok, result} = OptionsBacktestRunner.run(%{
  symbols: ["AAPL", "TSLA"],
  start_date: ~D[2024-03-01],
  end_date: ~D[2024-11-30],
  strategies: [:break_and_retest],
  initial_capital: Decimal.new("100000"),
  config: config
})

# Access results
result.trades           # List of completed trades
result.analytics        # Performance analytics
result.equity_curve     # Account value over time
```

### Comparing Options vs Equity

```elixir
alias Signal.Analytics.OptionsReport

# Run both backtests
{:ok, equity_result} = run_equity_backtest(params)
{:ok, options_result} = run_options_backtest(params)

# Generate comparison report
{:ok, report} = OptionsReport.comparison_report(
  equity_result.trades,
  options_result.trades
)

# Print formatted report
IO.puts(OptionsReport.to_text(report))
```

## Configuration Options

### Instrument Configuration

```elixir
alias Signal.Instruments.Config

# Options with weekly expiration, ATM strikes
config = Config.options()

# Options with 0DTE, 1 strike OTM
config = Config.zero_dte(strike_selection: :one_otm)

# Full custom configuration
config = Config.new(
  instrument_type: :options,
  expiration_preference: :weekly,  # :weekly or :zero_dte
  strike_selection: :atm,          # :atm, :one_otm, or :two_otm
  risk_percentage: Decimal.new("0.01"),
  slippage_pct: Decimal.new("0.01"),
  use_bar_open_for_entry: true,
  use_bar_close_for_exit: true
)
```

### Configuration Parameters

| Parameter | Values | Description |
|-----------|--------|-------------|
| `instrument_type` | `:equity`, `:options` | Trade type |
| `expiration_preference` | `:weekly`, `:zero_dte` | Options expiration target |
| `strike_selection` | `:atm`, `:one_otm`, `:two_otm` | Strike distance from current price |
| `risk_percentage` | `Decimal` | Percentage of portfolio to risk per trade |
| `slippage_pct` | `Decimal` | Simulated slippage for fills |

## Optimization

### Using Parameter Presets

```elixir
alias Signal.Optimization.OptionsParams
alias Signal.Optimization.Runner

# Use a preset
grid = OptionsParams.preset(:default)      # Standard optimization
grid = OptionsParams.preset(:comprehensive) # All combinations
grid = OptionsParams.preset(:comparison)   # Equity vs options
grid = OptionsParams.preset(:zero_dte)     # 0DTE focus
grid = OptionsParams.preset(:weekly)       # Weekly focus
grid = OptionsParams.preset(:conservative) # Low risk
grid = OptionsParams.preset(:aggressive)   # Higher risk, OTM

# Run optimization
{:ok, result} = Runner.run(%{
  symbols: ["SPY", "QQQ"],
  start_date: ~D[2024-03-01],
  end_date: ~D[2024-11-30],
  strategies: [:break_and_retest],
  initial_capital: Decimal.new("100000"),
  base_risk_per_trade: Decimal.new("0.01"),
  parameter_grid: grid
})
```

### Custom Parameter Grid

```elixir
grid = OptionsParams.custom_grid(%{
  instrument_type: [:options],
  expiration_preference: [:weekly, :zero_dte],
  strike_selection: [:atm, :one_otm],
  slippage_pct: [Decimal.new("0.01"), Decimal.new("0.02")]
})

# Check combination count
OptionsParams.combination_count(grid)  # => 8

# Preview grid
IO.puts(OptionsParams.grid_summary(grid))
```

### Combined Strategy + Options Optimization

```elixir
options_grid = OptionsParams.default_grid()

strategy_params = %{
  min_confluence_score: [6, 7, 8],
  min_rr: [Decimal.new("2.0"), Decimal.new("2.5")]
}

merged_grid = OptionsParams.merge_with_strategy(options_grid, strategy_params)
```

## Analytics

### Options-Specific Metrics

```elixir
alias Signal.Analytics.OptionsMetrics

# Calculate options metrics
{:ok, metrics} = OptionsMetrics.calculate(options_trades)

# Access metrics
metrics.base_metrics            # Standard trade metrics
metrics.avg_entry_premium       # Average premium paid
metrics.avg_exit_premium        # Average premium received
metrics.avg_premium_capture_multiple  # Exit/entry ratio
metrics.total_contracts         # Total contracts traded
metrics.by_exit_reason          # Breakdown by exit type
metrics.by_contract_type        # Calls vs puts
metrics.by_expiration_type      # 0DTE vs weekly vs monthly
metrics.by_strike_distance      # ATM vs OTM performance
metrics.avg_dte_at_entry        # Average days to expiration
```

### Configuration Breakdown

```elixir
alias Signal.Analytics.OptionsReport

{:ok, config_report} = OptionsReport.configuration_report(options_trades)

# Access breakdowns
config_report.by_expiration_type   # 0DTE, weekly, monthly, leaps
config_report.by_strike_distance   # ATM, 1_otm, 2_otm, deep_otm
config_report.by_contract_type     # call, put
config_report.by_exit_reason       # expiration, premium_target, etc.
config_report.best_configuration   # Best performing config
config_report.worst_configuration  # Worst performing config

# Print formatted report
IO.puts(OptionsReport.configuration_to_text(config_report))
```

## Exit Handling

Options positions exit via:

1. **Premium Target** - Exit when premium reaches target multiple
2. **Premium Floor** - Exit when premium falls to floor percentage
3. **Underlying Stop** - Exit when underlying hits stop loss
4. **Underlying Target** - Exit when underlying hits take profit
5. **Expiration** - Exit on expiration day or when past expiration

```elixir
alias Signal.Options.ExitHandler

# Check exit conditions
result = ExitHandler.check_exit(position, option_bar, underlying_bar)

case result do
  :hold -> "Keep position open"
  {:exit, :expiration, price} -> "Exit due to expiration at #{price}"
  {:exit, :premium_target, price} -> "Exit at premium target #{price}"
  {:exit, :premium_stop, price} -> "Exit at premium floor #{price}"
  {:exit, :underlying_stop, price} -> "Exit at underlying stop"
  {:exit, :underlying_target, price} -> "Exit at underlying target"
end
```

## Data Requirements

### Historical Data

Options bar data is available from **February 2024** via Alpaca. Backtests before this date will skip signals that would have traded options.

### Contract Discovery

Contracts are discovered and cached via:

```elixir
alias Signal.Options.ContractDiscovery

# Sync contracts for a symbol
ContractDiscovery.sync_contracts("AAPL")

# Find nearest weekly expiration
{:ok, date} = ContractDiscovery.find_nearest_weekly("AAPL", ~D[2024-06-15])

# Find 0DTE expiration
{:ok, date} = ContractDiscovery.find_zero_dte("SPY", ~D[2024-06-15])
```

### OSI Symbol Format

Options use OSI (Options Symbology Initiative) format:

```
AAPL240621C00150000
│    │     │ │
│    │     │ └─ Strike price × 1000 (8 digits, zero-padded)
│    │     └─── Contract type: C=Call, P=Put
│    └───────── Expiration: YYMMDD
└────────────── Underlying symbol
```

## Module Reference

| Module | Purpose |
|--------|---------|
| `Signal.Instruments.Config` | Configuration for instrument selection |
| `Signal.Instruments.Resolver` | Resolves signals to instruments |
| `Signal.Instruments.OptionsContract` | Options instrument representation |
| `Signal.Options.ContractDiscovery` | Contract lookup and caching |
| `Signal.Options.PriceLookup` | Historical options price queries |
| `Signal.Options.PositionSizer` | Contract quantity calculation |
| `Signal.Options.ExitHandler` | Options-specific exit logic |
| `Signal.Backtest.OptionsTradeSimulator` | Options trade execution |
| `Signal.Backtest.OptionsBacktestRunner` | High-level backtest orchestration |
| `Signal.Analytics.OptionsMetrics` | Options performance metrics |
| `Signal.Analytics.OptionsReport` | Comparison and breakdown reports |
| `Signal.Optimization.OptionsParams` | Optimization parameter presets |

## Limitations

1. **Data Availability**: Options data only available from February 2024
2. **No Greeks**: Historical bars don't include delta/gamma/theta
3. **No Bid/Ask**: Bars only, no spread information
4. **Liquidity**: Cannot measure liquidity directly from bar data
5. **Exercise Simulation**: ITM options at expiration assume exercise at intrinsic value

## Best Practices

1. **Start with Weekly**: More forgiving than 0DTE, good for initial testing
2. **Use ATM Initially**: Better fills, more liquidity
3. **Conservative Slippage**: Start with 1-2% slippage assumption
4. **Liquid Underlyings**: Focus on SPY, QQQ, TSLA for 0DTE
5. **Compare Results**: Always run equity comparison to validate options edge
