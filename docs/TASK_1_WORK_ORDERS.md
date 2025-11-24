# Phase 2 Task 1: Detailed Work Orders

## Overview

This document contains detailed, step-by-step work orders for implementing the three core technical analysis modules in Phase 2 Task 1.

**Modules Covered:**
1. `Signal.Technicals.Levels` - Daily Reference Levels
2. `Signal.Technicals.Swings` - Swing Detection
3. `Signal.Technicals.StructureDetector` - BOS/ChoCh Detection

**Estimated Total Time:** ~8-10 hours

---

# Work Order #1: Signal.Technicals.Levels Module

**File:** `lib/signal/technicals/levels.ex`
**Purpose:** Calculate and track daily reference levels (PDH/PDL, PMH/PML, OR)
**Dependencies:** Signal.Repo, Signal.MarketData.Bar, Phoenix.PubSub
**Estimated Time:** 2-3 hours

---

## Module Structure

```elixir
defmodule Signal.Technicals.Levels do
  @moduledoc """
  Calculates and manages daily reference levels for trading strategies.

  ## Key Levels Tracked:
  - Previous Day High/Low (PDH/PDL)
  - Premarket High/Low (PMH/PML)
  - Opening Range High/Low - 5 minute (OR5H/OR5L)
  - Opening Range High/Low - 15 minute (OR15H/OR15L)
  - Psychological levels (whole and half numbers)

  ## Usage:

      # Calculate all daily levels for a symbol
      {:ok, levels} = Levels.calculate_daily_levels(:AAPL, ~D[2024-11-23])

      # Get current levels for trading
      {:ok, levels} = Levels.get_current_levels(:AAPL)

      # Check if a level was broken
      broken? = Levels.level_broken?(175.50, 175.60, 175.45)
  """

  # Public API - 6 functions
  # Private helpers - 10 functions
end
```

---

## Public API Functions

### Function 1: `calculate_daily_levels/2`

**Signature:**
```elixir
@spec calculate_daily_levels(atom(), Date.t()) ::
  {:ok, %Signal.Technicals.KeyLevels{}} | {:error, atom()}
```

**Purpose:** Calculate all daily reference levels for a symbol on a specific date

**Algorithm:**
1. Query previous day's bars (date - 1, all bars)
2. Extract PDH = max(high), PDL = min(low)
3. Query premarket bars (4:00 AM - 9:30 AM ET on date)
4. Extract PMH = max(high), PML = min(low)
5. Opening ranges calculated separately (see update_opening_range/2)
6. Create KeyLevels struct
7. Store in database
8. Broadcast to PubSub
9. Return {:ok, levels}

**Error Handling:**
- No previous day data → `{:error, :no_previous_day_data}`
- Weekend/holiday → `{:error, :not_a_trading_day}`
- Database error → `{:error, :database_error}`

**Implementation Steps:**

```elixir
def calculate_daily_levels(symbol, date) do
  with {:ok, :trading_day} <- validate_trading_day(date),
       {:ok, prev_bars} <- get_previous_day_bars(symbol, date),
       {:ok, pm_bars} <- get_premarket_bars(symbol, date) do

    {pdh, pdl} = calculate_high_low(prev_bars)
    {pmh, pml} = calculate_high_low(pm_bars)

    levels = %Signal.Technicals.KeyLevels{
      symbol: to_string(symbol),
      date: date,
      previous_day_high: pdh,
      previous_day_low: pdl,
      premarket_high: pmh,
      premarket_low: pml
      # OR fields remain nil until 9:35/9:45
    }

    with {:ok, stored} <- store_levels(levels),
         :ok <- broadcast_levels_update(symbol, stored) do
      {:ok, stored}
    end
  end
end
```

**Test Cases:**
1. Calculate levels with valid previous day data
2. Handle missing previous day data
3. Handle weekends (no trading)
4. Handle missing premarket data (use nil)
5. Verify database storage
6. Verify PubSub broadcast

---

### Function 2: `get_current_levels/1`

**Signature:**
```elixir
@spec get_current_levels(atom()) ::
  {:ok, %Signal.Technicals.KeyLevels{}} | {:error, :not_found}
```

**Purpose:** Retrieve today's calculated levels for a symbol

**Algorithm:**
1. Get today's date in ET timezone
2. Query database for levels where symbol = X and date = today
3. If found, return {:ok, levels}
4. If not found, return {:error, :not_found}

**Implementation:**

```elixir
def get_current_levels(symbol) do
  today = get_current_trading_date()

  query = from l in Signal.Technicals.KeyLevels,
    where: l.symbol == ^to_string(symbol) and l.date == ^today

  case Signal.Repo.one(query) do
    nil -> {:error, :not_found}
    levels -> {:ok, levels}
  end
end
```

**Test Cases:**
1. Get levels that exist
2. Handle missing levels (returns error)
3. Verify correct date used (ET timezone)

---

### Function 3: `update_opening_range/3`

**Signature:**
```elixir
@spec update_opening_range(atom(), Date.t(), :five_min | :fifteen_min) ::
  {:ok, %Signal.Technicals.KeyLevels{}} | {:error, atom()}
```

**Purpose:** Calculate and update opening range after market opens

