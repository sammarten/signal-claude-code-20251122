# Daily Market Preview - Project Plan

## Overview

Generate an automated daily market analysis each morning before market open, modeled after the format used by professional day traders. The system pulls market data, calculates key levels, detects market regime, and generates actionable scenarios.

---

## Phase 1: Core Infrastructure (MVP)

### 1.1 Data Sources

```
┌─────────────────────────────────────────────────────────────┐
│                     ALPACA MARKETS API                       │
├─────────────────────────────────────────────────────────────┤
│  Bars Endpoint: /v2/stocks/{symbol}/bars                    │
│  - Historical OHLC data                                      │
│  - Timeframes: 1Min, 5Min, 15Min, 1Hour, 1Day               │
│  - Used for: Key levels, regime detection, divergence       │
│                                                              │
│  Snapshot Endpoint: /v2/stocks/{symbol}/snapshot            │
│  - Current price, today's bar, prev close                   │
│  - Used for: Pre-market position, gap analysis              │
│                                                              │
│  News Endpoint: /v1/news                                     │
│  - Headlines, summaries, sentiment                          │
│  - Params: symbols, start, end, limit                       │
│  - Used for: Catalyst identification                        │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 Symbols to Track

```
INDICES (Primary):
  - SPY   (S&P 500 proxy)
  - QQQ   (Nasdaq proxy)
  - DIA   (Dow proxy)
  - IWM   (Russell 2000 proxy)

MAG 7:
  - AAPL, MSFT, GOOGL, AMZN, NVDA, META, TSLA

SEMICONDUCTORS:
  - AMD, AVGO, MU, TSM, INTC

MOMENTUM/WATCHLIST:
  - PLTR, HOOD, SOFI, COIN, etc. (configurable)

COMMODITIES:
  - GLD (Gold), SLV (Silver), USO (Oil)
```

### 1.3 Data Models

```
KeyLevels {
  symbol: string
  date: date
  
  // Core levels
  previous_day_high: decimal
  previous_day_low: decimal
  previous_day_close: decimal
  previous_day_open: decimal
  
  // Extended levels
  last_week_high: decimal
  last_week_low: decimal
  last_week_close: decimal
  
  // Derived levels
  equilibrium: decimal          // (week_high + week_low) / 2
  all_time_high: decimal
  
  // Event-based levels (optional)
  event_pivot: decimal          // FOMC candle, earnings gap, etc.
  event_type: string
}

MarketRegime {
  symbol: string
  date: date
  timeframe: string             // "daily", "weekly"
  
  regime: enum {
    TRENDING_UP,
    TRENDING_DOWN,
    RANGING,
    BREAKOUT_PENDING
  }
  
  // Supporting metrics
  range_high: decimal
  range_low: decimal
  range_duration_days: int
  distance_from_ath_percent: decimal
  
  // Trend metrics (if trending)
  trend_direction: enum { UP, DOWN, NEUTRAL }
  higher_lows_count: int
  lower_highs_count: int
}

IndexDivergence {
  date: date
  
  spy_status: enum { LEADING, LAGGING, NEUTRAL }
  qqq_status: enum { LEADING, LAGGING, NEUTRAL }
  dia_status: enum { LEADING, LAGGING, NEUTRAL }
  
  // Performance deltas (vs each other)
  spy_vs_qqq_1d: decimal        // percentage difference
  spy_vs_qqq_5d: decimal
  
  // Distance from ATH
  spy_from_ath: decimal
  qqq_from_ath: decimal
  dia_from_ath: decimal
  
  implication: string           // Generated insight
}

RelativeStrength {
  symbol: string
  date: date
  benchmark: string             // "SPY" or "QQQ"
  
  rs_1d: decimal                // 1-day relative performance
  rs_5d: decimal                // 5-day relative performance
  rs_20d: decimal               // 20-day relative performance
  
  status: enum { 
    STRONG_OUTPERFORM,
    OUTPERFORM, 
    INLINE, 
    UNDERPERFORM,
    STRONG_UNDERPERFORM
  }
}

