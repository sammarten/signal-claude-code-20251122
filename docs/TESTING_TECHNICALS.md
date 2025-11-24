# Testing Technical Analysis Modules

This guide shows you how to test the `Levels`, `Swings`, and `StructureDetector` modules with real market data.

## Prerequisites

Make sure you have historical data loaded:

```bash
# Load 2024 data for a few symbols
mix signal.load_data --symbols AAPL,TSLA,NVDA --year 2024
```

---

## Method 1: Interactive IEx Testing (Recommended)

The `Signal.Technicals.Inspector` module provides interactive testing in IEx.

### Start IEx

```bash
iex -S mix
```

### Quick Start - Inspect Everything

```elixir
alias Signal.Technicals.Inspector

# Comprehensive analysis with ASCII chart
Inspector.inspect_symbol(:AAPL, days: 5)
```

This will show:
- ✅ Key levels (PDH/PDL, PMH/PML, Opening Ranges)
- ✅ Swing analysis (highs and lows)
- ✅ Market structure (trend, BOS, ChoCh)
- ✅ ASCII price chart with swing points marked

### Test Individual Modules

#### Swing Detection

```elixir
# View all swing points
Inspector.inspect_swings(:AAPL, days: 2)

# Customize lookback period
Inspector.inspect_swings(:AAPL, days: 3, lookback: 3)
```

**What to look for:**
- Swing highs should be higher than N bars before/after
- Swing lows should be lower than N bars before/after
- Latest swing high/low should make sense visually

#### Market Structure

```elixir
# Analyze trend and structure
Inspector.inspect_structure(:AAPL, days: 3)
```

**What to look for:**
- **Bullish trend**: Should show higher highs AND higher lows
- **Bearish trend**: Should show lower highs AND lower lows
- **BOS (Break of Structure)**: Price breaking previous swing in trend direction
- **ChoCh (Change of Character)**: Price breaking opposite swing (reversal signal)

#### Key Levels

```elixir
# Check daily levels
Inspector.inspect_levels(:AAPL, ~D[2024-11-23])

# Use today's date
Inspector.inspect_levels(:AAPL)
```

**What to look for:**
- PDH/PDL calculated from previous day's data
- PMH/PML from premarket session (4:00 AM - 9:30 AM ET)
- Opening ranges (5min and 15min) if available
- Current price position relative to levels

#### ASCII Chart

```elixir
# Show visual chart
Inspector.show_chart(:AAPL, days: 2)
```

**Chart legend:**
- `●` = Swing point (high or low)
- `▪` = Green/bullish bar
- `▫` = Red/bearish bar
- `─` = Doji/neutral bar

---

## Method 2: Mix Task (Quick CLI Testing)

Run tests from the command line without opening IEx.

### Basic Usage

```bash
# Test all modules for AAPL
mix signal.test_technicals AAPL

# Test specific symbol with custom days
mix signal.test_technicals TSLA --days 5

# Test only swings
mix signal.test_technicals NVDA --module swings

# Test structure with custom lookback
mix signal.test_technicals AAPL --module structure --lookback 3
```

### Options

| Flag | Description | Default |
|------|-------------|---------|
| `--days` | Days of data to analyze | 3 |
| `--module` | Module to test (swings, structure, levels, all) | all |
| `--lookback` | Swing detection lookback period | 2 |

---

## Method 3: Direct Module Usage

Test modules directly in IEx for maximum control.

### Swings Module

```elixir
alias Signal.Technicals.Swings
alias Signal.Repo
import Ecto.Query

# Get bars
bars = from(b in Signal.MarketData.Bar,
         where: b.symbol == "AAPL",
         order_by: [asc: b.bar_time],
         limit: 100)
       |> Repo.all()

# Identify swings
swings = Swings.identify_swings(bars, lookback: 2)

# Get latest swing high
latest_high = Swings.get_latest_swing(bars, :high)

# Check if specific bar is a swing
Swings.swing_high?(bars, 50, 2)
```

### Levels Module