**Algorithm:**
1. Query bars for opening range period
   - 5min: 9:30:00 - 9:34:59 (5 bars)
   - 15min: 9:30:00 - 9:44:59 (15 bars)
2. Calculate high/low from those bars
3. Update existing KeyLevels record
4. Broadcast update
5. Return updated levels

**Implementation:**

```elixir
def update_opening_range(symbol, date, range_type) do
  minutes = case range_type do
    :five_min -> 5
    :fifteen_min -> 15
  end

  with {:ok, or_bars} <- get_opening_range_bars(symbol, date, minutes),
       {high, low} <- calculate_high_low(or_bars),
       {:ok, levels} <- get_levels_for_date(symbol, date) do

    updated = case range_type do
      :five_min ->
        %{levels | opening_range_5m_high: high, opening_range_5m_low: low}
      :fifteen_min ->
        %{levels | opening_range_15m_high: high, opening_range_15m_low: low}
    end

    with {:ok, stored} <- update_levels(updated),
         :ok <- broadcast_levels_update(symbol, stored) do
      {:ok, stored}
    end
  end
end
```

**Test Cases:**
1. Update 5-minute OR at 9:35 AM
2. Update 15-minute OR at 9:45 AM
3. Handle missing bars (early morning)
4. Verify broadcast sent

---

### Function 4: `level_broken?/3`

**Signature:**
```elixir
@spec level_broken?(Decimal.t(), Decimal.t(), Decimal.t()) :: boolean()
```

**Purpose:** Determine if price broke through a level

**Algorithm:**
- Bullish break: previous_price ≤ level AND current_price > level
- Bearish break: previous_price ≥ level AND current_price < level

**Implementation:**

```elixir
def level_broken?(level, current_price, previous_price) do
  bullish_break = Decimal.compare(previous_price, level) != :gt and
                  Decimal.compare(current_price, level) == :gt

  bearish_break = Decimal.compare(previous_price, level) != :lt and
                  Decimal.compare(current_price, level) == :lt

  bullish_break or bearish_break
end
```

**Test Cases:**
1. Bullish break (below → above)
2. Bearish break (above → below)
3. No break (stays on same side)
4. Price exactly on level (edge case)

---

### Function 5: `find_nearest_psychological/1`

**Signature:**
```elixir
@spec find_nearest_psychological(Decimal.t()) ::
  %{whole: Decimal.t(), half: Decimal.t(), quarter: Decimal.t()}
```

**Purpose:** Find nearest psychological price levels (whole, half, quarter numbers)

**Algorithm:**
1. Whole: Round to nearest integer (175.00, 176.00)
2. Half: Round to nearest 0.50 (175.50, 176.00)
3. Quarter: Round to nearest 0.25 (175.25, 175.50)

**Implementation:**

```elixir
def find_nearest_psychological(price) do
  # Whole number
  whole_down = Decimal.round(price, 0, :down)
  whole_up = Decimal.add(whole_down, Decimal.new(1))

  whole = if Decimal.compare(Decimal.sub(price, whole_down),
                             Decimal.sub(whole_up, price)) == :lt do
    whole_down
  else
    whole_up
  end

  # Half number
  half_down = Decimal.mult(Decimal.round(Decimal.div(price, Decimal.new("0.5")), 0, :down),
                           Decimal.new("0.5"))
  half_up = Decimal.add(half_down, Decimal.new("0.5"))

  half = if Decimal.compare(Decimal.sub(price, half_down),
                            Decimal.sub(half_up, price)) == :lt do
    half_down
  else
    half_up
  end

  # Quarter number
  quarter_down = Decimal.mult(Decimal.round(Decimal.div(price, Decimal.new("0.25")), 0, :down),
                              Decimal.new("0.25"))
  quarter_up = Decimal.add(quarter_down, Decimal.new("0.25"))

  quarter = if Decimal.compare(Decimal.sub(price, quarter_down),
                               Decimal.sub(quarter_up, price)) == :lt do
    quarter_down
  else
    quarter_up
  end

  %{whole: whole, half: half, quarter: quarter}
end
```

**Test Cases:**
1. Price = 175.23 → whole: 175, half: 175.50, quarter: 175.25
2. Price = 175.50 → whole: 176, half: 175.50, quarter: 175.50
3. Price = 175.99 → whole: 176, half: 176.00, quarter: 176.00

---

### Function 6: `get_level_status/2`

**Signature:**
```elixir
@spec get_level_status(atom(), Decimal.t()) ::
  {:above | :below | :at, atom(), Decimal.t()}
```

**Purpose:** Determine which key level price is relative to

**Algorithm:**
1. Get current levels for symbol
2. Compare current_price to all levels
3. Find closest level and relationship

**Implementation:**

```elixir
def get_level_status(symbol, current_price) do
  with {:ok, levels} <- get_current_levels(symbol) do
    all_levels = [
      {:pdh, levels.previous_day_high},
      {:pdl, levels.previous_day_low},
      {:pmh, levels.premarket_high},
      {:pml, levels.premarket_low},
      {:or5h, levels.opening_range_5m_high},
      {:or5l, levels.opening_range_5m_low},
      {:or15h, levels.opening_range_15m_high},
      {:or15l, levels.opening_range_15m_low}
    ]
    |> Enum.reject(fn {_name, value} -> is_nil(value) end)

    # Find closest level
    {level_name, level_value} = Enum.min_by(all_levels, fn {_name, value} ->
      Decimal.abs(Decimal.sub(current_price, value))
    end)

    position = cond do
      Decimal.compare(current_price, level_value) == :gt -> :above
      Decimal.compare(current_price, level_value) == :lt -> :below
      true -> :at
    end

    {position, level_name, level_value}
  end
end
```