PremarketSnapshot {
  symbol: string
  timestamp: datetime
  
  current_price: decimal
  previous_close: decimal
  gap_percent: decimal
  gap_direction: enum { UP, DOWN, FLAT }
  
  premarket_high: decimal
  premarket_low: decimal
  premarket_volume: int
  
  position_in_range: enum {
    ABOVE_PREV_DAY_HIGH,
    NEAR_PREV_DAY_HIGH,
    MIDDLE_OF_RANGE,
    NEAR_PREV_DAY_LOW,
    BELOW_PREV_DAY_LOW
  }
}

Scenario {
  type: enum { BULLISH, BEARISH, BOUNCE, FADE }
  
  trigger_level: decimal
  trigger_condition: string     // "break above", "break below", "hold", "reject"
  target_level: decimal
  
  description: string           // Human-readable scenario
}

DailyPreview {
  date: date
  generated_at: datetime
  
  // Context
  market_context: string        // Summary of overnight action
  key_events: list<string>      // FOMC, earnings, etc.
  expected_volatility: enum { HIGH, NORMAL, LOW }
  
  // Index analysis
  index_divergence: IndexDivergence
  spy_levels: KeyLevels
  qqq_levels: KeyLevels
  spy_regime: MarketRegime
  qqq_regime: MarketRegime
  
  // Scenarios
  spy_scenarios: list<Scenario>
  qqq_scenarios: list<Scenario>
  
  // Watchlist
  high_conviction: list<WatchlistItem>
  monitoring: list<WatchlistItem>
  avoid: list<WatchlistItem>
  
  // Sector notes
  relative_strength_leaders: list<string>
  relative_strength_laggards: list<string>
  
  // Game plan
  stance: enum { AGGRESSIVE, NORMAL, CAUTIOUS, HANDS_OFF }
  position_size: enum { FULL, HALF, QUARTER }
  focus: string
  risk_notes: list<string>
}

WatchlistItem {
  symbol: string
  setup: string                 // "break and retest", "bounce play", etc.
  key_level: decimal
  bias: enum { LONG, SHORT, NEUTRAL }
  conviction: enum { HIGH, MEDIUM, LOW }
  notes: string
}
```

---

## Phase 1 Calculations

### 2.1 Key Levels Calculation

```
FUNCTION calculate_key_levels(symbol, date):
  
  // Get daily bars for last 10 trading days
  daily_bars = fetch_bars(symbol, "1Day", days=10)
  
  // Previous day
  prev_day = daily_bars[-1]
  previous_day_high = prev_day.high
  previous_day_low = prev_day.low
  previous_day_close = prev_day.close
  previous_day_open = prev_day.open
  
  // Last week (5 trading days)
  last_week_bars = daily_bars[-6:-1]  // exclude today
  last_week_high = MAX(bar.high for bar in last_week_bars)
  last_week_low = MIN(bar.low for bar in last_week_bars)
  last_week_close = last_week_bars[-1].close
  
  // Equilibrium (midpoint of recent range)
  equilibrium = (last_week_high + last_week_low) / 2
  
  // All-time high (need longer history)
  all_bars = fetch_bars(symbol, "1Day", days=252)  // 1 year
  all_time_high = MAX(bar.high for bar in all_bars)
  
  RETURN KeyLevels{...}
```

### 2.2 Market Regime Detection

```
FUNCTION detect_regime(symbol, date):
  
  daily_bars = fetch_bars(symbol, "1Day", days=20)
  
  // Calculate range metrics
  recent_bars = daily_bars[-10:]  // last 2 weeks
  range_high = MAX(bar.high for bar in recent_bars)
  range_low = MIN(bar.low for bar in recent_bars)
  range_size = range_high - range_low
  current_price = daily_bars[-1].close
  
  // Calculate ATR for context
  atr_14 = calculate_atr(daily_bars, period=14)
  
  // Determine if ranging
  // Ranging = price oscillating within a band, multiple touches of high/low
  touches_high = COUNT(bar where bar.high >= range_high * 0.995)
  touches_low = COUNT(bar where bar.low <= range_low * 1.005)
  
  is_ranging = touches_high >= 2 AND touches_low >= 2 
               AND range_size < atr_14 * 3
  
  // Determine trend via higher lows / lower highs
  swing_lows = find_swing_lows(daily_bars)
  swing_highs = find_swing_highs(daily_bars)
  
  higher_lows = is_ascending(swing_lows)
  lower_highs = is_descending(swing_highs)
  
  IF is_ranging:
    regime = RANGING
  ELSE IF higher_lows AND NOT lower_highs:
    regime = TRENDING_UP
  ELSE IF lower_highs AND NOT higher_lows:
    regime = TRENDING_DOWN
  ELSE:
    regime = BREAKOUT_PENDING
  
  // Range duration (how many days in this range)
  range_duration = count_days_in_range(daily_bars, range_high, range_low)
  
  RETURN MarketRegime{...}
