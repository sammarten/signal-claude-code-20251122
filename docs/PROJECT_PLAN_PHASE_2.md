I'll search through your project knowledge to understand the trading strategies you want to implement, then create a comprehensive Phase 2 plan.Based on my review of your project knowledge and Phase 1 accomplishments, I'll create a comprehensive Phase 2 plan for implementing your break and retest trading strategies. This plan builds on your solid technical foundation.

# Phase 2 Project Plan: Trading Strategy Implementation

## Executive Summary

**Objective**: Implement algorithmic break and retest trading strategies with supporting technical analysis to generate high-probability trade signals during the first 1.5 hours of market hours (9:30-11:00 AM ET).

**Duration**: 4-6 weeks
**Success Criteria**:

- Automated detection of break and retest patterns across all configured symbols
- Real-time signal generation with quality scoring
- Historical backtesting capability with performance metrics
- Dashboard visualization of setups and signals

---

## Phase 2 Architecture Overview

```
Phase 1 Infrastructure (Complete)
├── Real-time Data (BarCache, PubSub)
├── Historical Storage (TimescaleDB)
├── WebSocket Streaming (Alpaca)
└── LiveView Dashboard

Phase 2 Addition
├── Technical Analysis Layer
│   ├── Market Structure (BOS, ChoCh, Swings)
│   ├── Key Levels (Daily, Premarket, Opening Range)
│   ├── PD Arrays (Order Blocks, Fair Value Gaps)
│   └── Price Action (Candle Patterns)
├── Strategy Engine
│   ├── Break and Retest Detector
│   ├── Entry Signal Generator
│   ├── Confluence Analyzer
│   └── Quality Scoring System
├── Signal Management
│   ├── Signal Storage (Events table)
│   ├── Signal Broadcasting (PubSub)
│   └── Performance Tracking
└── Dashboard Enhancements
    ├── Setup Visualization
    ├── Signal Alerts
    └── Trade Journal
```

---

## Task Breakdown

### **Task 1: Market Structure & Key Levels Detection** (Week 1)

_Foundation for all trading decisions_

#### 1.1 Daily Reference Levels Module

**Location**: `lib/signal/technicals/levels.ex`

**Responsibilities**:

- Track previous day high/low (PDH/PDL)
- Track premarket high/low (PMH/PML)
- Track opening range high/low (ORH/ORL - 5min and 15min)
- Identify whole/half psychological numbers
- Store in database for historical analysis

**Data Structure**:

```elixir
%KeyLevels{
  symbol: "AAPL",
  date: ~D[2024-11-23],
  previous_day_high: Decimal.new("175.50"),
  previous_day_low: Decimal.new("173.20"),
  premarket_high: Decimal.new("174.80"),
  premarket_low: Decimal.new("174.10"),
  opening_range_5m_high: Decimal.new("174.90"),
  opening_range_5m_low: Decimal.new("174.50"),
  opening_range_15m_high: Decimal.new("175.10"),
  opening_range_15m_low: Decimal.new("174.30")
}
```

**Functions**:

- `calculate_daily_levels/2` - Compute all reference levels for a symbol/date
- `get_current_levels/1` - Get today's levels for a symbol
- `level_broken?/3` - Check if price has broken a level
- `find_nearest_psychological/1` - Find nearest whole/half numbers

**Integration**:

- Subscribe to `"bars:{symbol}"` PubSub
- Calculate opening range after 9:35 AM and 9:45 AM
- Broadcast `"levels:{symbol}"` when levels update
- Store in `key_levels` table for backtesting

#### 1.2 Market Structure Module

**Location**: `lib/signal/technicals/market_structure.ex`

**Responsibilities**:

- Detect swing highs and swing lows
- Identify Break of Structure (BOS)
- Identify Change of Character (ChoCh)
- Determine market direction (bullish/bearish/ranging)

**Swing Detection Algorithm**:

```elixir
# Swing High: High is higher than N bars before and after (typically N=2)
def swing_high?(bars, index, lookback \\ 2) do
  current = Enum.at(bars, index)

  before_bars = Enum.slice(bars, max(0, index - lookback), lookback)
  after_bars = Enum.slice(bars, index + 1, lookback)

  Enum.all?(before_bars, &(current.high > &1.high)) and
  Enum.all?(after_bars, &(current.high > &1.high))
end
```

**BOS Detection**:

```elixir
# Bullish BOS: Price breaks above previous swing high
# Bearish BOS: Price breaks below previous swing low
def detect_bos(bars) do
  swings = identify_swings(bars)
  latest_bar = List.last(bars)

  case get_trend(swings) do
    :bullish ->
      prev_swing_high = find_previous_swing_high(swings)
      if latest_bar.close > prev_swing_high.high, do: {:bos, :bullish}

    :bearish ->
      prev_swing_low = find_previous_swing_low(swings)
      if latest_bar.close < prev_swing_low.low, do: {:bos, :bearish}
  end
end
```

**Data Structure**:

```elixir
%MarketStructure{
  symbol: "AAPL",
  timeframe: :daily,  # :daily, :m30, :m1
  trend: :bullish,    # :bullish, :bearish, :ranging
  swing_highs: [%Swing{}, ...],
  swing_lows: [%Swing{}, ...],
  latest_bos: %{type: :bullish, time: ~U[...], price: Decimal.new("175.50")},
  latest_choch: %{type: :bearish, time: ~U[...], price: Decimal.new("174.20")}
}
```

**Deliverables**:

- `lib/signal/technicals/swings.ex` - Swing detection
- `lib/signal/technicals/market_structure.ex` - BOS/ChoCh detection
- `priv/repo/migrations/*_create_market_structure.exs`
- `test/signal/technicals/market_structure_test.exs`

**Database Schema**:

```sql
CREATE TABLE market_structure (
  symbol TEXT NOT NULL,
  timeframe TEXT NOT NULL,
  bar_time TIMESTAMPTZ NOT NULL,
  trend TEXT,
  swing_type TEXT,  -- 'high' or 'low'
  swing_price NUMERIC,
  bos_detected BOOLEAN,
  choch_detected BOOLEAN,
  PRIMARY KEY (symbol, timeframe, bar_time)
);
```

---

### **Task 2: PD Arrays - Order Blocks & Fair Value Gaps** (Week 2)

_Smart Money Concepts for high-probability zones_

#### 2.1 Fair Value Gap (FVG) Detection

**Location**: `lib/signal/technicals/pd_arrays/fair_value_gap.ex`

**Definition**: A FVG forms when there's a gap between candles showing aggressive price movement.

**Detection Algorithm**:

```elixir
def detect_fvg(bar1, bar2, bar3) do
  # Bullish FVG: Gap between bar1 high and bar3 low
  bullish_gap = bar3.low - bar1.high

  # Bearish FVG: Gap between bar1 low and bar3 high
  bearish_gap = bar1.low - bar3.high

  cond do
    bullish_gap > 0 ->
      {:ok, %FVG{
        type: :bullish,
        top: bar3.low,
        bottom: bar1.high,
        bar_time: bar2.bar_time,
        mitigated: false
      }}

    bearish_gap > 0 ->
      {:ok, %FVG{
        type: :bearish,
        top: bar1.low,
        bottom: bar3.high,
        bar_time: bar2.bar_time,
        mitigated: false
      }}

    true -> {:error, :no_gap}
  end
end

def check_mitigation(fvg, current_bar) do
  case fvg.type do
    :bullish -> current_bar.low <= fvg.bottom
    :bearish -> current_bar.high >= fvg.top
  end
end
```

#### 2.2 Order Block Detection

**Location**: `lib/signal/technicals/pd_arrays/order_block.ex`

**Definition**: Last opposing candle(s) before a strong move (BOS).

**Detection Criteria**:

1. Identify BOS on target timeframe
2. Find the last opposing candles before BOS
3. Mark the body range (open to close) as order block
4. Check for FVG overlap (increases confluence)
5. Verify it was created from another PD array

**Detection Algorithm**:

```elixir
def detect_order_block(bars, bos_index) do
  bos_bar = Enum.at(bars, bos_index)

  # For bullish BOS, find last bearish candles before the move
  opposing_candles =
    bars
    |> Enum.slice(0, bos_index)
    |> Enum.reverse()
    |> Enum.take_while(&is_opposing_candle?(&1, bos_bar.trend))

  if Enum.any?(opposing_candles) do
    # Get highest wick among opposing candles
    highest_wick = opposing_candles
                   |> Enum.max_by(& &1.high)
                   |> Map.get(:high)

    first_candle = List.last(opposing_candles)
    last_candle = List.first(opposing_candles)

    %OrderBlock{
      type: opposite_type(bos_bar.trend),
      top: highest_wick,
      bottom: first_candle.open,
      body_top: last_candle.close,
      body_bottom: first_candle.open,
      bar_time: last_candle.bar_time,
      mitigated: false,
      has_fvg_confluence: check_fvg_overlap(last_candle, fvgs)
    }
  end
end
```