**Test Cases:**
1. Price above PDH
2. Price below PDL
3. Price between PMH and PMH
4. Handle nil opening ranges

---

## Private Helper Functions

### Helper 1: `get_previous_day_bars/2`

**Purpose:** Fetch all bars from previous trading day

**Implementation:**

```elixir
defp get_previous_day_bars(symbol, date) do
  prev_date = get_previous_trading_day(date)

  query = from b in Signal.MarketData.Bar,
    where: b.symbol == ^to_string(symbol),
    where: fragment("?::date = ?", b.bar_time, ^prev_date),
    order_by: [asc: b.bar_time]

  bars = Signal.Repo.all(query)

  if Enum.empty?(bars) do
    {:error, :no_previous_day_data}
  else
    {:ok, bars}
  end
end
```

---

### Helper 2: `get_premarket_bars/2`

**Purpose:** Fetch bars from 4:00 AM - 9:30 AM ET

**Implementation:**

```elixir
defp get_premarket_bars(symbol, date) do
  timezone = Application.get_env(:signal, :timezone, "America/New_York")

  premarket_start = DateTime.new!(date, ~T[04:00:00], timezone)
  premarket_end = DateTime.new!(date, ~T[09:30:00], timezone)

  query = from b in Signal.MarketData.Bar,
    where: b.symbol == ^to_string(symbol),
    where: b.bar_time >= ^premarket_start,
    where: b.bar_time < ^premarket_end,
    order_by: [asc: b.bar_time]

  bars = Signal.Repo.all(query)

  # Premarket data is optional
  {:ok, bars}
end
```

---

### Helper 3: `get_opening_range_bars/3`

**Purpose:** Fetch bars for opening range calculation

**Implementation:**

```elixir
defp get_opening_range_bars(symbol, date, minutes) do
  timezone = Application.get_env(:signal, :timezone, "America/New_York")

  range_start = DateTime.new!(date, ~T[09:30:00], timezone)
  range_end = DateTime.add(range_start, minutes * 60, :second)

  query = from b in Signal.MarketData.Bar,
    where: b.symbol == ^to_string(symbol),
    where: b.bar_time >= ^range_start,
    where: b.bar_time < ^range_end,
    order_by: [asc: b.bar_time]

  bars = Signal.Repo.all(query)

  if length(bars) < minutes do
    {:error, :insufficient_bars}
  else
    {:ok, bars}
  end
end
```

---

### Helper 4: `calculate_high_low/1`

**Purpose:** Extract high/low from list of bars

**Implementation:**

```elixir
defp calculate_high_low(bars) when is_list(bars) and length(bars) > 0 do
  high = Enum.max_by(bars, & &1.high).high
  low = Enum.min_by(bars, & &1.low).low
  {high, low}
end

defp calculate_high_low([]), do: {nil, nil}
```

---

### Helper 5: `store_levels/1`

**Purpose:** Insert or update levels in database

**Implementation:**

```elixir
defp store_levels(%Signal.Technicals.KeyLevels{} = levels) do
  Signal.Repo.insert(
    levels,
    on_conflict: {:replace_all_except, [:symbol, :date]},
    conflict_target: [:symbol, :date]
  )
end
```

---

### Helper 6: `update_levels/1`

**Purpose:** Update existing levels record

**Implementation:**

```elixir
defp update_levels(%Signal.Technicals.KeyLevels{} = levels) do
  Signal.Repo.update(Signal.Technicals.KeyLevels.changeset(levels, %{}))
end
```

---

### Helper 7: `broadcast_levels_update/2`

**Purpose:** Broadcast level changes via PubSub

**Implementation:**

```elixir
defp broadcast_levels_update(symbol, levels) do
  Phoenix.PubSub.broadcast(
    Signal.PubSub,
    "levels:#{symbol}",
    {:levels_updated, symbol, levels}
  )
end
```

---

### Helper 8: `get_current_trading_date/0`

**Purpose:** Get today's date in ET timezone

**Implementation:**

```elixir
defp get_current_trading_date do
  timezone = Application.get_env(:signal, :timezone, "America/New_York")
  DateTime.now!(timezone) |> DateTime.to_date()
end
```

---

### Helper 9: `get_previous_trading_day/1`

**Purpose:** Get previous trading day (skip weekends)

**Implementation:**

```elixir
defp get_previous_trading_day(date) do
  case Date.day_of_week(date) do
    1 -> Date.add(date, -3)  # Monday → Friday
    _ -> Date.add(date, -1)  # Other days → previous day
  end
end
```

---

### Helper 10: `validate_trading_day/1`

**Purpose:** Check if date is a trading day (not weekend)

**Implementation:**

```elixir
defp validate_trading_day(date) do
  case Date.day_of_week(date) do
    day when day in [6, 7] -> {:error, :not_a_trading_day}
    _ -> {:ok, :trading_day}
  end
end
```

---

## Module Dependencies

