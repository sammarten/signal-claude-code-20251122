# Signal Options Trading Integration

## Project Plan - Phase 3 Extension

---

## Executive Summary

This project plan extends Signal's Phase 3 backtesting infrastructure to support options trading alongside the existing equity trading capabilities. The system will use technical analysis against underlying stock prices to generate directional signals, then execute trades via weekly or 0DTE options contracts through Alpaca's Options API.

**Key Design Principles:**

- Configuration-driven: All parameters (instrument type, expiration preference, strike selection, slippage) are configurable for optimization through backtesting
- Instrument abstraction: A unified approach separates equity and options concerns, allowing strategies to remain agnostic to execution vehicle
- Leverage existing infrastructure: Build on current technical analysis, signal generation, and backtesting foundations

---

## Architecture Overview

### Current Flow (Phase 2)

The existing system analyzes stock price action, detects setups via strategies like Break and Retest, and generates trade signals with direction, entry, stop, and target prices.

### Proposed Flow

The new architecture introduces an **Instruments layer** between signal generation and execution:

1. **Strategies** detect setups on the underlying stock (unchanged)
2. **Trade Signals** specify direction and price levels on the underlying (unchanged)
3. **Instrument Resolver** (NEW) determines whether to trade equity or options based on configuration
4. **Contract Selector** (NEW, options only) picks the appropriate contract based on expiration and strike preferences
5. **Price Simulator** (NEW, options only) estimates entry/exit premiums from historical bar data
6. **Execution** places orders for the selected instrument type

This design keeps your proven technical analysis intact while adding options as an alternative execution vehicle.

---

## New Module Concepts

### 1. Instruments Context

A new top-level context that handles the abstraction between tradeable instrument types.

**Instrument Resolver**

- Takes a trade signal and configuration
- Returns either an equity instrument or options instrument
- Configuration determines which path: equity or options

**Equity Instrument**

- Thin wrapper maintaining backward compatibility
- Contains symbol, direction, entry/stop/target prices, quantity

**Options Instrument**

- Derived from the underlying signal
- Contains: underlying symbol, contract symbol (OSI format), contract type (call/put), strike, expiration, premiums, quantity
- For bullish signals → buy calls
- For bearish signals → buy puts

### 2. Contract Selector

Responsible for choosing which specific options contract to trade.

**Inputs:**

- Signal direction (bullish/bearish)
- Current underlying price
- Current date/time
- Configuration preferences

**Configuration Options:**

- Expiration preference: weekly (default) or 0DTE
- Strike selection: ATM (default), 1 strike OTM, or 2 strikes OTM
- Future enhancement: delta-based selection

**Logic:**

- Determines call vs put from signal direction
- Finds appropriate expiration date based on preference and current day
- Selects strike based on configuration (starting with simple OTM logic)
- Builds OSI contract symbol (e.g., AAPL251017C00150000)

### 3. Options Price Simulator

Estimates option premiums for backtesting using Alpaca's historical options bar data.

**Data Source:**

- Alpaca Options Bars API
- 1-minute OHLC data available from February 2024
- Uses opening price for entry simulation, closing price for exit simulation

**Simulation Approach:**

- Given a contract symbol and timestamp, fetch the 1-minute bar
- Entry: use bar open price as simulated fill
- Exit: use bar close price as simulated fill
- Apply configurable slippage factor (percentage added to entry, subtracted from exit)

**Limitations to Document:**

- No bid/ask spread data (bars only)
- Limited historical depth (February 2024 onward)
- Liquidity not directly measurable

### 4. Position Sizer

Calculates how many contracts to purchase.

**Inputs:**

- Portfolio value (from account or backtest state)
- Risk percentage (1-2% configurable)
- Contract premium

**Logic:**

- Calculate dollar amount available for the trade
- Divide by premium per contract (premium × 100 shares)
- Round down to whole contracts
- Ensure minimum of 1 contract if any risk budget available

---

## Configuration Schema

All options-related parameters should be configurable at the strategy/backtest level:

**Instrument Selection**

- Instrument type: options (default) or equity

**Options Contract Selection**

- Expiration preference: weekly (default) or 0DTE
- Strike selection: ATM (default), 1 strike OTM, or 2 strikes OTM