**Quality Scoring**:

```elixir
def score_order_block(ob, context) do
  score = 0

  # +2 points: Overlaps with FVG
  score = if ob.has_fvg_confluence, do: score + 2, else: score

  # +1 point: Created from liquidity sweep
  score = if context.liquidity_sweep?, do: score + 1, else: score

  # +1 point: Aligns with higher timeframe structure
  score = if context.htf_aligned?, do: score + 1, else: score

  # +1 point: Unmitigated
  score = if not ob.mitigated, do: score + 1, else: score

  %{ob | quality_score: score, max_score: 5}
end
```

**Deliverables**:

- `lib/signal/technicals/pd_arrays/fair_value_gap.ex`
- `lib/signal/technicals/pd_arrays/order_block.ex`
- `priv/repo/migrations/*_create_pd_arrays.exs`
- `test/signal/technicals/pd_arrays_test.exs`

---

### **Task 3: Break and Retest Strategy Engine** (Week 3)

_Core trading logic_

#### 3.1 Break and Retest Detector

**Location**: `lib/signal/strategies/break_and_retest.ex`

**Entry Model Requirements**:

1. **Break Phase**: Price must break above/below key level with momentum
2. **Retest Phase**: Price pulls back to test broken level
3. **Confirmation Phase**: Strong price action candle at retest
4. **Continuation Phase**: Price resumes in break direction

**Detection Algorithm**:

```elixir
defmodule Signal.Strategies.BreakAndRetest do
  @moduledoc """
  Detects break and retest patterns on key levels.

  ## Entry Criteria
  - Break of key level (PDH/PDL, PMH/PML, ORH/ORL)
  - Retest shows strong rejection candle
  - Minimum 2:1 risk-reward available
  - Aligns with market structure
  - Occurs within trading window (9:30-11:00 AM ET)
  """

  def evaluate(symbol) do
    with {:ok, levels} <- get_current_levels(symbol),
         {:ok, bars} <- get_recent_bars(symbol, 30),
         {:ok, structure} <- get_market_structure(symbol),
         {:ok, pd_arrays} <- get_pd_arrays(symbol) do

      levels
      |> identify_broken_levels(bars)
      |> Enum.map(&check_retest(&1, bars, structure, pd_arrays))
      |> Enum.filter(&valid_setup?/1)
      |> Enum.map(&score_setup/1)
    end
  end

  defp identify_broken_levels(levels, bars) do
    latest_bar = List.last(bars)
    previous_bar = Enum.at(bars, -2)

    [
      check_level_break(:pdh, levels.previous_day_high, previous_bar, latest_bar),
      check_level_break(:pdl, levels.previous_day_low, previous_bar, latest_bar),
      check_level_break(:pmh, levels.premarket_high, previous_bar, latest_bar),
      check_level_break(:pml, levels.premarket_low, previous_bar, latest_bar),
      check_level_break(:or5h, levels.opening_range_5m_high, previous_bar, latest_bar),
      check_level_break(:or5l, levels.opening_range_5m_low, previous_bar, latest_bar),
    ]
    |> Enum.filter(&(&1.broken?))
  end

  defp check_retest(broken_level, bars, structure, pd_arrays) do
    retest_bars = bars |> Enum.take(-15)  # Last 15 bars after break

    case find_retest_candle(broken_level, retest_bars) do
      {:ok, retest_bar} ->
        %Setup{
          type: :break_and_retest,
          direction: broken_level.direction,
          level_type: broken_level.type,
          level_price: broken_level.price,
          retest_bar: retest_bar,
          entry_price: calculate_entry(retest_bar, broken_level.direction),
          stop_loss: calculate_stop(retest_bar, broken_level.direction),
          take_profit: calculate_target(retest_bar, broken_level, structure),
          confluence: calculate_confluence(broken_level, pd_arrays, structure),
          timestamp: DateTime.utc_now()
        }

      {:error, _} -> nil
    end
  end

  defp find_retest_candle(broken_level, bars) do
    # Look for price returning to broken level
    bars
    |> Enum.find(fn bar ->
      case broken_level.direction do
        :bullish ->
          # For bullish break, retest should touch level from above
          bar.low <= broken_level.price and bar.close > broken_level.price

        :bearish ->
          # For bearish break, retest should touch level from below
          bar.high >= broken_level.price and bar.close < broken_level.price
      end
    end)
    |> case do
      nil -> {:error, :no_retest}
      bar -> {:ok, bar}
    end
  end

  defp calculate_entry(retest_bar, direction) do
    case direction do
      :bullish -> retest_bar.high  # Enter above retest bar
      :bearish -> retest_bar.low   # Enter below retest bar
    end
  end

  defp calculate_stop(retest_bar, direction) do
    case direction do
      :bullish -> Decimal.sub(retest_bar.low, Decimal.new("0.10"))
      :bearish -> Decimal.add(retest_bar.high, Decimal.new("0.10"))
    end
  end

  defp calculate_target(retest_bar, broken_level, structure) do
    entry = calculate_entry(retest_bar, broken_level.direction)
    stop = calculate_stop(retest_bar, broken_level.direction)
    risk = Decimal.abs(Decimal.sub(entry, stop))

    # Minimum 2:1 reward
    reward = Decimal.mult(risk, Decimal.new("2"))

    case broken_level.direction do
      :bullish -> Decimal.add(entry, reward)
      :bearish -> Decimal.sub(entry, reward)
    end
  end
end
```