**Imports:**
```elixir
import Ecto.Query
alias Signal.Repo
alias Signal.MarketData.Bar
alias Signal.Technicals.KeyLevels
```

**Application Config Required:**
```elixir
# config/dev.exs
config :signal,
  timezone: "America/New_York",
  market_open: ~T[09:30:00],
  market_close: ~T[16:00:00]
```

---

## Testing Checklist

### Unit Tests (`test/signal/technicals/levels_test.exs`)

- [ ] `calculate_daily_levels/2` with valid data
- [ ] `calculate_daily_levels/2` with missing previous day
- [ ] `calculate_daily_levels/2` on weekend
- [ ] `get_current_levels/1` returns stored levels
- [ ] `get_current_levels/1` returns error when not found
- [ ] `update_opening_range/3` for 5-minute range
- [ ] `update_opening_range/3` for 15-minute range
- [ ] `level_broken?/3` detects bullish break
- [ ] `level_broken?/3` detects bearish break
- [ ] `level_broken?/3` returns false when no break
- [ ] `find_nearest_psychological/1` rounds correctly
- [ ] `get_level_status/2` identifies position relative to levels

### Integration Tests

- [ ] Database insert/update works correctly
- [ ] PubSub broadcasts received by subscribers
- [ ] Timezone handling correct for ET market hours

---

## Implementation Time Estimate

| Task | Time |
|------|------|
| Module setup and structure | 15 min |
| Public API (6 functions) | 60 min |
| Private helpers (10 functions) | 45 min |
| Error handling and edge cases | 20 min |
| Documentation (@doc, @moduledoc) | 20 min |
| Unit tests (12 tests) | 40 min |
| Integration tests (3 tests) | 20 min |
| **Total** | **3h 20min** |

---

# Work Order #2: Signal.Technicals.Swings Module

**File:** `lib/signal/technicals/swings.ex`
**Purpose:** Detect swing highs and swing lows in price data
**Dependencies:** Signal.MarketData.Bar
**Estimated Time:** 1.5-2 hours

---

## Module Structure

```elixir
defmodule Signal.Technicals.Swings do
  @moduledoc """
  Detects swing highs and swing lows in bar data.

  A swing high is a bar whose high is higher than N bars before and after it.
  A swing low is a bar whose low is lower than N bars before and after it.

  ## Algorithm:

  Default lookback period is 2 bars (configurable).

  ## Usage:

      # Identify all swings in a bar series
      swings = Swings.identify_swings(bars)
      # => [
      #   %{type: :high, index: 5, price: 175.50, bar_time: ~U[...]},
      #   %{type: :low, index: 12, price: 174.20, bar_time: ~U[...]},
      #   ...
      # ]

      # Check if specific bar is a swing
      is_swing? = Swings.swing_high?(bars, 10, lookback: 2)
  """

  # Public API - 4 functions
  # Private helpers - 3 functions
end
```

---

## Public API Functions

### Function 1: `identify_swings/2`

**Signature:**
```elixir
@spec identify_swings(list(%Signal.MarketData.Bar{}), keyword()) ::
  list(%{type: :high | :low, index: integer(), price: Decimal.t(), bar_time: DateTime.t()})
```

**Purpose:** Find all swing highs and lows in a bar series

**Options:**
- `:lookback` - Number of bars before/after to compare (default: 2)
- `:min_bars` - Minimum bars required to detect swings (default: 5)

**Algorithm:**
1. Validate minimum bars (need at least lookback*2 + 1)
2. Iterate through bars from index `lookback` to `length - lookback - 1`
3. For each bar, check if it's a swing high or swing low
4. Collect all detected swings with metadata

**Implementation:**

```elixir
def identify_swings(bars, opts \\ []) when is_list(bars) do
  lookback = Keyword.get(opts, :lookback, 2)
  min_bars = Keyword.get(opts, :min_bars, lookback * 2 + 1)

  if length(bars) < min_bars do
    []
  else
    # Start from lookback index, end at length - lookback - 1
    start_idx = lookback
    end_idx = length(bars) - lookback - 1

    start_idx..end_idx
    |> Enum.reduce([], fn idx, acc ->
      bar = Enum.at(bars, idx)

      cond do
        swing_high?(bars, idx, lookback) ->
          [%{
            type: :high,
            index: idx,
            price: bar.high,
            bar_time: bar.bar_time,
            bar: bar
          } | acc]

        swing_low?(bars, idx, lookback) ->
          [%{
            type: :low,
            index: idx,
            price: bar.low,
            bar_time: bar.bar_time,
            bar: bar
          } | acc]

        true ->
          acc
      end
    end)
    |> Enum.reverse()
  end
end
```

**Test Cases:**
1. Identify swings with default lookback (2)
2. Identify swings with custom lookback (3)
3. Return empty list when insufficient bars
4. Correctly identify both highs and lows
5. Handle bars list with no swings

---

### Function 2: `swing_high?/3`

**Signature:**
```elixir
@spec swing_high?(list(%Signal.MarketData.Bar{}), integer(), integer()) :: boolean()
```

**Purpose:** Determine if bar at index is a swing high

**Algorithm:**
1. Get current bar's high
2. Get N bars before (where N = lookback)
3. Get N bars after
4. Return true if current high > all before highs AND current high > all after highs

**Implementation:**