```

### 2.3 Index Divergence

```
FUNCTION calculate_divergence(date):
  
  spy_bars = fetch_bars("SPY", "1Day", days=5)
  qqq_bars = fetch_bars("QQQ", "1Day", days=5)
  dia_bars = fetch_bars("DIA", "1Day", days=5)
  
  // 1-day performance
  spy_1d = (spy_bars[-1].close - spy_bars[-2].close) / spy_bars[-2].close
  qqq_1d = (qqq_bars[-1].close - qqq_bars[-2].close) / qqq_bars[-2].close
  dia_1d = (dia_bars[-1].close - dia_bars[-2].close) / dia_bars[-2].close
  
  // 5-day performance
  spy_5d = (spy_bars[-1].close - spy_bars[0].close) / spy_bars[0].close
  qqq_5d = (qqq_bars[-1].close - qqq_bars[0].close) / qqq_bars[0].close
  dia_5d = (dia_bars[-1].close - dia_bars[0].close) / dia_bars[0].close
  
  // Determine leader/laggard
  performances = {SPY: spy_5d, QQQ: qqq_5d, DIA: dia_5d}
  sorted_perf = SORT(performances, descending=true)
  
  leader = sorted_perf[0]
  laggard = sorted_perf[-1]
  
  // Distance from ATH
  spy_ath = get_all_time_high("SPY")
  qqq_ath = get_all_time_high("QQQ")
  dia_ath = get_all_time_high("DIA")
  
  spy_from_ath = (spy_ath - spy_bars[-1].close) / spy_ath * 100
  qqq_from_ath = (qqq_ath - qqq_bars[-1].close) / qqq_ath * 100
  dia_from_ath = (dia_ath - dia_bars[-1].close) / dia_ath * 100
  
  // Generate implication
  IF qqq is laggard AND qqq_from_ath > spy_from_ath + 2:
    implication = "Tech lagging - harder to trade NQ names, look at SPY components"
  ELSE IF spy_from_ath < 1 AND qqq_from_ath < 1:
    implication = "Both indices near ATH - watch for breakout or rejection"
  ELSE:
    implication = "Indices relatively aligned"
  
  RETURN IndexDivergence{...}
```

### 2.4 Relative Strength

```
FUNCTION calculate_relative_strength(symbol, benchmark, date):
  
  stock_bars = fetch_bars(symbol, "1Day", days=20)
  bench_bars = fetch_bars(benchmark, "1Day", days=20)
  
  // Calculate returns for each period
  FOR period IN [1, 5, 20]:
    stock_return = (stock_bars[-1].close - stock_bars[-period].close) 
                   / stock_bars[-period].close
    bench_return = (bench_bars[-1].close - bench_bars[-period].close) 
                   / bench_bars[-period].close
    
    rs_{period} = stock_return - bench_return
  
  // Classify
  IF rs_5d > 0.03:
    status = STRONG_OUTPERFORM
  ELSE IF rs_5d > 0.01:
    status = OUTPERFORM
  ELSE IF rs_5d > -0.01:
    status = INLINE
  ELSE IF rs_5d > -0.03:
    status = UNDERPERFORM
  ELSE:
    status = STRONG_UNDERPERFORM
  
  RETURN RelativeStrength{...}