#### 3.2 Opening Range Strategy

**Location**: `lib/signal/strategies/opening_range.ex`

**Specific Rules**:

- Mark 5-minute high/low (9:30-9:35 AM)
- Mark 15-minute high/low (9:30-9:45 AM)
- Wait for break outside range
- Look for retest of broken range
- Enter on strong price action candle
- Target 2:1 minimum

```elixir
defmodule Signal.Strategies.OpeningRange do
  def evaluate(symbol) do
    levels = get_current_levels(symbol)
    bars = get_bars_since_open(symbol)

    # Check if opening ranges are established
    with {:ok, :established} <- check_ranges_ready(levels),
         {:ok, break} <- detect_range_break(levels, bars),
         {:ok, retest} <- detect_retest(break, bars) do

      generate_signal(%{
        type: :opening_range_breakout,
        range: break.range,  # :or5m or :or15m
        direction: break.direction,
        entry: retest.entry_price,
        stop: retest.stop_loss,
        target: retest.take_profit,
        confluence: score_confluence(break, retest, levels)
      })
    end
  end
end
```

#### 3.3 One Candle Rule Strategy

**Location**: `lib/signal/strategies/one_candle_rule.ex`

**Rules**:

- In uptrend: Last red candle before continuation becomes support
- In downtrend: Last green candle before continuation becomes resistance
- Wait for break above/below, then retest

```elixir
defmodule Signal.Strategies.OneCandleRule do
  def evaluate(symbol) do
    structure = get_market_structure(symbol)
    bars = get_recent_bars(symbol, 50)

    case structure.trend do
      :bullish -> find_last_bearish_candle(bars)
      :bearish -> find_last_bullish_candle(bars)
      _ -> {:error, :no_trend}
    end
    |> check_for_break_and_retest(bars)
  end
end
```

**Deliverables**:

- `lib/signal/strategies/break_and_retest.ex`
- `lib/signal/strategies/opening_range.ex`
- `lib/signal/strategies/one_candle_rule.ex`
- `lib/signal/strategies/premarket_breakout.ex`
- `test/signal/strategies/*_test.exs`

---

### **Task 4: Signal Generation & Quality Scoring** (Week 4)

_Confluence-based decision making_

#### 4.1 Confluence Analyzer

**Location**: `lib/signal/confluence_analyzer.ex`

**Confluence Factors**:

1. **Multi-timeframe alignment** (+3 points): Daily, 30-min, 1-min all agree
2. **PD Array confluence** (+2 points): Order block + FVG overlap
3. **Key level confluence** (+2 points): Multiple levels align (PDH + PMH)
4. **Market structure** (+2 points): BOS in same direction
5. **Volume confirmation** (+1 point): Above average volume on break
6. **Price action quality** (+1 point): Strong rejection candle
7. **Time window** (+1 point): Within first 30 minutes of open
8. **Risk-reward** (+1 point): 3:1 or better available