```elixir
alias Signal.Technicals.Levels

# Calculate levels for a date
{:ok, levels} = Levels.calculate_daily_levels(:AAPL, ~D[2024-11-23])

# Get current levels
{:ok, levels} = Levels.get_current_levels(:AAPL)

# Check level breaks
price_broke = Levels.level_broken?(
  levels.previous_day_high,  # level
  Decimal.new("176.00"),     # current price
  Decimal.new("175.00")      # previous price
)

# Find psychological levels
psych = Levels.find_nearest_psychological(Decimal.new("175.23"))
# => %{whole: 175, half: 175.50, quarter: 175.25}

# Get price position
{:ok, {position, level_name, level_value}} =
  Levels.get_level_status(:AAPL, Decimal.new("175.60"))
```

### Structure Detector Module

```elixir
alias Signal.Technicals.StructureDetector

# Analyze structure
structure = StructureDetector.analyze(bars, lookback: 2)

# Access results
structure.trend           # :bullish | :bearish | :ranging
structure.latest_bos      # %{type: :bullish, price: ..., ...}
structure.latest_choch    # %{type: :bearish, price: ..., ...}
structure.swing_highs     # [%{type: :high, price: ..., ...}, ...]
structure.swing_lows      # [%{type: :low, price: ..., ...}, ...]

# Determine trend from swings
trend = StructureDetector.determine_trend(
  structure.swing_highs,
  structure.swing_lows
)

# Detect BOS
bos = StructureDetector.detect_bos(bars, swings, :bullish)

# Detect ChoCh
choch = StructureDetector.detect_choch(bars, swings, :bearish)

# Get structure state
state = StructureDetector.get_structure_state(structure)
# => :strong_bullish | :weak_bullish | :strong_bearish | :weak_bearish | :ranging
```

---

## Method 4: Create Test Scenarios

Create known test cases to verify logic.

### Example: Test Known Swing Pattern

```elixir
# Create bars with a clear swing high at index 5
test_bars = [
  %Signal.MarketData.Bar{high: Decimal.new("100"), low: Decimal.new("98"), ...},  # 0
  %Signal.MarketData.Bar{high: Decimal.new("102"), low: Decimal.new("100"), ...}, # 1
  %Signal.MarketData.Bar{high: Decimal.new("104"), low: Decimal.new("102"), ...}, # 2
  %Signal.MarketData.Bar{high: Decimal.new("106"), low: Decimal.new("104"), ...}, # 3
  %Signal.MarketData.Bar{high: Decimal.new("108"), low: Decimal.new("106"), ...}, # 4
  %Signal.MarketData.Bar{high: Decimal.new("110"), low: Decimal.new("108"), ...}, # 5 <- SWING HIGH
  %Signal.MarketData.Bar{high: Decimal.new("108"), low: Decimal.new("106"), ...}, # 6
  %Signal.MarketData.Bar{high: Decimal.new("106"), low: Decimal.new("104"), ...}, # 7
  %Signal.MarketData.Bar{high: Decimal.new("104"), low: Decimal.new("102"), ...}, # 8
]

# Test swing detection
Swings.swing_high?(test_bars, 5, 2)  # Should be true
swings = Swings.identify_swings(test_bars, lookback: 2)
# Should include swing high at index 5
```

### Example: Test Bullish Trend

```elixir
# Create bars showing clear bullish trend (higher highs, higher lows)
swing_highs = [
  %{price: Decimal.new("100"), index: 5},
  %{price: Decimal.new("105"), index: 10},
  %{price: Decimal.new("110"), index: 15}
]

swing_lows = [
  %{price: Decimal.new("95"), index: 3},
  %{price: Decimal.new("100"), index: 8},
  %{price: Decimal.new("105"), index: 13}
]

trend = StructureDetector.determine_trend(swing_highs, swing_lows)
# Should return :bullish
```

---

## Validation Checklist

Use this checklist to verify each module works correctly:

### ✅ Swings Module

- [ ] Swing highs are higher than N bars before/after
- [ ] Swing lows are lower than N bars before/after
- [ ] `get_latest_swing/2` returns most recent swing
- [ ] Lookback parameter changes sensitivity
- [ ] Empty bars list returns empty swings
- [ ] Insufficient bars returns empty swings

### ✅ Levels Module

