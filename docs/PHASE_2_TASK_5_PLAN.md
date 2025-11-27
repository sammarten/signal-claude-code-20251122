# Phase 2 Task 5: Dashboard Integration & Visualization

## Implementation Plan

### Executive Summary

This plan outlines the implementation of Task 5 (Dashboard Integration & Visualization) from Phase 2. A significant amount of infrastructure already exists, so this task focuses on creating the UI layer to visualize signals and setups.

---

## Existing Infrastructure Inventory

### Backend (Complete)

| Component | Location | Status |
|-----------|----------|--------|
| TradeSignal Schema | `lib/signal/signals/trade_signal.ex` | Complete |
| SignalGenerator | `lib/signal/signal_generator.ex` | Complete |
| ConfluenceAnalyzer | `lib/signal/confluence_analyzer.ex` | Complete |
| Setup Struct | `lib/signal/strategies/setup.ex` | Complete |
| BreakAndRetest Strategy | `lib/signal/strategies/break_and_retest.ex` | Complete |
| OpeningRange Strategy | `lib/signal/strategies/opening_range.ex` | Complete |
| OneCandleRule Strategy | `lib/signal/strategies/one_candle_rule.ex` | Complete |
| Database Migration | `priv/repo/migrations/20251126000002_create_trade_signals.exs` | Complete |

**Key Capabilities:**
- Signal generation with rate limiting (1 per symbol per 5 min, 2 per day max)
- Confluence scoring (0-13 points, grades A-F)
- PubSub broadcasting to `signals:{symbol}` and `signals:all` topics
- Signal lifecycle management (active, filled, expired, invalidated)

### Dashboard (Partial)

| Component | Location | Status |
|-----------|----------|--------|
| MarketLive | `lib/signal_web/live/market_live.ex` | Complete |
| SystemStats | `lib/signal_web/live/components/system_stats.ex` | Complete |
| TradingChart Hook | `assets/js/hooks/trading_chart.js` | Complete |
| KeyLevelsManager | `assets/js/hooks/key_levels.js` | Complete |
| SessionHighlighter | `assets/js/hooks/session_highlighter.js` | Complete |

**Current Dashboard Features:**
- Real-time price quotes and candlestick charts
- Key levels displayed on charts (PDH/PDL, PMH/PML, opening ranges)
- Session highlighting (pre-market, regular hours, post-market)
- System health monitoring
- Connection status

---

## What Needs to Be Built

### 1. SignalsLive (`lib/signal_web/live/signals_live.ex`)

**Purpose:** Main signals dashboard page showing real-time trade signals

**Features:**
- Real-time signal list subscribed to `signals:all` topic
- Quality grade filter (All, A, B, C, etc.)
- Direction filter (All, Long, Short)
- Status filter (Active, Filled, Expired)
- Signal cards with:
  - Symbol, direction, strategy name
  - Entry, stop loss, take profit prices
  - Risk/reward ratio
  - Quality grade badge (color-coded)
  - Confluence score with factor breakdown
  - Time since generation
  - Countdown to expiry
- Click to expand for full setup details
- Sound/visual alert for new high-grade signals

**PubSub Subscriptions:**
- `signals:all` - for all signal events
- `signals:{symbol}` - for symbol-specific updates (optional)

### 2. SignalCard Component (`lib/signal_web/live/components/signal_card.ex`)

**Purpose:** Reusable component for displaying a single signal

**Features:**
- Compact view (list item)
- Expanded view (full details)
- Color coding:
  - Green for long positions
  - Red for short positions
  - Grade badges (A=green, B=blue, C=yellow, D=orange, F=red)
- Confluence factor checklist with icons
- Mini sparkline or price indicator

### 3. SetupDetails Component (`lib/signal_web/live/components/setup_details.ex`)

**Purpose:** Detailed view of a signal's setup

**Features:**
- Entry zone highlight
- Stop loss and take profit levels
- Key level that was broken/retested
- Retest bar information
- Break bar information
- Confluence factors with scores
- Risk/reward visualization

### 4. StrategyPerformance Component (`lib/signal_web/live/components/strategy_performance.ex`)

**Purpose:** Show aggregate strategy performance metrics

**Features:**
- Win rate by strategy (requires filled signals with P&L)
- Average R:R achieved
- Signal count by grade
- Signal count by time of day
- Best performing symbols

**Note:** Full metrics require Phase 3 (backtesting) data. Initial implementation will show:
- Total signals generated
- Signals by grade distribution
- Signals by strategy
- Active vs expired vs filled counts

### 5. Chart Annotations Hook (`assets/js/hooks/chart_annotations.js`)

**Purpose:** Visualize signals directly on trading charts