```elixir
def swing_high?(bars, index, lookback \\ 2) do
  if index < lookback or index >= length(bars) - lookback do
    false
  else
    current_bar = Enum.at(bars, index)
    current_high = current_bar.high

    before_bars = Enum.slice(bars, index - lookback, lookback)
    after_bars = Enum.slice(bars, index + 1, lookback)

    all_before_lower = Enum.all?(before_bars, fn bar ->
      Decimal.compare(current_high, bar.high) == :gt
    end)

    all_after_lower = Enum.all?(after_bars, fn bar ->
      Decimal.compare(current_high, bar.high) == :gt
    end)

    all_before_lower and all_after_lower
  end
end
```

**Test Cases:**
1. Valid swing high with lookback 2
2. Valid swing high with lookback 3
3. Not a swing high (one bar after is higher)
4. Not a swing high (one bar before is higher)
5. Index out of bounds (too early)
6. Index out of bounds (too late)

---

### Function 3: `swing_low?/3`

**Signature:**
```elixir
@spec swing_low?(list(%Signal.MarketData.Bar{}), integer(), integer()) :: boolean()
```

**Purpose:** Determine if bar at index is a swing low

**Algorithm:**
1. Get current bar's low
2. Get N bars before (where N = lookback)
3. Get N bars after
4. Return true if current low < all before lows AND current low < all after lows

**Implementation:**

```elixir
def swing_low?(bars, index, lookback \\ 2) do
  if index < lookback or index >= length(bars) - lookback do
    false
  else
    current_bar = Enum.at(bars, index)
    current_low = current_bar.low

    before_bars = Enum.slice(bars, index - lookback, lookback)
    after_bars = Enum.slice(bars, index + 1, lookback)

    all_before_higher = Enum.all?(before_bars, fn bar ->
      Decimal.compare(current_low, bar.low) == :lt
    end)

    all_after_higher = Enum.all?(after_bars, fn bar ->
      Decimal.compare(current_low, bar.low) == :lt
    end)

    all_before_higher and all_after_higher
  end
end
```

**Test Cases:**
1. Valid swing low with lookback 2
2. Valid swing low with lookback 3
3. Not a swing low (one bar after is lower)
4. Not a swing low (one bar before is lower)
5. Index out of bounds (too early)
6. Index out of bounds (too late)

---

### Function 4: `get_latest_swing/2`

**Signature:**
```elixir
@spec get_latest_swing(list(%Signal.MarketData.Bar{}), :high | :low) ::
  %{type: :high | :low, index: integer(), price: Decimal.t()} | nil
```

**Purpose:** Get the most recent swing high or swing low

**Algorithm:**
1. Call identify_swings/1
2. Filter by type (:high or :low)
3. Return last element (most recent)

**Implementation:**

```elixir
def get_latest_swing(bars, type) when type in [:high, :low] do
  bars
  |> identify_swings()
  |> Enum.filter(&(&1.type == type))
  |> List.last()
end
```

**Test Cases:**
1. Get latest swing high
2. Get latest swing low
3. Return nil when no swings of that type exist

---

## Private Helper Functions

### Helper 1: `validate_index_bounds/3`

**Purpose:** Check if index is valid for swing detection

**Implementation:**

```elixir
defp validate_index_bounds(index, list_length, lookback) do
  index >= lookback and index < list_length - lookback
end
```

---

### Helper 2: `compare_all_greater/2`

**Purpose:** Check if target value is greater than all values in list

**Implementation:**

```elixir
defp compare_all_greater(target, values) do
  Enum.all?(values, fn value ->
    Decimal.compare(target, value) == :gt
  end)
end
```

---

### Helper 3: `compare_all_less/2`

**Purpose:** Check if target value is less than all values in list

**Implementation:**

```elixir
defp compare_all_less(target, values) do
  Enum.all?(values, fn value ->
    Decimal.compare(target, value) == :lt
  end)
end
```

---

## Module Dependencies

**Imports:**
```elixir
alias Signal.MarketData.Bar
```

---

## Testing Checklist

### Unit Tests (`test/signal/technicals/swings_test.exs`)

- [ ] `identify_swings/1` finds all swings with default lookback
- [ ] `identify_swings/2` with custom lookback
- [ ] `identify_swings/1` returns empty for insufficient bars
- [ ] `swing_high?/3` detects valid swing high
- [ ] `swing_high?/3` rejects invalid swing high (bar after is higher)
- [ ] `swing_high?/3` handles index out of bounds
- [ ] `swing_low?/3` detects valid swing low
- [ ] `swing_low?/3` rejects invalid swing low (bar after is lower)
- [ ] `swing_low?/3` handles index out of bounds
- [ ] `get_latest_swing/2` returns most recent swing high
- [ ] `get_latest_swing/2` returns most recent swing low
- [ ] `get_latest_swing/2` returns nil when no swings

### Edge Case Tests

- [ ] Single bar (no swings possible)
- [ ] All bars with same high (no swing highs)
- [ ] All bars with same low (no swing lows)
- [ ] Consecutive swing highs
- [ ] Consecutive swing lows

---

## Implementation Time Estimate

