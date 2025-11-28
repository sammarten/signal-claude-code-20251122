# Signal Trading System - Quick Start Guide

**Reading time: 5-10 minutes**

## What Signal Does

Signal is a day trading system that:
1. Streams real-time market data from Alpaca Markets
2. Detects trading patterns (break and retest, opening range breakouts)
3. Generates trade signals with quality grades (A, B, C, D)
4. Backtests strategies on 5 years of historical data
5. Optimizes parameters to find the best settings

---

## Starting the System

```bash
# Load API credentials
source .env

# Start the server
iex -S mix phx.server
```

Visit **http://localhost:4000** to access the dashboard.

---

## The Four Main Pages

### 1. Dashboard (`/`)

**What it shows**: Real-time market data for all configured symbols (AAPL, TSLA, NVDA, etc.)

**Key elements**:
- Live price updates via WebSocket
- Current bid/ask quotes
- Volume indicators
- Connection status

**When to use**: Monitor the market during trading hours (9:30 AM - 4:00 PM ET)

---

### 2. Backtest (`/backtest`)

**What it does**: Test trading strategies against historical data to see how they would have performed.

**How to run a backtest**:

1. **Select symbols** - Click the symbol chips (AAPL, TSLA, etc.) to include/exclude
2. **Pick date range** - Choose start and end dates (max 5 years of data available)
3. **Choose strategies**:
   - `break_and_retest` - Trades when price breaks a level then retests it
   - `opening_range` - Trades breakouts from the first 5-15 minutes of trading
4. **Set parameters**:
   - Initial Capital: Starting account balance (default $100,000)
   - Risk Per Trade: Percentage of account to risk (default 1%)
5. Click **Run Backtest**

**Understanding results**:

| Metric | What it means |
|--------|---------------|
| Total P&L | Net profit/loss in dollars |
| Win Rate | Percentage of winning trades |
| Profit Factor | Gross profit ÷ gross loss (>1.0 = profitable) |
| Sharpe Ratio | Risk-adjusted return (>1.0 = good, >2.0 = excellent) |
| Max Drawdown | Largest peak-to-trough decline |

**The equity curve chart**: Shows your account value over time. Green = above starting capital, Red = below.

**Viewing trades**: Click the "Trades" tab to see individual trade details - entry/exit prices, P&L, and R-multiple (how many times your risk you made/lost).

---

### 3. Optimization (`/optimization`)

**What it does**: Tests many parameter combinations to find the best settings for your strategy.

**How to run an optimization**:

1. **Configure the same settings as backtest** (symbols, dates, strategies)
2. **Set parameter ranges** - The system will test combinations of:
   - Min Confluence Score: 5-9 (higher = stricter signal quality)
   - Min Risk/Reward: 1.5-3.0 (higher = bigger profit targets)
3. Click **Run Optimization**

**Reading the results table**:

Results are ranked by Sharpe Ratio (best risk-adjusted returns). Each row shows:
- The parameter values tested
- Performance metrics for that combination
- Whether it's likely overfit (performed well in-sample but may not work live)

**Walk-Forward Analysis**: The system uses "walk-forward" testing - it optimizes on older data, then validates on newer data. This helps avoid overfitting to historical patterns that won't repeat.

---

### 4. Reports (`/reports`)

**What it does**: Deep-dive analysis of backtest performance by different dimensions.

**Available analyses**:

| Tab | Shows |
|-----|-------|
| By Strategy | Which strategy performs best |
| By Symbol | Which stocks are most profitable |
| By Time | Best/worst times of day to trade |
| By Grade | How signal quality (A/B/C) correlates with results |

**How to use**: Select a completed backtest run from the dropdown, then explore the tabs.

---

## Key Concepts

### Confluence Score (1-13)

Measures how many factors align for a trade setup:
- Multi-timeframe agreement (+3)
- Order block + FVG overlap (+2)
- Multiple key levels align (+2)
- Break of structure confirmed (+2)
- Above-average volume (+1)
- Strong rejection candle (+1)
- Within first 30 min of open (+1)
- 3:1+ risk/reward available (+1)

**Grades**: A (10+), B (8-9), C (6-7), D (4-5), F (<4)

### Key Levels

Price levels the system tracks:
- **PDH/PDL**: Previous Day High/Low
- **PMH/PML**: Premarket High/Low
- **ORH/ORL**: Opening Range High/Low (5-min and 15-min)

### Risk/Reward (R:R)

If you risk $100 to make $200, that's 2:1 R:R. The system requires minimum 2:1 by default.

### R-Multiple

How a trade performed relative to risk:
- +2R = Made 2x your risk (e.g., risked $100, made $200)
- -1R = Lost your full risk amount
- +0.5R = Made half your risk (partial target)

---

## Typical Workflow

1. **Start with a backtest** on recent data (last 6-12 months) to see baseline performance

2. **Run optimization** to find better parameters, but be skeptical of results that seem too good

3. **Validate with reports** - check if performance is consistent across symbols and times

4. **Paper trade** (coming in Phase 4) - test with simulated money before going live

---

## Quick Tips

- **Longer backtests are better** - 2+ years shows how strategies perform in different market conditions
- **Watch for overfitting** - If optimization results are dramatically better than baseline, parameters may be too tuned to past data
- **Profit factor > 1.5** is a solid target - means you make $1.50 for every $1 lost
- **Win rate isn't everything** - A 40% win rate with 3:1 R:R is profitable; a 60% win rate with 0.5:1 R:R loses money
- **Max drawdown matters** - Can you stomach a 15% drawdown? That affects position sizing

---

## Database Commands

```bash
# Load historical data (required for backtesting)
mix signal.load_data --year 2024

# Check data coverage
mix signal.load_data --check-only

# Fill gaps in data
mix signal.fill_gaps
```

---

## Next Steps

Once comfortable with the system:
1. Run backtests on different time periods
2. Compare strategy performance
3. Find parameter settings that work across multiple symbols
4. Wait for Phase 4 to paper trade with Alpaca