```

### 2.5 Premarket Analysis

```
FUNCTION analyze_premarket(symbol):
  
  // Get snapshot (includes premarket data)
  snapshot = fetch_snapshot(symbol)
  
  // Get previous day's bar
  prev_day = fetch_bars(symbol, "1Day", days=1)[0]
  
  current_price = snapshot.latest_trade.price
  previous_close = prev_day.close
  
  gap_percent = (current_price - previous_close) / previous_close * 100
  
  IF gap_percent > 0.5:
    gap_direction = UP
  ELSE IF gap_percent < -0.5:
    gap_direction = DOWN
  ELSE:
    gap_direction = FLAT
  
  // Position relative to previous day's range
  IF current_price > prev_day.high:
    position = ABOVE_PREV_DAY_HIGH
  ELSE IF current_price > prev_day.high - (prev_day.high - prev_day.low) * 0.1:
    position = NEAR_PREV_DAY_HIGH
  ELSE IF current_price < prev_day.low:
    position = BELOW_PREV_DAY_LOW
  ELSE IF current_price < prev_day.low + (prev_day.high - prev_day.low) * 0.1:
    position = NEAR_PREV_DAY_LOW
  ELSE:
    position = MIDDLE_OF_RANGE
  
  RETURN PremarketSnapshot{...}
```

### 2.6 Scenario Generation

```
FUNCTION generate_scenarios(key_levels, regime, premarket):
  
  scenarios = []
  current = premarket.current_price
  
  IF regime.regime == RANGING:
    
    // Bounce scenario (if near support)
    IF current <= key_levels.last_week_low * 1.01:
      scenarios.append(Scenario{
        type: BOUNCE,
        trigger_level: key_levels.last_week_low,
        trigger_condition: "hold above",
        target_level: key_levels.equilibrium,
        description: "Bounce off {last_week_low}, target equilibrium {equilibrium}"
      })
    
    // Fade scenario (if near resistance)  
    IF current >= key_levels.last_week_high * 0.99:
      scenarios.append(Scenario{
        type: FADE,
        trigger_level: key_levels.last_week_high,
        trigger_condition: "reject at",
        target_level: key_levels.equilibrium,
        description: "Rejection at {last_week_high}, fade to {equilibrium}"
      })
    
    // Breakout scenarios
    scenarios.append(Scenario{
      type: BULLISH,
      trigger_level: key_levels.last_week_high,
      trigger_condition: "break above and hold",
      target_level: key_levels.all_time_high,
      description: "Break above {last_week_high}, hold for push to ATH"
    })
    
    scenarios.append(Scenario{
      type: BEARISH,
      trigger_level: key_levels.last_week_low,
      trigger_condition: "break below",
      target_level: key_levels.last_week_low * 0.98,  // 2% below
      description: "Break below {last_week_low}, continuation lower"
    })
  
  ELSE IF regime.regime == TRENDING_UP:
    
    // Pullback buy scenario
    scenarios.append(Scenario{
      type: BOUNCE,
      trigger_level: key_levels.previous_day_low,
      trigger_condition: "dip to and hold",
      target_level: key_levels.previous_day_high,
      description: "Buy the dip at {prev_day_low}, target {prev_day_high}"
    })
    
    // Continuation scenario
    scenarios.append(Scenario{
      type: BULLISH,
      trigger_level: key_levels.previous_day_high,
      trigger_condition: "break above",
      target_level: key_levels.all_time_high,
      description: "Break above {prev_day_high}, continuation to ATH"
    })
  
  RETURN scenarios
```

### 2.7 Stance Determination

```
FUNCTION determine_stance(regime, divergence, key_events):
  
  // Check for major events
  has_fomc = "FOMC" IN key_events
  has_major_earnings = check_major_earnings(date)
  
  IF has_fomc AND time < FOMC_TIME:
    stance = HANDS_OFF
    size = QUARTER
    focus = "Wait for FOMC at 2pm ET"
    
  ELSE IF regime.regime == RANGING AND regime.range_duration_days > 5:
    stance = CAUTIOUS
    size = HALF
    focus = "Play range extremes only, no mid-range trades"
    
  ELSE IF regime.regime == TRENDING_UP AND divergence.qqq_status != LAGGING:
    stance = NORMAL
    size = FULL
    focus = "Buy pullbacks, look for continuation setups"
    
  ELSE IF divergence.qqq_status == LAGGING:
    stance = CAUTIOUS
    size = HALF
    focus = "Tech lagging - be selective, consider SPY names"
  
  ELSE:
    stance = NORMAL
    size = FULL
    focus = "Standard playbook"
  
  RETURN {stance, size, focus}