```elixir
defmodule Signal.ConfluenceAnalyzer do
  def analyze(setup) do
    %{
      total_score: calculate_total(setup),
      max_score: 13,
      factors: %{
        timeframe_alignment: check_timeframe_alignment(setup),
        pd_array_confluence: check_pd_arrays(setup),
        key_level_confluence: check_key_levels(setup),
        market_structure: check_structure(setup),
        volume: check_volume(setup),
        price_action: check_price_action(setup),
        timing: check_timing(setup),
        risk_reward: check_risk_reward(setup)
      },
      grade: assign_grade(total_score)
    }
  end

  defp assign_grade(score) do
    cond do
      score >= 10 -> :A  # Excellent - take with confidence
      score >= 8  -> :B  # Very good - high probability
      score >= 6  -> :C  # Good - moderate probability
      score >= 4  -> :D  # Fair - lower probability
      true        -> :F  # Poor - avoid
    end
  end
end
```

#### 4.2 Signal Generator & Storage

**Location**: `lib/signal/signal_generator.ex`

```elixir
defmodule Signal.SignalGenerator do
  @moduledoc """
  Generates trade signals and stores them in the events table.
  Broadcasts signals via PubSub for real-time consumption.
  """

  def generate_signal(setup, confluence) do
    signal = %Signal{
      id: UUID.uuid4(),
      symbol: setup.symbol,
      strategy: setup.type,
      direction: setup.direction,
      entry_price: setup.entry_price,
      stop_loss: setup.stop_loss,
      take_profit: setup.take_profit,
      risk_reward: calculate_rr(setup),
      confluence_score: confluence.total_score,
      quality_grade: confluence.grade,
      factors: confluence.factors,
      timestamp: DateTime.utc_now(),
      status: :active,
      expires_at: calculate_expiry(setup)
    }

    # Store in database
    {:ok, event} = store_signal_event(signal)

    # Broadcast to subscribers
    Phoenix.PubSub.broadcast(
      Signal.PubSub,
      "signals:#{signal.symbol}",
      {:signal_generated, signal}
    )

    Phoenix.PubSub.broadcast(
      Signal.PubSub,
      "signals:all",
      {:signal_generated, signal}
    )

    {:ok, signal}
  end
end
```

**Database Schema**:

```sql
CREATE TABLE trade_signals (
  id UUID PRIMARY KEY,
  symbol TEXT NOT NULL,
  strategy TEXT NOT NULL,
  direction TEXT NOT NULL,  -- 'long' or 'short'
  entry_price NUMERIC NOT NULL,
  stop_loss NUMERIC NOT NULL,
  take_profit NUMERIC NOT NULL,
  risk_reward NUMERIC NOT NULL,
  confluence_score INTEGER NOT NULL,
  quality_grade TEXT NOT NULL,
  confluence_factors JSONB,
  status TEXT NOT NULL,  -- 'active', 'filled', 'expired', 'invalidated'
  generated_at TIMESTAMPTZ NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  filled_at TIMESTAMPTZ,
  exit_price NUMERIC,
  pnl NUMERIC,

  CONSTRAINT valid_direction CHECK (direction IN ('long', 'short')),
  CONSTRAINT valid_status CHECK (status IN ('active', 'filled', 'expired', 'invalidated'))
);

CREATE INDEX idx_signals_symbol_status ON trade_signals(symbol, status);
CREATE INDEX idx_signals_generated_at ON trade_signals(generated_at DESC);
CREATE INDEX idx_signals_quality ON trade_signals(quality_grade, confluence_score);
```

**Deliverables**:

- `lib/signal/confluence_analyzer.ex`
- `lib/signal/signal_generator.ex`
- `priv/repo/migrations/*_create_trade_signals.exs`
- `test/signal/signal_generation_test.exs`

---

### **Task 5: Dashboard Integration & Visualization** (Week 5)

_Real-time monitoring_

#### 5.1 Signals LiveView

**Location**: `lib/signal_web/live/signals_live.ex`

**Features**:

- Real-time signal list with quality grades
- Color-coded by direction (green=long, red=short)
- Expandable cards showing full setup details
- Confluence factor breakdown
- Chart visualization of setup
- One-click "view details" to see annotated chart

**Layout**:

```
┌─────────────────────────────────────────────────────────────┐
│  Active Signals (4)                    Grade: [All ▼]       │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌──────────────────────────────────────────────┐          │
│  │ AAPL  LONG  Opening Range Breakout     Grade A│          │
│  │ Entry: $175.50  Stop: $175.20  Target: $176.10│          │
│  │ R:R 2.0:1  Score: 11/13  ⏰ 9:47 AM           │          │
│  │                                                │          │
│  │ Confluence: ✓ Timeframe ✓ Order Block         │          │
│  │            ✓ Key Level  ✓ Market Structure    │          │
│  └──────────────────────────────────────────────┘          │
│                                                              │
│  ┌──────────────────────────────────────────────┐          │
│  │ NVDA  LONG  Break & Retest PDH          Grade B│          │
│  │ Entry: $142.30  Stop: $141.90  Target: $143.10│          │
│  │ R:R 2.0:1  Score: 9/13  ⏰ 9:52 AM            │          │
│  └──────────────────────────────────────────────┘          │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

#### 5.2 Setup Details Component

**Location**: `lib/signal_web/live/components/setup_details.ex`

**Features**:

- Mini price chart with annotations
- Entry zone highlighted
- Stop loss and take profit levels marked
- Key levels drawn
- Order blocks/FVGs highlighted
- Confluence factor checklist

#### 5.3 Strategy Performance Panel

**Location**: `lib/signal_web/live/components/strategy_performance.ex`

**Metrics**:

- Win rate by strategy
- Average R:R achieved
- Best/worst setups
- Quality grade distribution
- Time-of-day performance

**Deliverables**:

- `lib/signal_web/live/signals_live.ex`
- `lib/signal_web/live/components/setup_details.ex`
- `lib/signal_web/live/components/strategy_performance.ex`
- `assets/js/chart_annotations.js`

---

### **Task 6: Background Processing & Scheduling** (Week 6)

_Continuous evaluation_

#### 6.1 Strategy Evaluator GenServer

**Location**: `lib/signal/strategy_evaluator.ex`

**Responsibilities**:

- Subscribe to bar updates for all symbols
- Run strategy evaluation on each new bar
- Generate signals when setups detected
- Invalidate expired/broken setups

```elixir
defmodule Signal.StrategyEvaluator do
  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(_state) do
    # Subscribe to bar updates for all configured symbols
    for symbol <- Application.get_env(:signal, :symbols) do
      Phoenix.PubSub.subscribe(Signal.PubSub, "bars:#{symbol}")
    end

    {:ok, %{}}
  end

  def handle_info({:bar_update, bar}, state) do
    # Run all strategies for this symbol
    Task.start(fn ->
      evaluate_strategies(bar.symbol)
    end)

    {:noreply, state}
  end

  defp evaluate_strategies(symbol) do
    strategies = [
      Signal.Strategies.BreakAndRetest,
      Signal.Strategies.OpeningRange,
      Signal.Strategies.OneCandleRule,
      Signal.Strategies.PremarketBreakout
    ]

    for strategy <- strategies do
      case strategy.evaluate(symbol) do
        {:ok, setup} ->
          confluence = Signal.ConfluenceAnalyzer.analyze(setup)

          if confluence.grade in [:A, :B] do
            Signal.SignalGenerator.generate_signal(setup, confluence)
          end

        {:error, _reason} -> :ok
      end
    end
  end
end
```

#### 6.2 Level Calculator Scheduler

**Location**: `lib/signal/level_calculator.ex`

**Schedule**:

- **4:00 AM ET**: Calculate previous day high/low
- **9:00 AM ET**: Calculate premarket high/low
- **9:35 AM ET**: Calculate 5-minute opening range
- **9:45 AM ET**: Calculate 15-minute opening range

```elixir
defmodule Signal.LevelCalculator do
  use GenServer

  def init(state) do
    # Schedule level calculations
    schedule_daily_levels()
    schedule_premarket_levels()
    schedule_opening_range_5m()
    schedule_opening_range_15m()

    {:ok, state}
  end

  defp schedule_daily_levels do
    # Run at 4:00 AM ET every day
    Quantum.add_job(:daily_levels, "0 4 * * *", fn ->
      calculate_all_daily_levels()
    end)
  end