**Features:**
- Entry line (horizontal dashed)
- Stop loss line (red)
- Take profit line (green)
- Entry zone shading
- Signal marker/arrow at retest bar
- Configurable visibility toggle

### 6. SignalMarkers Manager (`assets/js/hooks/signal_markers.js`)

**Purpose:** Manage multiple signal annotations on a single chart

**Features:**
- Add/remove signal markers
- Update signal status (change colors when filled/expired)
- Clear all markers

### 7. Router Updates

Add new route for signals page:

```elixir
scope "/", SignalWeb do
  pipe_through :browser

  live "/", MarketLive, :index
  live "/signals", SignalsLive, :index
end
```

### 8. Navigation Component

Add navigation between Market and Signals views:
- Tab bar or sidebar navigation
- Active state indicator

---

## Implementation Steps

### Step 1: Create SignalsLive Core Structure

1. Create `lib/signal_web/live/signals_live.ex`
2. Implement mount with PubSub subscription to `signals:all`
3. Implement handle_info for signal events
4. Load initial active signals from database
5. Basic render with signal list

### Step 2: Create SignalCard Component

1. Create `lib/signal_web/live/components/signal_card.ex`
2. Implement compact card view
3. Add grade badge styling
4. Add direction color coding
5. Add expiry countdown

### Step 3: Add Filtering and Sorting

1. Add grade filter (A/B/C/D/F/All)
2. Add direction filter (Long/Short/All)
3. Add status filter (Active/Filled/Expired/All)
4. Add sorting (newest first, grade, symbol)

### Step 4: Create SetupDetails Component

1. Create `lib/signal_web/live/components/setup_details.ex`
2. Display full confluence analysis
3. Show entry/stop/target levels
4. Display retest and break bar info

### Step 5: Create Chart Annotations

1. Create `assets/js/hooks/chart_annotations.js`
2. Implement entry/stop/target lines
3. Implement signal marker
4. Register hook in app.js

### Step 6: Integrate Annotations with Charts

1. Add signal overlay capability to TradingChart hook
2. Create SignalMarkers manager
3. Push signal events to charts

### Step 7: Create StrategyPerformance Component

1. Create `lib/signal_web/live/components/strategy_performance.ex`
2. Query aggregate statistics
3. Display grade distribution chart
4. Display strategy breakdown

### Step 8: Update Router and Navigation

1. Add `/signals` route
2. Create navigation component
3. Update MarketLive header with nav link
4. Update SignalsLive header with nav link

### Step 9: Add Signal Alerts

1. Implement browser notification for Grade A/B signals
2. Add sound alert option (configurable)
3. Add visual flash for new signals

### Step 10: Polish and Testing

1. Add loading states
2. Add empty states
3. Add error handling
4. Write LiveView tests
5. Test real-time updates

---

## File Structure (New Files)

```
lib/signal_web/
├── live/
│   ├── signals_live.ex              # New: Main signals dashboard
│   └── components/
│       ├── signal_card.ex           # New: Individual signal card
│       ├── setup_details.ex         # New: Full setup details
│       ├── strategy_performance.ex  # New: Performance metrics
│       └── nav.ex                   # New: Navigation component

assets/js/hooks/
├── chart_annotations.js             # New: Signal annotations on charts
└── signal_markers.js                # New: Signal marker manager
```

---

## Dependencies

- All backend infrastructure is complete
- Lightweight Charts library already installed
- Phoenix PubSub already configured
- TailwindCSS already configured

---

## Testing Strategy

1. **Unit Tests:**
   - SignalCard component rendering
   - SetupDetails component rendering
   - StrategyPerformance calculations

2. **LiveView Tests:**
   - SignalsLive mount and initial load
   - PubSub message handling
   - Filter interactions

3. **Integration Tests:**
   - End-to-end signal display
   - Real-time updates

---

## Success Criteria

1. Signals appear in real-time as they're generated
2. Filtering works correctly for grade, direction, status
3. Signal cards display all relevant information
4. Confluence factors are clearly displayed
5. Chart annotations show signal levels
6. Performance metrics update accurately
7. Navigation between Market and Signals is smooth
8. No performance degradation on main dashboard

---

## Estimated Effort

| Step | Effort |
|------|--------|
| SignalsLive Core | 2-3 hours |
| SignalCard Component | 1-2 hours |
| Filtering/Sorting | 1 hour |
| SetupDetails Component | 1-2 hours |
| Chart Annotations | 2-3 hours |
| StrategyPerformance | 1-2 hours |
| Router/Navigation | 30 min |
| Alerts | 1 hour |
| Polish/Testing | 2-3 hours |
| **Total** | **12-18 hours** |