```

---

## Phase 2: News Integration

### 3.1 Alpaca News Endpoint

```
FUNCTION fetch_news(symbols, hours_back=24):
  
  // Alpaca News API
  response = GET /v1/news
    ?symbols={symbols}
    &start={now - hours_back}
    &limit=50
    &include_content=false
  
  // Response structure:
  // {
  //   "news": [
  //     {
  //       "id": int,
  //       "headline": string,
  //       "summary": string,
  //       "author": string,
  //       "created_at": datetime,
  //       "updated_at": datetime,
  //       "url": string,
  //       "symbols": [string],
  //       "source": string
  //     }
  //   ]
  // }
  
  RETURN response.news
```

### 3.2 News Classification

```
FUNCTION classify_news(news_items):
  
  catalysts = []
  
  FOR item IN news_items:
    
    headline_lower = item.headline.lower()
    
    // Earnings related
    IF contains_any(headline_lower, ["earnings", "eps", "revenue", "guidance"]):
      catalyst_type = "EARNINGS"
      
    // Fed/macro related  
    ELSE IF contains_any(headline_lower, ["fed", "fomc", "rate", "powell", "inflation"]):
      catalyst_type = "MACRO"
      
    // Analyst actions
    ELSE IF contains_any(headline_lower, ["upgrade", "downgrade", "price target", "rating"]):
      catalyst_type = "ANALYST"
      
    // M&A / corporate actions
    ELSE IF contains_any(headline_lower, ["acquire", "merger", "buyout", "split"]):
      catalyst_type = "CORPORATE"
      
    // Product/business news
    ELSE IF contains_any(headline_lower, ["launch", "partnership", "contract", "deal"]):
      catalyst_type = "BUSINESS"
      
    ELSE:
      catalyst_type = "OTHER"
    
    catalysts.append({
      symbol: item.symbols[0],
      type: catalyst_type,
      headline: item.headline,
      timestamp: item.created_at,
      source: item.source
    })
  
  RETURN catalysts
```

---

## Phase 3: Future Enhancements

### 4.1 Economic Calendar Integration

```
// Option A: Static JSON file (simplest)
economic_calendar.json:
{
  "2025": {
    "FOMC": ["2025-01-29", "2025-03-19", "2025-05-07", ...],
    "NFP": ["2025-01-10", "2025-02-07", ...],
    "CPI": ["2025-01-15", "2025-02-12", ...]
  }
}

// Option B: Forex Factory scraper
// Option C: Trading Economics API
// Option D: Alpha Vantage economic calendar
```

### 4.2 Earnings Calendar

```
// Could use:
// - Alpaca News (filter for earnings announcements)
// - Alpha Vantage earnings calendar
// - Yahoo Finance earnings calendar
// - Manually maintained watchlist with earnings dates
```

### 4.3 Twitter/X Integration (Future)

```
// Options:
// - Official Twitter API (expensive: $100+/month)
// - Nitter instances (free but unreliable)
// - Social sentiment APIs (StockTwits, Sentdex)
// - Skip for now, add later if valuable
```

---

## Implementation Sequence

```
PHASE 1 - MVP (Week 1)
├── Day 1-2: Data fetching layer
│   ├── Alpaca client wrapper
│   ├── Bars fetching with caching
│   └── Snapshot fetching
│
├── Day 3-4: Calculations
│   ├── Key levels calculation
│   ├── Market regime detection
│   ├── Index divergence
│   └── Relative strength
│
├── Day 5: Scenario generation
│   ├── Rule-based scenario builder
│   └── Stance determination
│
└── Day 6-7: Output generation
    ├── DailyPreview assembly
    ├── Text/markdown formatter
    └── Manual testing with real data

PHASE 2 - News (Week 2)
├── Alpaca News integration
├── News classification
└── Catalyst highlighting in preview

PHASE 3 - Polish (Week 3)
├── Scheduling (morning cron job)
├── Delivery (email? Push notification? In-app?)
├── Historical storage for backtesting
└── Tuning thresholds based on usage
```

---

## Output Format

### Text Output (MVP)

```
══════════════════════════════════════════════════════════════
DAILY MARKET PREVIEW - Friday, December 13, 2025
Generated: 6:30 AM ET
══════════════════════════════════════════════════════════════