end
```

**Deliverables**:

- `lib/signal/strategy_evaluator.ex`
- `lib/signal/level_calculator.ex`
- Update `lib/signal/application.ex` supervision tree
- `test/signal/strategy_evaluator_test.exs`

---

## Database Schema Summary

### New Tables for Phase 2:

```sql
-- Key Levels (daily reference points)
CREATE TABLE key_levels (
  symbol TEXT NOT NULL,
  date DATE NOT NULL,
  previous_day_high NUMERIC NOT NULL,
  previous_day_low NUMERIC NOT NULL,
  premarket_high NUMERIC,
  premarket_low NUMERIC,
  opening_range_5m_high NUMERIC,
  opening_range_5m_low NUMERIC,
  opening_range_15m_high NUMERIC,
  opening_range_15m_low NUMERIC,
  PRIMARY KEY (symbol, date)
);

-- Market Structure (swings, BOS, ChoCh)
CREATE TABLE market_structure (
  symbol TEXT NOT NULL,
  timeframe TEXT NOT NULL,
  bar_time TIMESTAMPTZ NOT NULL,
  trend TEXT,
  swing_type TEXT,
  swing_price NUMERIC,
  bos_detected BOOLEAN DEFAULT false,
  choch_detected BOOLEAN DEFAULT false,
  PRIMARY KEY (symbol, timeframe, bar_time)
);

-- PD Arrays (Order Blocks, FVGs)
CREATE TABLE pd_arrays (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  symbol TEXT NOT NULL,
  type TEXT NOT NULL,  -- 'order_block' or 'fvg'
  direction TEXT NOT NULL,  -- 'bullish' or 'bearish'
  top NUMERIC NOT NULL,
  bottom NUMERIC NOT NULL,
  created_at TIMESTAMPTZ NOT NULL,
  mitigated BOOLEAN DEFAULT false,
  mitigated_at TIMESTAMPTZ,
  quality_score INTEGER,
  metadata JSONB
);

CREATE INDEX idx_pd_arrays_symbol_type ON pd_arrays(symbol, type, mitigated);

-- Trade Signals
CREATE TABLE trade_signals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  symbol TEXT NOT NULL,
  strategy TEXT NOT NULL,
  direction TEXT NOT NULL,
  entry_price NUMERIC NOT NULL,
  stop_loss NUMERIC NOT NULL,
  take_profit NUMERIC NOT NULL,
  risk_reward NUMERIC NOT NULL,
  confluence_score INTEGER NOT NULL,
  quality_grade TEXT NOT NULL,
  confluence_factors JSONB,
  status TEXT NOT NULL DEFAULT 'active',
  generated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at TIMESTAMPTZ NOT NULL,
  filled_at TIMESTAMPTZ,
  exit_price NUMERIC,
  pnl NUMERIC
);