| Task | Time |
|------|------|
| Module setup and structure | 10 min |
| Public API (4 functions) | 40 min |
| Private helpers (3 functions) | 15 min |
| Edge case handling | 15 min |
| Documentation | 15 min |
| Unit tests (12 tests) | 35 min |
| Edge case tests (5 tests) | 15 min |
| **Total** | **2h 25min** |

---

# Work Order #3: Signal.Technicals.StructureDetector Module

**File:** `lib/signal/technicals/structure_detector.ex`
**Purpose:** Detect Break of Structure (BOS) and Change of Character (ChoCh)
**Dependencies:** Signal.Technicals.Swings, Signal.MarketData.Bar
**Estimated Time:** 2-3 hours

---

## Module Structure

```elixir
defmodule Signal.Technicals.StructureDetector do
  @moduledoc """
  Detects market structure patterns: Break of Structure (BOS) and Change of Character (ChoCh).

  ## Concepts:

  **Break of Structure (BOS):**
  - Bullish BOS: Price breaks above previous swing high (trend continuation)
  - Bearish BOS: Price breaks below previous swing low (trend continuation)

  **Change of Character (ChoCh):**
  - Bullish ChoCh: In downtrend, price breaks above previous swing high (reversal)
  - Bearish ChoCh: In uptrend, price breaks below previous swing low (reversal)

  **Trend Determination:**
  - Bullish: Higher highs and higher lows
  - Bearish: Lower highs and lower lows
  - Ranging: No clear pattern

  ## Usage:

      # Analyze market structure
      structure = StructureDetector.analyze(bars)
      # => %{
      #   trend: :bullish,
      #   latest_bos: %{type: :bullish, price: 175.50, bar_time: ~U[...]},
      #   latest_choch: nil,
      #   swing_highs: [...],
      #   swing_lows: [...]
      # }
  """

  # Public API - 5 functions
  # Private helpers - 8 functions
end
```

---

## Public API Functions

### Function 1: `analyze/2`

**Signature:**
```elixir
@spec analyze(list(%Signal.MarketData.Bar{}), keyword()) :: %{
  trend: :bullish | :bearish | :ranging,
  latest_bos: map() | nil,
  latest_choch: map() | nil,
  swing_highs: list(map()),
  swing_lows: list(map())
}
```

**Purpose:** Comprehensive market structure analysis

**Options:**
- `:lookback` - Swing detection lookback (default: 2)
- `:min_swings` - Minimum swings needed for trend (default: 3)

**Algorithm:**
1. Identify all swings using Swings module
2. Separate into swing highs and swing lows
3. Determine trend from swing pattern
4. Detect most recent BOS
5. Detect most recent ChoCh
6. Return comprehensive structure map

**Implementation:**

```elixir
def analyze(bars, opts \\ []) when is_list(bars) do
  lookback = Keyword.get(opts, :lookback, 2)

  # Identify swings
  all_swings = Signal.Technicals.Swings.identify_swings(bars, lookback: lookback)

  swing_highs = Enum.filter(all_swings, &(&1.type == :high))
  swing_lows = Enum.filter(all_swings, &(&1.type == :low))

  # Determine trend
  trend = determine_trend(swing_highs, swing_lows)

  # Detect BOS and ChoCh
  latest_bos = detect_latest_bos(bars, swing_highs, swing_lows, trend)
  latest_choch = detect_latest_choch(bars, swing_highs, swing_lows, trend)

  %{
    trend: trend,
    latest_bos: latest_bos,
    latest_choch: latest_choch,
    swing_highs: swing_highs,
    swing_lows: swing_lows
  }
end
```

**Test Cases:**
1. Analyze bullish trend with BOS
2. Analyze bearish trend with BOS
3. Analyze ranging market
4. Detect ChoCh on trend reversal
5. Handle insufficient data

---

### Function 2: `detect_bos/3`

**Signature:**
```elixir
@spec detect_bos(list(%Signal.MarketData.Bar{}), list(map()), atom()) ::
  %{type: :bullish | :bearish, price: Decimal.t(), bar_time: DateTime.t(), index: integer()} | nil
```

**Purpose:** Detect Break of Structure in bar series

**Arguments:**
- `bars` - List of bars to analyze
- `swings` - Previously identified swings
- `trend` - Current trend direction

**Algorithm:**
1. Get latest bar
2. Find previous swing high/low based on trend
3. Check if price broke beyond swing level
4. Return BOS details or nil

**Implementation:**

```elixir
def detect_bos(bars, swings, trend) when trend in [:bullish, :bearish] do
  if Enum.empty?(bars) or Enum.empty?(swings) do
    nil
  else
    latest_bar = List.last(bars)

    case trend do
      :bullish ->
        # Look for break above previous swing high
        swing_highs = Enum.filter(swings, &(&1.type == :high))

        if Enum.empty?(swing_highs) do
          nil
        else
          prev_swing = List.last(swing_highs)

          if Decimal.compare(latest_bar.close, prev_swing.price) == :gt do
            %{
              type: :bullish,
              price: latest_bar.close,
              bar_time: latest_bar.bar_time,
              index: length(bars) - 1,
              broken_swing: prev_swing
            }
          else
            nil
          end
        end

      :bearish ->
        # Look for break below previous swing low
        swing_lows = Enum.filter(swings, &(&1.type == :low))

        if Enum.empty?(swing_lows) do
          nil
        else
          prev_swing = List.last(swing_lows)

          if Decimal.compare(latest_bar.close, prev_swing.price) == :lt do
            %{
              type: :bearish,
              price: latest_bar.close,
              bar_time: latest_bar.bar_time,
              index: length(bars) - 1,
              broken_swing: prev_swing
            }
          else
            nil
          end
        end
    end
  end
end

def detect_bos(_bars, _swings, :ranging), do: nil
```