OVERNIGHT SUMMARY
─────────────────
Futures flat to slightly lower after Thursday's chop. ES -0.2%, 
NQ -0.4%. AVGO earnings moved after-hours but fading into 
pre-market. Still inside the 2-week range on QQQ.

MARKET REGIME: RANGING (Day 10)
Expected Volatility: NORMAL

INDEX DIVERGENCE
─────────────────
        5D Perf    From ATH    Status
SPY     +0.8%      -0.3%       LEADING
QQQ     -0.2%      -2.1%       LAGGING  
DIA     +1.2%      +0.0%       AT ATH

⚠️  Tech lagging overall market. NQ names harder to trade.
    Consider SPY components or look elsewhere (commodities).

SPY KEY LEVELS
─────────────────
Resistance:  690.00  (ATH)
Pivot:       688.00  (Last week high)
Support:     685.00  (Friday low)
Current:     687.50  (middle of range)

SCENARIOS
─────────────────
BULLISH:  Break above 690, hold → new ATH territory
BEARISH:  Break below 685 → push toward 682
BOUNCE:   Dip to 685, buyers step in → reclaim 688
FADE:     Pop to 690, rejection → back to 688

QQQ KEY LEVELS
─────────────────
Resistance:  625.00  (Last week high)
Pivot:       622.00  (Equilibrium)
Support:     618.00  (Monday low)
Current:     621.50  (middle of range)

SCENARIOS
─────────────────
BULLISH:  Break above 625, hold → continuation to ATH
BEARISH:  Break below 618 → push toward 615
BOUNCE:   Dip to 618, hold → reclaim 622
FADE:     Pop to 625, rejection → fade to 622

WATCHLIST
─────────────────
HIGH CONVICTION:
  • GLD  - Breaking out of base, 416 key level, LONG bias
  • PLTR - Above Monday high 183.50, continuation setup

MONITORING:
  • TSLA - Ranging 445-455, wait for direction
  • AVGO - Post-earnings, watch 372 support after fade

AVOID/CAUTIOUS:
  • NVDA - Lagging, no clear setup
  • AMD  - Ranging, semis weak overall

SECTOR NOTES
─────────────────
Relative Strength:  GLD, SLV, DIA components
Relative Weakness:  Semiconductors (NVDA, AMD), META

GAME PLAN
─────────────────
Stance: CAUTIOUS
Size:   HALF
Focus:  Still ranging on QQQ - play extremes only. 
        Wait for first 15min to establish direction.
        
Risk Notes:
  • Day 10 of range - breakout could come any day
  • Semis lagging - avoid unless clear catalyst
  • Friday - expect lower volume into close

══════════════════════════════════════════════════════════════
```

---

## Configuration

```
config.yaml:

alpaca:
  api_key: ${ALPACA_API_KEY}
  api_secret: ${ALPACA_API_SECRET}
  base_url: "https://data.alpaca.markets"
  
symbols:
  indices: [SPY, QQQ, DIA, IWM]
  mag7: [AAPL, MSFT, GOOGL, AMZN, NVDA, META, TSLA]
  semiconductors: [AMD, AVGO, MU, TSM]
  momentum: [PLTR, HOOD, SOFI, COIN]
  commodities: [GLD, SLV, USO]

thresholds:
  ranging_atr_multiple: 3.0      # range < 3x ATR = ranging
  divergence_threshold: 0.02     # 2% diff = divergent
  relative_strength_strong: 0.03 # 3% outperformance = strong
  near_level_threshold: 0.005    # 0.5% = "near" a level

schedule:
  generate_time: "06:30"         # ET
  timezone: "America/New_York"
  
output:
  format: "markdown"             # or "json", "html"
  destination: "stdout"          # or "file", "email", "webhook"
```

---

## Testing Strategy

```
1. UNIT TESTS
   - Key level calculation with known data
   - Regime detection edge cases
   - Divergence calculation accuracy

2. INTEGRATION TESTS  
   - Full pipeline with mocked Alpaca responses
   - Output format validation

3. MANUAL VALIDATION
   - Compare generated preview to manual analysis
   - Run for 1 week, note discrepancies
   - Tune thresholds based on feedback

4. HISTORICAL BACKTESTING (Future)
   - Store daily previews
   - Compare scenarios to actual outcomes
   - Measure accuracy of regime detection
```