**Position Sizing**

- Risk percentage: 1% to 2% of portfolio per trade

**Simulation Parameters**

- Slippage percentage: 0% to 5% (default 1%)
- Use bar open for entry: yes (default)
- Use bar close for exit: yes (default)

---

## Data Requirements

### Underlying Stock Data (Existing)

- 1-minute bars for all watchlist symbols
- Already implemented in Phase 3 historical data ingestion

### Options Contract Data (New)

**Contract Discovery**

- Use Alpaca's contract search endpoint
- Filter by underlying symbol, expiration range, contract type
- Cache available contracts daily (they don't change intraday)

**Historical Options Bars**

- 1-minute timeframe from Alpaca
- Date range: February 2024 to present
- Store in TimescaleDB alongside equity bars

**Data Volume Considerations**

- Each underlying has dozens of strikes across multiple expirations
- Strategy: Only fetch bars for contracts that would have been traded
- Lazy loading during backtest: fetch contract bars on-demand when a signal triggers

---

## Backtesting Integration

### Event-Driven Flow

The existing event-driven backtesting engine processes bars chronologically. Options integration extends this:

1. Bar event arrives for underlying symbol
2. Strategy evaluates and potentially generates a signal
3. Instrument Resolver checks configuration
4. If options enabled:
   - Contract Selector identifies target contract
   - Price Simulator fetches options bar for same timestamp
   - Position Sizer calculates quantity
5. Trade Simulator records the simulated trade
6. Position Manager tracks open options positions
7. On exit signal or expiration: close position using options bar prices

### Exit Handling

Options positions can exit via:

- **Signal-based exit**: Trailing stop or target hit on underlying triggers options position close
- **Time-based exit**: Configurable max hold time (e.g., close by 10:30 AM)
- **Expiration**: If holding through expiration, simulate exercise or expiry based on moneyness

### Performance Metrics

Extend existing metrics to capture options-specific data:

- Premium paid vs premium received
- Average hold time
- Win rate by expiration type (weekly vs 0DTE)
- Performance by strike distance (1 OTM vs 2 OTM)

---

## Project Tasks

### Phase A: Foundation & Data Layer

**Goal:** Establish options data infrastructure

**Tasks:**

1. Design and create TimescaleDB schema for options contracts and bars
2. Implement Alpaca Options Contracts API client (discovery endpoint)
3. Implement Alpaca Options Bars API client (historical data)
4. Build contract symbol parser/generator (OSI format)
5. Create daily contract sync job for watchlist symbols

**Done when:**

- Options contracts table populated for watchlist
- Ability to fetch and store options bars on demand

---

### Phase B: Instruments Abstraction

**Goal:** Build the instrument layer that separates equity from options

**Tasks:**

1. Design Instruments context structure
2. Implement Equity instrument (wrapper for existing behavior)
3. Implement Options instrument representation
4. Build Instrument Resolver with configuration-based routing
5. Create configuration schema and validation

**Done when:**

- Instrument abstraction complete
- Existing equity flow working through new layer (no regression)

---

### Phase C: Contract Selection & Price Simulation

**Goal:** Implement options-specific logic

**Tasks:**

1. Build Contract Selector with expiration logic (weekly/0DTE)
2. Implement strike selection (ATM, 1 OTM, 2 OTM)
3. Create Price Simulator using options bars
4. Add slippage configuration and application
5. Implement Position Sizer for options (contract quantity calculation)

**Done when:**

- Given a signal, system can select appropriate contract
- Can simulate entry/exit prices from historical data

---

### Phase D: Backtesting Integration

**Goal:** Connect options to the event-driven backtesting engine

**Tasks:**

1. Extend backtest engine to support instrument abstraction
2. Implement options position tracking (separate from equity)
3. Handle options-specific exit conditions (expiration, time-based)
4. Add lazy loading of options bars during backtest
5. Update trade log to capture options-specific fields

**Done when:**

- Can run a complete backtest with options execution
- Trade log shows contract details, premiums, P&L

---

### Phase E: Performance Analytics & Reporting

**Goal:** Measure and compare options vs equity performance

**Tasks:**

1. Extend performance metrics for options trades
2. Build comparison reports (options vs equity on same signals)
3. Add breakdown by configuration (weekly vs 0DTE, strike distance)
4. Create visualization for options backtest results
5. Document metrics and interpretation

**Done when:**

- Comprehensive performance report for options backtests
- Side-by-side comparison capability

---

### Phase F: Optimization & Polish

**Goal:** Enable parameter optimization and finalize

**Tasks:**

1. Integrate options parameters into optimization framework
2. Run optimization sweeps across configurations
3. Identify optimal settings for each strategy/symbol combination
4. Performance testing and optimization of data fetching
5. Documentation and code cleanup

**Done when:**

- Optimization results for options parameters
- Production-ready options backtesting capability
- Complete documentation

---

## Symbols & Expirations

### Watchlist Symbols

All current watchlist symbols support options trading:

- **Tech:** TSLA, GOOG, NVDA, AAPL, MSFT, META, AMZN
- **ETFs:** SPY, QQQ

### Expiration Availability

| Symbol | 0DTE Available | Weekly Available |
|--------|----------------|------------------|
| SPY    | Mon, Wed, Fri  | Yes              |
| QQQ    | Mon, Wed, Fri  | Yes              |
| TSLA   | No (typically) | Yes              |
| AAPL   | No (typically) | Yes              |
| Others | No (typically) | Yes              |

**Note:** 0DTE availability varies and should be validated via contract discovery API. The system should gracefully fall back to weekly if 0DTE is unavailable for a given symbol/date.

---

## Risk Considerations

### Technical Risks

1. **Limited Historical Data**: Alpaca options data only goes back to February 2024, limiting backtest depth
   - Mitigation: Focus optimization on available data period; document limitations

2. **No Greeks Data in Bars**: Historical bars don't include delta/gamma/theta
   - Mitigation: Use price-based analysis only; consider adding Greeks for live trading later

3. **Liquidity Uncertainty**: Bar data doesn't show bid/ask spreads or volume
   - Mitigation: Conservative slippage assumptions; focus on liquid underlyings (SPY, QQQ, TSLA)

4. **Data Volume**: Options have many more contracts than equities
   - Mitigation: Lazy loading; only fetch contracts that would be traded

### Trading Risks

1. **Premium Decay**: Options lose value over time (theta)
   - Mitigation: Quick trades align with existing "work in 5 minutes" philosophy

2. **Volatility Impact**: IV changes affect premium independent of direction
   - Mitigation: Document as limitation; consider IV filters in future

3. **Expiration Risk**: 0DTE options can go to zero quickly
   - Mitigation: Start with weeklies; strict time-based exits

---

## Success Criteria

The project will be considered successful when:

1. **Functional:** Can run backtests using options execution on all watchlist symbols
2. **Configurable:** Can easily switch between equity and options via configuration
3. **Comparable:** Can run the same signals through both execution types and compare results
4. **Optimizable:** Options parameters are integrated into optimization framework
5. **Documented:** Clear documentation of limitations, assumptions, and usage

---

## Future Enhancements (Out of Scope)

The following are explicitly deferred to keep this phase focused:

- Live trading integration with Alpaca Options API
- Greeks-based contract selection (delta targeting)
- Spread strategies (verticals, iron condors, etc.)
- Implied volatility filtering
- Dynamic expiration selection based on market conditions
- Multi-leg options strategies

---

## Dependencies

### External

- Alpaca Options Trading API (paper account enabled)
- Alpaca Options Market Data API (historical bars)

### Internal

- Phase 3 backtesting engine (in progress)
- Historical equity data ingestion (in progress)
- TimescaleDB infrastructure (complete)
- Existing strategy and signal modules (complete)

---

## Appendix: Alpaca Options API Reference

### Contract Discovery

- Endpoint for searching available contracts
- Filter by: underlying symbols, expiration date, type (call/put), strike range

### Historical Data

- OHLC bar data endpoint
- Timeframes: 1Min, 5Min, 15Min, 1Hour, 1Day
- Available from: February 2024

### Contract Symbol Format (OSI)

- Format: Underlying + Date (YYMMDD) + Type (C/P) + Strike (padded to 8 digits)
- Example: AAPL251017C00150000 = AAPL October 17, 2025 $150 Call

---

*Document Version: 1.0*  
*Created: November 2025*