**Test Cases:**
1. Detect bullish BOS (break above swing high)
2. Detect bearish BOS (break below swing low)
3. No BOS when price doesn't break swing
4. Return nil for ranging trend
5. Handle empty swings list

---

### Function 3: `detect_choch/3`

**Signature:**
```elixir
@spec detect_choch(list(%Signal.MarketData.Bar{}), list(map()), atom()) ::
  %{type: :bullish | :bearish, price: Decimal.t(), bar_time: DateTime.t()} | nil
```

**Purpose:** Detect Change of Character (trend reversal)

**Algorithm:**
1. In bullish trend, look for break below swing low → bearish ChoCh
2. In bearish trend, look for break above swing high → bullish ChoCh
3. ChoCh indicates potential trend reversal

**Implementation:**

```elixir
def detect_choch(bars, swings, trend) when trend in [:bullish, :bearish] do
  if Enum.empty?(bars) or Enum.empty?(swings) do
    nil
  else
    latest_bar = List.last(bars)

    case trend do
      :bullish ->
        # In uptrend, ChoCh = break below swing low (bearish reversal)
        swing_lows = Enum.filter(swings, &(&1.type == :low))

        if Enum.empty?(swing_lows) do
          nil
        else
          prev_swing = List.last(swing_lows)

          if Decimal.compare(latest_bar.close, prev_swing.price) == :lt do
            %{
              type: :bearish,
              price: latest_bar.close,
              bar_time: latest_bar.bar_time,
              index: length(bars) - 1,
              broken_swing: prev_swing
            }
          else
            nil
          end
        end

      :bearish ->
        # In downtrend, ChoCh = break above swing high (bullish reversal)
        swing_highs = Enum.filter(swings, &(&1.type == :high))

        if Enum.empty?(swing_highs) do
          nil
        else
          prev_swing = List.last(swing_highs)

          if Decimal.compare(latest_bar.close, prev_swing.price) == :gt do
            %{
              type: :bullish,
              price: latest_bar.close,
              bar_time: latest_bar.bar_time,
              index: length(bars) - 1,
              broken_swing: prev_swing
            }
          else
            nil
          end
        end
    end
  end
end

def detect_choch(_bars, _swings, :ranging), do: nil
```

**Test Cases:**
1. Detect bullish ChoCh in downtrend
2. Detect bearish ChoCh in uptrend
3. No ChoCh when price stays in range
4. Return nil for ranging market

---

### Function 4: `determine_trend/2`

**Signature:**
```elixir
@spec determine_trend(list(map()), list(map())) :: :bullish | :bearish | :ranging
```

**Purpose:** Determine market trend from swing pattern

**Algorithm:**
1. Check if we have enough swings (need at least 2 highs and 2 lows)
2. Bullish: Higher highs AND higher lows
3. Bearish: Lower highs AND lower lows
4. Ranging: Mixed or insufficient data

**Implementation:**

```elixir
def determine_trend(swing_highs, swing_lows) do
  cond do
    length(swing_highs) < 2 or length(swing_lows) < 2 ->
      :ranging

    higher_highs?(swing_highs) and higher_lows?(swing_lows) ->
      :bullish

    lower_highs?(swing_highs) and lower_lows?(swing_lows) ->
      :bearish

    true ->
      :ranging
  end
end
```

**Test Cases:**
1. Detect bullish trend (HH + HL)
2. Detect bearish trend (LH + LL)
3. Detect ranging (mixed swings)
4. Return ranging when insufficient swings

---

### Function 5: `get_structure_state/1`

**Signature:**
```elixir
@spec get_structure_state(map()) :: :strong_bullish | :weak_bullish | :strong_bearish | :weak_bearish | :ranging
```

**Purpose:** Classify market structure strength

**Algorithm:**
1. Strong bullish: Bullish trend with recent BOS, no ChoCh
2. Weak bullish: Bullish trend with recent ChoCh
3. Strong bearish: Bearish trend with recent BOS, no ChoCh
4. Weak bearish: Bearish trend with recent ChoCh
5. Ranging: No clear trend

**Implementation:**

```elixir
def get_structure_state(%{trend: trend, latest_bos: bos, latest_choch: choch}) do
  case trend do
    :bullish ->
      if bos && !choch, do: :strong_bullish, else: :weak_bullish

    :bearish ->
      if bos && !choch, do: :strong_bearish, else: :weak_bearish

    :ranging ->
      :ranging
  end
end
```

**Test Cases:**
1. Strong bullish state
2. Weak bullish state (has ChoCh)
3. Strong bearish state
4. Weak bearish state (has ChoCh)
5. Ranging state

---

## Private Helper Functions

### Helper 1: `higher_highs?/1`

**Purpose:** Check if swing highs are ascending

**Implementation:**