CREATE INDEX idx_signals_symbol_status ON trade_signals(symbol, status);
CREATE INDEX idx_signals_quality ON trade_signals(quality_grade, confluence_score);
```

---

## Testing Strategy

### Unit Tests

- Test each module in isolation
- Mock dependencies (BarCache, database)
- Cover edge cases (gaps, incomplete data)
- Test mathematical calculations (R:R, confluence scores)

### Integration Tests

- Test end-to-end signal generation
- Use historical data fixtures
- Verify PubSub message flow
- Test dashboard rendering with test data

### Backtesting Tests

- Load 5 years of historical data
- Run strategies over past data
- Validate signal generation matches expected setups
- Calculate historical performance metrics

**Test Coverage Goal**: >80%

---

## Phase 2 Deliverables Checklist

### Week 1: Market Structure

- [ ] `lib/signal/technicals/levels.ex` - Key level calculator
- [ ] `lib/signal/technicals/swings.ex` - Swing detection
- [ ] `lib/signal/technicals/market_structure.ex` - BOS/ChoCh
- [ ] Database migrations for market_structure
- [ ] Unit tests (15+ test cases)
- [ ] Integration with BarCache

### Week 2: PD Arrays

- [ ] `lib/signal/technicals/pd_arrays/fair_value_gap.ex`
- [ ] `lib/signal/technicals/pd_arrays/order_block.ex`
- [ ] Database migrations for pd_arrays
- [ ] Unit tests (20+ test cases)
- [ ] Quality scoring algorithms

### Week 3: Strategy Engine

- [ ] `lib/signal/strategies/break_and_retest.ex`
- [ ] `lib/signal/strategies/opening_range.ex`
- [ ] `lib/signal/strategies/one_candle_rule.ex`
- [ ] `lib/signal/strategies/premarket_breakout.ex`
- [ ] Unit tests (30+ test cases)
- [ ] Strategy evaluation tests with fixtures

### Week 4: Signal Generation

- [ ] `lib/signal/confluence_analyzer.ex`
- [ ] `lib/signal/signal_generator.ex`
- [ ] Database migrations for trade_signals
- [ ] Unit tests (15+ test cases)
- [ ] PubSub integration tests

### Week 5: Dashboard

- [ ] `lib/signal_web/live/signals_live.ex`
- [ ] `lib/signal_web/live/components/setup_details.ex`
- [ ] `lib/signal_web/live/components/strategy_performance.ex`
- [ ] Chart annotation JavaScript
- [ ] LiveView tests

### Week 6: Background Processing

- [ ] `lib/signal/strategy_evaluator.ex` GenServer
- [ ] `lib/signal/level_calculator.ex` Scheduler
- [ ] Update supervision tree
- [ ] Integration tests
- [ ] Performance testing

### Documentation

- [ ] Phase 2 README with strategy explanations
- [ ] API documentation for new modules
- [ ] Trading rules documentation
- [ ] Confluence scoring guide
- [ ] Dashboard user guide

---

## Success Metrics

### Functional Metrics

1. **Signal Generation**: System generates signals for all configured strategies
2. **Real-time Performance**: Signals generated within 1 second of setup detection
3. **Quality Filtering**: Only A/B grade signals displayed by default
4. **Accuracy**: 0 false positive breakouts (proper retest confirmation)

### Performance Metrics

1. **Database Queries**: <50ms for signal generation
2. **Memory Usage**: <200MB additional for strategy engine
3. **CPU Usage**: <20% during active market hours
4. **Dashboard Latency**: <100ms for signal updates

### Trading Metrics (to be measured in Phase 3 backtesting)

1. **Signal Quality**: Confluence scores >8 for generated signals
2. **Setup Frequency**: 3-10 signals per day across all symbols
3. **Risk-Reward**: All signals meet minimum 2:1 R:R
4. **Time Window Compliance**: All signals within 9:30-11:00 AM ET

---

## Risk Management & Safeguards

### Signal Quality Controls

1. **Minimum confluence score**: 6/13 (Grade C or better)
2. **Required retest confirmation**: No entries on break alone
3. **Risk-reward validation**: Minimum 2:1, ideal 3:1
4. **Time window enforcement**: Reject signals outside 9:30-11:00 AM ET
5. **Maximum signals per symbol**: 2 per day to avoid overtrading

### Data Quality Checks

1. **Missing bars detection**: Alert if gaps in data during market hours
2. **Level validation**: Verify PDH/PDL calculated from complete previous day
3. **Structure validation**: Require minimum 20 bars for swing detection
4. **PD array validation**: FVGs must have measurable gap, OBs must have BOS

### System Safeguards

1. **Signal expiry**: Signals invalidate after 30 minutes if not filled
2. **Setup invalidation**: Monitor for level reclaim that breaks setup
3. **Error handling**: Graceful degradation if module fails
4. **Rate limiting**: Max 1 signal per symbol per 5 minutes

---

## Migration Path from Phase 1

Phase 1 provides the perfect foundation:

```
Phase 1 Infrastructure → Phase 2 Enhancements
├── BarCache → Used by all strategy modules for latest prices
├── Historical Data → Used for backfilling market structure
├── PubSub → Used for signal broadcasting
├── TimescaleDB → Extended with new tables
├── Monitor → Enhanced to track signal generation
└── Dashboard → Extended with Signals LiveView
```

**No breaking changes required** - Phase 2 adds new capabilities without modifying Phase 1 core.

---

## Next Steps After Phase 2

**Phase 3 Preview: Backtesting & Paper Trading**

- Historical signal generation on past data
- Performance metrics calculation
- Trade simulation engine
- Win rate and profit factor analysis
- Strategy optimization
- Paper trading with Alpaca

**Phase 4 Preview: Live Trading (Automated)**

- Order execution integration
- Position management
- Real-time P&L tracking
- Risk management enforcement
- Trade journal automation

---

This Phase 2 plan provides a comprehensive roadmap to implement your break and retest trading strategies on top of the solid Phase 1 infrastructure. The modular design allows for iterative development and testing, with each task building naturally on the previous one.