- [ ] PDH/PDL calculated from previous day's max/min
- [ ] PMH/PML calculated from 4:00 AM - 9:30 AM ET
- [ ] Opening ranges calculated at 9:35 and 9:45 AM
- [ ] `level_broken?/3` detects bullish and bearish breaks
- [ ] Psychological levels round correctly
- [ ] `get_level_status/2` finds nearest level

### ✅ Structure Detector Module

- [ ] Bullish trend = higher highs + higher lows
- [ ] Bearish trend = lower highs + lower lows
- [ ] BOS detects break of previous swing in trend direction
- [ ] ChoCh detects break of opposite swing (reversal)
- [ ] Strong state = BOS present, no ChoCh
- [ ] Weak state = ChoCh present (reversal warning)

---

## Troubleshooting

### No Data Found

```
⚠️  No bar data found. Load historical data first:
    mix signal.load_data --symbols AAPL --year 2024
```

**Solution:** Load historical data for the symbol.

### No Levels Found

```
⚠️  No levels calculated for this date.
   Calculate with: Levels.calculate_daily_levels(:AAPL, ~D[2024-11-23])
```

**Solution:** Levels must be calculated manually. Run:
```elixir
Levels.calculate_daily_levels(:AAPL, ~D[2024-11-23])
```

### No Swings Detected

Possible causes:
- Not enough bars (need at least `lookback * 2 + 1` bars)
- Lookback too large for dataset
- Price action has no clear swings

**Solution:**
- Increase days: `Inspector.inspect_swings(:AAPL, days: 5)`
- Decrease lookback: `lookback: 1`

### Trend Shows Ranging

This is normal if:
- Insufficient swing points (need 2+ highs and 2+ lows)
- Mixed higher/lower pattern (consolidation)
- Very short time period

**Solution:** Increase time range: `days: 5` or `days: 10`

---

## Quick Reference

```elixir
# === IN IEX ===

# Quick comprehensive test
Inspector.inspect_symbol(:AAPL, days: 5)

# Individual modules
Inspector.inspect_swings(:AAPL, days: 2)
Inspector.inspect_structure(:AAPL, days: 3)
Inspector.inspect_levels(:AAPL)
Inspector.show_chart(:AAPL, days: 2)

# === CLI ===

# All modules
mix signal.test_technicals AAPL --days 5

# Specific module
mix signal.test_technicals AAPL --module swings
mix signal.test_technicals AAPL --module structure
mix signal.test_technicals AAPL --module levels
```

---

## Next Steps

Once you've validated the modules work correctly:

1. **Write Unit Tests** - See `docs/TASK_1_WORK_ORDERS.md` for test specifications
2. **Create Test Fixtures** - Known data with expected results
3. **Integration Testing** - Test with live streaming data
4. **Visual Charting** - Add to LiveView dashboard (Phase 2 Task 5)

---

## Example Output

When you run `Inspector.inspect_symbol(:AAPL, days: 2)`, you'll see:

```
================================================================================
Technical Analysis for AAPL
================================================================================

📊 Data Range: 780 bars over 2 days
   From: 2024-11-21 09:30:00
   To:   2024-11-22 16:00:00
   Price Range: $173.50 - $176.80

--------------------------------------------------------------------------------
📊 KEY LEVELS
--------------------------------------------------------------------------------
   PDH: $176.50  |  PDL: $173.80
   PMH: $174.90  |  PML: $174.20
   OR5: $175.20 - $174.60

--------------------------------------------------------------------------------
📍 SWING ANALYSIS
--------------------------------------------------------------------------------
   Total Swings: 8
   Swing Highs: 4
   Swing Lows:  4
   Latest High: $176.20 at 14:30
   Latest Low:  $174.10 at 11:45

--------------------------------------------------------------------------------
🏗️  MARKET STRUCTURE
--------------------------------------------------------------------------------
   Trend: 📈 BULLISH
   State: 💪 STRONG BULLISH
   BOS:   BULLISH at $176.50

--------------------------------------------------------------------------------
📈 PRICE CHART (Last 50 bars)
--------------------------------------------------------------------------------
[ASCII chart with swing points marked]
================================================================================
```

Happy testing! 🚀