```elixir
defp higher_highs?(swing_highs) when length(swing_highs) >= 2 do
  swing_highs
  |> Enum.chunk_every(2, 1, :discard)
  |> Enum.all?(fn [prev, curr] ->
    Decimal.compare(curr.price, prev.price) == :gt
  end)
end

defp higher_highs?(_), do: false
```

---

### Helper 2: `higher_lows?/1`

**Purpose:** Check if swing lows are ascending

**Implementation:**

```elixir
defp higher_lows?(swing_lows) when length(swing_lows) >= 2 do
  swing_lows
  |> Enum.chunk_every(2, 1, :discard)
  |> Enum.all?(fn [prev, curr] ->
    Decimal.compare(curr.price, prev.price) == :gt
  end)
end

defp higher_lows?(_), do: false
```

---

### Helper 3: `lower_highs?/1`

**Purpose:** Check if swing highs are descending

**Implementation:**

```elixir
defp lower_highs?(swing_highs) when length(swing_highs) >= 2 do
  swing_highs
  |> Enum.chunk_every(2, 1, :discard)
  |> Enum.all?(fn [prev, curr] ->
    Decimal.compare(curr.price, prev.price) == :lt
  end)
end

defp lower_highs?(_), do: false
```

---

### Helper 4: `lower_lows?/1`

**Purpose:** Check if swing lows are descending

**Implementation:**

```elixir
defp lower_lows?(swing_lows) when length(swing_lows) >= 2 do
  swing_lows
  |> Enum.chunk_every(2, 1, :discard)
  |> Enum.all?(fn [prev, curr] ->
    Decimal.compare(curr.price, prev.price) == :lt
  end)
end

defp lower_lows?(_), do: false
```

---

### Helper 5: `detect_latest_bos/4`

**Purpose:** Wrapper to detect most recent BOS

**Implementation:**

```elixir
defp detect_latest_bos(bars, swing_highs, swing_lows, trend) do
  all_swings = (swing_highs ++ swing_lows) |> Enum.sort_by(& &1.index)
  detect_bos(bars, all_swings, trend)
end
```

---

### Helper 6: `detect_latest_choch/4`

**Purpose:** Wrapper to detect most recent ChoCh

**Implementation:**

```elixir
defp detect_latest_choch(bars, swing_highs, swing_lows, trend) do
  all_swings = (swing_highs ++ swing_lows) |> Enum.sort_by(& &1.index)
  detect_choch(bars, all_swings, trend)
end
```

---

## Module Dependencies

**Imports:**
```elixir
alias Signal.Technicals.Swings
alias Signal.MarketData.Bar
```

---

## Testing Checklist

### Unit Tests (`test/signal/technicals/structure_detector_test.exs`)

- [ ] `analyze/1` detects bullish trend
- [ ] `analyze/1` detects bearish trend
- [ ] `analyze/1` detects ranging market
- [ ] `detect_bos/3` finds bullish BOS
- [ ] `detect_bos/3` finds bearish BOS
- [ ] `detect_bos/3` returns nil when no BOS
- [ ] `detect_choch/3` finds bullish ChoCh
- [ ] `detect_choch/3` finds bearish ChoCh
- [ ] `detect_choch/3` returns nil when no ChoCh
- [ ] `determine_trend/2` identifies bullish (HH + HL)
- [ ] `determine_trend/2` identifies bearish (LH + LL)
- [ ] `determine_trend/2` identifies ranging
- [ ] `get_structure_state/1` classifies strong bullish
- [ ] `get_structure_state/1` classifies weak bullish
- [ ] `get_structure_state/1` classifies strong bearish
- [ ] `get_structure_state/1` classifies weak bearish

### Integration Tests

- [ ] Full analysis with real bar data
- [ ] Trend changes over time
- [ ] Multiple BOS in same trend

---

## Implementation Time Estimate

| Task | Time |
|------|------|
| Module setup and structure | 15 min |
| Public API (5 functions) | 60 min |
| Private helpers (6 functions) | 30 min |
| Edge case handling | 20 min |
| Documentation | 20 min |
| Unit tests (16 tests) | 45 min |
| Integration tests (3 tests) | 20 min |
| **Total** | **3h 10min** |

---

# Summary of All Work Orders

| Module | File | Functions | Tests | Est. Time |
|--------|------|-----------|-------|-----------|
| Levels | `lib/signal/technicals/levels.ex` | 16 | 15 | 3h 20min |
| Swings | `lib/signal/technicals/swings.ex` | 7 | 17 | 2h 25min |
| StructureDetector | `lib/signal/technicals/structure_detector.ex` | 11 | 19 | 3h 10min |
| **TOTAL** | **3 files** | **34 functions** | **51 tests** | **~9 hours** |

---

## Implementation Order

**Recommended sequence:**

1. **Swings module first** (no dependencies)
   - Standalone swing detection
   - Can test independently

2. **Levels module second** (no dependencies on swings)
   - Uses BarCache and database
   - Independent from market structure

3. **StructureDetector module third** (depends on Swings)
   - Uses swing detection from Swings module
   - Builds on swing foundation

---

## Next Steps

After completing these three modules, you'll need:

1. **Database migrations** (2 files)
2. **Ecto schemas** (2 files)
3. **LevelCalculator GenServer** (1 file)
4. **Supervision tree update** (modify application.ex)
5. **Integration tests** (test all modules together)

Would you like to proceed with implementation?
