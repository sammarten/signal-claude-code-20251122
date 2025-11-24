# Testing Technical Analysis - Quick Start

## 🚀 Fast Track (30 seconds)

```bash
# 1. Make sure you have data
mix signal.load_data --symbols AAPL --year 2024

# 2. Open IEx
iex -S mix

# 3. Run comprehensive test
alias Signal.Technicals.Inspector
Inspector.inspect_symbol(:AAPL, days: 5)
```

You'll see:
- ✅ ASCII price chart with swing points
- ✅ Key levels (PDH/PDL, opening ranges)
- ✅ Swing analysis (highs/lows)
- ✅ Market structure (trend, BOS, ChoCh)

---

## 📋 Testing Methods

| Method | Best For | Speed |
|--------|----------|-------|
| **IEx Inspector** | Interactive exploration | ⚡ Instant |
| **Mix Task** | Quick CLI checks | ⚡⚡ Fast |
| **Direct Module** | Detailed testing | ⚡⚡⚡ Full control |
| **Unit Tests** | Automated validation | 🔄 Continuous |

---

## 🎯 IEx Inspector Commands

```elixir
alias Signal.Technicals.Inspector

# All-in-one (RECOMMENDED)
Inspector.inspect_symbol(:AAPL, days: 5)

# Individual modules
Inspector.inspect_swings(:AAPL, days: 2)
Inspector.inspect_structure(:AAPL, days: 3)
Inspector.inspect_levels(:AAPL)

# ASCII chart only
Inspector.show_chart(:AAPL, days: 2)
```

---

## 💻 CLI Mix Task

```bash
# Comprehensive test
mix signal.test_technicals AAPL --days 5

# Test specific module
mix signal.test_technicals TSLA --module swings
mix signal.test_technicals NVDA --module structure
mix signal.test_technicals AAPL --module levels

# Custom lookback
mix signal.test_technicals AAPL --module swings --lookback 3
```

---

## 🔬 Direct Module Testing

```elixir
# Get some bars
bars = Signal.Repo.all(
  from b in Signal.MarketData.Bar,
    where: b.symbol == "AAPL",
    order_by: [asc: b.bar_time],
    limit: 100
)

# Test Swings
alias Signal.Technicals.Swings
swings = Swings.identify_swings(bars)
Swings.swing_high?(bars, 50, 2)

# Test Structure
alias Signal.Technicals.StructureDetector
structure = StructureDetector.analyze(bars)
structure.trend  # :bullish | :bearish | :ranging

# Test Levels
alias Signal.Technicals.Levels
{:ok, levels} = Levels.get_current_levels(:AAPL)
Levels.level_broken?(level, current, previous)
```

---

## 📊 What to Look For

### Swings
- ✅ Swing highs higher than N bars before/after
- ✅ Swing lows lower than N bars before/after
- ✅ Marked with `●` on ASCII chart

### Structure
- ✅ **Bullish**: Higher highs + higher lows
- ✅ **Bearish**: Lower highs + lower lows
- ✅ **BOS**: Break beyond previous swing (continuation)
- ✅ **ChoCh**: Break opposite swing (reversal)

### Levels
- ✅ **PDH/PDL**: Previous day high/low
- ✅ **PMH/PML**: Premarket high/low (4-9:30 AM)
- ✅ **OR5/OR15**: Opening ranges (5min/15min)
- ✅ Price position relative to levels

---

## 🐛 Troubleshooting

**No data?**
```bash
mix signal.load_data --symbols AAPL --year 2024
```

**No levels?**
```elixir
Levels.calculate_daily_levels(:AAPL, ~D[2024-11-23])
```

**No swings?**
- Increase days or decrease lookback

**Trend showing ranging?**
- Need more data (try `days: 10`)

---

## 📚 Full Documentation

See `docs/TESTING_TECHNICALS.md` for:
- Detailed examples
- Validation checklist
- Test scenarios
- Expected outputs

---

## 🎨 Example Output

```
================================================================================
Technical Analysis for AAPL
================================================================================

📊 Data Range: 780 bars over 5 days
   From: 2024-11-18 09:30:00
   To:   2024-11-23 16:00:00

📊 KEY LEVELS
   PDH: $176.50  |  PDL: $173.80
   OR5: $175.20 - $174.60

📍 SWING ANALYSIS
   Total Swings: 12
   Latest High: $176.20 at 14:30
   Latest Low:  $174.10 at 11:45

🏗️  MARKET STRUCTURE
   Trend: 📈 BULLISH
   State: 💪 STRONG BULLISH
   BOS:   BULLISH at $176.50

📈 PRICE CHART
  $176.50 │     ●▪▪
  $175.50 │   ▪▪  ▪▪▪
  $174.50 │ ▪▪      ▪●▪
  $173.50 │●
          └──────────────
          09:30    16:00

Legend: ● Swing  ▪ Green  ▫ Red
```

---

## ⚡ Pro Tips

1. **Start with `inspect_symbol(:AAPL, days: 5)`** - See everything at once
2. **Use ASCII chart** - Visual validation is faster than reading numbers
3. **Test multiple symbols** - AAPL, TSLA, NVDA, SPY all behave differently
4. **Vary lookback** - `lookback: 2` vs `lookback: 3` changes sensitivity
5. **Compare timeframes** - `days: 1` vs `days: 5` vs `days: 10`

---

🎉 **You're ready to test!** Start with `Inspector.inspect_symbol(:AAPL, days: 5)` and explore from there.
