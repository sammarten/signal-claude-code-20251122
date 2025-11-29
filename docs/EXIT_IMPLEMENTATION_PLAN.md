# Exit Strategy Implementation Plan

## Overview

This document outlines the implementation plan for advanced exit strategies in the Signal backtesting framework. The current implementation supports only fixed stop losses and single take profit targets. This enhancement adds:

1. **Trailing Stops** - Stops that follow price to lock in profits
2. **Scaling Out** - Partial position exits at multiple targets
3. **Breakeven Management** - Moving stop to entry after reaching profit milestones
4. **Multiple Take Profit Levels** - Staged exits (T1, T2, T3)

## Current State Analysis

### Existing Exit Logic (`trade_simulator.ex:228-255`)

```elixir
defp check_trade_exit(state, trade_id, trade, bar) do
  case FillSimulator.check_stop(state.fill_config, trade, bar) do
    {:stopped, fill_price, gap?} ->
      close_trade(state, trade_id, fill_price, bar.bar_time, :stopped_out, gap?)
    :ok ->
      case FillSimulator.check_target(state.fill_config, trade, bar) do
        {:target_hit, fill_price} ->
          close_trade(state, trade_id, fill_price, bar.bar_time, :target_hit, false)
        :ok -> state
      end
  end
end
```

**Limitations:**
- Binary exit: either full stop or full target
- No partial position management
- Static stop loss (never adjusts)
- Single take profit level

### Current Data Model (`simulated_trade.ex`)

```elixir
field :stop_loss, :decimal        # Fixed stop
field :take_profit, :decimal      # Single target
field :position_size, :integer    # Full size, no partials
field :status, Ecto.Enum          # Single exit status
```

---

## Implementation Plan

### Task 1: Exit Strategy Configuration Module

**File**: `lib/signal/backtest/exit_strategy.ex`

Create a configuration module that defines exit behavior:

```elixir
defmodule Signal.Backtest.ExitStrategy do
  @moduledoc """
  Configures exit behavior for trade management.

  ## Strategy Types

  - `:fixed` - Traditional fixed stop and single target (current behavior)
  - `:trailing` - Stop follows price at fixed distance or ATR multiple
  - `:scaled` - Multiple targets with partial exits
  - `:breakeven` - Move stop to entry after reaching profit threshold
  - `:combined` - Mix of trailing, scaling, and breakeven
  """

  defstruct [
    :type,
    :initial_stop,
    :trailing_config,
    :targets,
    :breakeven_config
  ]

  @type t :: %__MODULE__{
    type: :fixed | :trailing | :scaled | :breakeven | :combined,
    initial_stop: Decimal.t(),
    trailing_config: trailing_config() | nil,
    targets: [target()] | nil,
    breakeven_config: breakeven_config() | nil
  }

  @type trailing_config :: %{
    type: :fixed_distance | :atr_multiple | :percent,
    value: Decimal.t(),
    activation_profit: Decimal.t() | nil  # Only start trailing after X profit
  }

  @type target :: %{
    price: Decimal.t(),
    exit_percent: integer(),  # 25, 50, etc.
    move_stop_to: :breakeven | :entry | {:price, Decimal.t()} | nil
  }

  @type breakeven_config :: %{
    trigger_r: Decimal.t(),      # Move to BE after 1R profit
    buffer: Decimal.t()          # Small buffer above/below entry
  }

  @doc "Creates a fixed stop/target strategy (current behavior)"
  def fixed(stop_loss, take_profit) do
    %__MODULE__{
      type: :fixed,
      initial_stop: stop_loss,
      targets: [%{price: take_profit, exit_percent: 100, move_stop_to: nil}]
    }
  end

  @doc "Creates a trailing stop strategy"
  def trailing(stop_loss, opts) do
    %__MODULE__{
      type: :trailing,
      initial_stop: stop_loss,
      trailing_config: %{
        type: Keyword.get(opts, :type, :fixed_distance),
        value: Keyword.fetch!(opts, :value),
        activation_profit: Keyword.get(opts, :activation_profit)
      }
    }
  end

  @doc "Creates a scaled exit strategy with multiple targets"
  def scaled(stop_loss, targets) do
    # Validate targets sum to 100%
    total = Enum.sum(Enum.map(targets, & &1.exit_percent))
    unless total == 100, do: raise "Target percentages must sum to 100"

    %__MODULE__{
      type: :scaled,
      initial_stop: stop_loss,
      targets: targets
    }
  end

  @doc "Creates a breakeven management strategy"
  def with_breakeven(strategy, trigger_r, buffer \\ Decimal.new("0.05")) do
    %{strategy |
      breakeven_config: %{
        trigger_r: trigger_r,
        buffer: buffer
      }
    }
  end
end
```

**Example Usage:**

```elixir
# Simple fixed strategy (backwards compatible)
ExitStrategy.fixed(Decimal.new("174.50"), Decimal.new("177.50"))

# Trailing stop: $0.50 trail distance
ExitStrategy.trailing(Decimal.new("174.50"), type: :fixed_distance, value: Decimal.new("0.50"))

# ATR-based trailing (2x ATR)
ExitStrategy.trailing(Decimal.new("174.50"), type: :atr_multiple, value: Decimal.new("2.0"))

# Scale out: 50% at T1, 50% at T2
ExitStrategy.scaled(Decimal.new("174.50"), [
  %{price: Decimal.new("176.50"), exit_percent: 50, move_stop_to: :breakeven},
  %{price: Decimal.new("178.50"), exit_percent: 50, move_stop_to: nil}
])

# Combined: Scale out with trailing on remainder
ExitStrategy.scaled(Decimal.new("174.50"), [
  %{price: Decimal.new("176.50"), exit_percent: 50, move_stop_to: :breakeven}
])
|> ExitStrategy.with_trailing(type: :fixed_distance, value: Decimal.new("0.50"))
```

---

### Task 2: Position State Tracking

**File**: `lib/signal/backtest/position_state.ex`

Track dynamic position state (current stop, remaining size, targets hit):

```elixir
defmodule Signal.Backtest.PositionState do
  @moduledoc """
  Tracks the evolving state of an open position.

  Unlike SimulatedTrade (which records the final outcome), PositionState
  tracks the current state: current stop level, remaining size, targets hit, etc.
  """

  defstruct [
    :trade_id,
    :symbol,
    :direction,
    :entry_price,
    :entry_time,
    :original_size,
    :remaining_size,
    :current_stop,
    :highest_price,        # For trailing (longs)
    :lowest_price,         # For trailing (shorts)
    :exit_strategy,
    :targets_hit,          # List of hit target indices
    :partial_exits,        # List of partial exit records
    :stop_moved_to_be,     # Boolean: has stop been moved to breakeven
    :r_at_peak             # Track max favorable excursion in R
  ]

  @type partial_exit :: %{
    exit_time: DateTime.t(),
    exit_price: Decimal.t(),
    shares_exited: integer(),
    pnl: Decimal.t(),
    reason: :target_1 | :target_2 | :target_3 | :trailing_stop
  }

  @doc "Creates initial position state from trade and exit strategy"
  def new(trade, exit_strategy) do
    %__MODULE__{
      trade_id: trade.id,
      symbol: trade.symbol,
      direction: trade.direction,
      entry_price: trade.entry_price,
      entry_time: trade.entry_time,
      original_size: trade.position_size,
      remaining_size: trade.position_size,
      current_stop: exit_strategy.initial_stop,
      highest_price: trade.entry_price,
      lowest_price: trade.entry_price,
      exit_strategy: exit_strategy,
      targets_hit: [],
      partial_exits: [],
      stop_moved_to_be: false,
      r_at_peak: Decimal.new(0)
    }
  end

  @doc "Updates position state with new bar data"
  def update(state, bar) do
    state
    |> update_price_extremes(bar)
    |> maybe_update_trailing_stop(bar)
    |> update_r_at_peak(bar)
  end

  @doc "Records a partial exit"
  def record_partial_exit(state, exit_record) do
    %{state |
      remaining_size: state.remaining_size - exit_record.shares_exited,
      partial_exits: [exit_record | state.partial_exits]
    }
  end

  @doc "Moves stop to breakeven (entry + buffer)"
  def move_to_breakeven(state) do
    buffer = get_in(state.exit_strategy, [:breakeven_config, :buffer]) || Decimal.new("0.05")

    new_stop = case state.direction do
      :long -> Decimal.add(state.entry_price, buffer)
      :short -> Decimal.sub(state.entry_price, buffer)
    end

    %{state | current_stop: new_stop, stop_moved_to_be: true}
  end

  # Private functions

  defp update_price_extremes(state, bar) do
    %{state |
      highest_price: Decimal.max(state.highest_price, bar.high),
      lowest_price: Decimal.min(state.lowest_price, bar.low)
    }
  end

  defp maybe_update_trailing_stop(state, bar) do
    case state.exit_strategy.trailing_config do
      nil -> state
      config -> update_trailing_stop(state, bar, config)
    end
  end

  defp update_trailing_stop(state, bar, config) do
    # Only trail if activation threshold met (if configured)
    if should_activate_trailing?(state, config) do
      new_stop = calculate_trailing_stop(state, bar, config)

      # Stop can only move in favorable direction
      if better_stop?(state.direction, new_stop, state.current_stop) do
        %{state | current_stop: new_stop}
      else
        state
      end
    else
      state
    end
  end

  defp should_activate_trailing?(state, config) do
    case config.activation_profit do
      nil -> true
      threshold -> current_profit_exceeds?(state, threshold)
    end
  end

  defp calculate_trailing_stop(state, _bar, config) do
    reference_price = case state.direction do
      :long -> state.highest_price
      :short -> state.lowest_price
    end

    trail_distance = case config.type do
      :fixed_distance -> config.value
      :percent -> Decimal.mult(reference_price, config.value)
      :atr_multiple ->
        # Would need ATR passed in or looked up
        Decimal.mult(Decimal.new("1.0"), config.value)  # Placeholder
    end

    case state.direction do
      :long -> Decimal.sub(reference_price, trail_distance)
      :short -> Decimal.add(reference_price, trail_distance)
    end
  end

  defp better_stop?(direction, new_stop, current_stop) do
    case direction do
      :long -> Decimal.compare(new_stop, current_stop) == :gt
      :short -> Decimal.compare(new_stop, current_stop) == :lt
    end
  end

  defp current_profit_exceeds?(_state, _threshold) do
    # Implementation to check if current unrealized profit exceeds threshold
    true
  end

  defp update_r_at_peak(state, bar) do
    # Calculate current R based on best price
    best_price = case state.direction do
      :long -> bar.high
      :short -> bar.low
    end

    current_r = calculate_r(state, best_price)

    if Decimal.compare(current_r, state.r_at_peak) == :gt do
      %{state | r_at_peak: current_r}
    else
      state
    end
  end

  defp calculate_r(state, price) do
    price_move = case state.direction do
      :long -> Decimal.sub(price, state.entry_price)
      :short -> Decimal.sub(state.entry_price, price)
    end

    risk_per_share = Decimal.abs(Decimal.sub(state.entry_price, state.exit_strategy.initial_stop))

    if Decimal.compare(risk_per_share, Decimal.new(0)) == :gt do
      Decimal.div(price_move, risk_per_share)
    else
      Decimal.new(0)
    end
  end
end
```

---

### Task 3: Enhanced Exit Manager

**File**: `lib/signal/backtest/exit_manager.ex`

Core logic for checking and executing exits:

```elixir
defmodule Signal.Backtest.ExitManager do
  @moduledoc """
  Manages position exits including trailing stops, scaling out, and breakeven management.

  Called by TradeSimulator on each bar to check for exit conditions.
  """

  alias Signal.Backtest.PositionState
  alias Signal.Backtest.ExitStrategy

  @type exit_action ::
    :none |
    {:full_exit, exit_reason(), Decimal.t()} |
    {:partial_exit, target_index :: integer(), shares :: integer(), Decimal.t()} |
    {:update_stop, Decimal.t()}

  @type exit_reason :: :stopped_out | :target_hit | :trailing_stopped | :time_exit

  @doc """
  Processes a bar and returns any exit actions needed.

  Returns a list of actions to take (may include multiple for scaled exits).
  """
  @spec process_bar(PositionState.t(), map()) :: {PositionState.t(), [exit_action()]}
  def process_bar(position, bar) do
    position
    |> PositionState.update(bar)
    |> check_stop_hit(bar)
    |> check_targets(bar)
    |> check_breakeven_trigger(bar)
  end

  @doc """
  Checks if the current stop has been hit.
  """
  def check_stop_hit(position, bar) do
    if stop_triggered?(position, bar) do
      fill_price = determine_stop_fill_price(position, bar)
      {position, [{:full_exit, :stopped_out, fill_price}]}
    else
      {position, []}
    end
  end

  @doc """
  Checks if any targets have been hit (for scaled exits).
  """
  def check_targets({position, actions}, bar) do
    # Don't check targets if already stopped out
    if Enum.any?(actions, fn action -> match?({:full_exit, _, _}, action) end) do
      {position, actions}
    else
      case position.exit_strategy.targets do
        nil -> {position, actions}
        targets -> check_target_levels(position, bar, targets, actions)
      end
    end
  end

  @doc """
  Checks if breakeven trigger has been reached.
  """
  def check_breakeven_trigger({position, actions}, bar) do
    case position.exit_strategy.breakeven_config do
      nil ->
        {position, actions}

      config when position.stop_moved_to_be ->
        {position, actions}

      config ->
        if breakeven_triggered?(position, bar, config) do
          new_position = PositionState.move_to_breakeven(position)
          {new_position, [{:update_stop, new_position.current_stop} | actions]}
        else
          {position, actions}
        end
    end
  end

  # Private implementation functions

  defp stop_triggered?(position, bar) do
    case position.direction do
      :long -> Decimal.compare(bar.low, position.current_stop) in [:lt, :eq]
      :short -> Decimal.compare(bar.high, position.current_stop) in [:gt, :eq]
    end
  end

  defp determine_stop_fill_price(position, bar) do
    # Check for gap through stop
    case position.direction do
      :long ->
        if Decimal.compare(bar.open, position.current_stop) == :lt do
          bar.open  # Gapped through - fill at open
        else
          position.current_stop
        end

      :short ->
        if Decimal.compare(bar.open, position.current_stop) == :gt do
          bar.open  # Gapped through - fill at open
        else
          position.current_stop
        end
    end
  end

  defp check_target_levels(position, bar, targets, actions) do
    # Find unhit targets that have been reached
    {new_position, new_actions} =
      targets
      |> Enum.with_index()
      |> Enum.filter(fn {_target, idx} -> idx not in position.targets_hit end)
      |> Enum.reduce({position, actions}, fn {target, idx}, {pos, acts} ->
        if target_reached?(pos, bar, target) do
          shares_to_exit = calculate_shares_for_percent(pos, target.exit_percent)

          updated_pos = %{pos |
            targets_hit: [idx | pos.targets_hit],
            remaining_size: pos.remaining_size - shares_to_exit
          }

          # Maybe move stop after hitting target
          updated_pos = maybe_move_stop_on_target(updated_pos, target)

          action = {:partial_exit, idx, shares_to_exit, target.price}
          {updated_pos, [action | acts]}
        else
          {pos, acts}
        end
      end)

    {new_position, new_actions}
  end

  defp target_reached?(position, bar, target) do
    case position.direction do
      :long -> Decimal.compare(bar.high, target.price) in [:gt, :eq]
      :short -> Decimal.compare(bar.low, target.price) in [:lt, :eq]
    end
  end

  defp calculate_shares_for_percent(position, percent) do
    # Calculate based on original size, not remaining
    # This ensures consistent sizing across targets
    floor(position.original_size * percent / 100)
  end

  defp maybe_move_stop_on_target(position, target) do
    case target.move_stop_to do
      nil -> position
      :breakeven -> PositionState.move_to_breakeven(position)
      :entry -> %{position | current_stop: position.entry_price}
      {:price, price} -> %{position | current_stop: price}
    end
  end

  defp breakeven_triggered?(position, bar, config) do
    current_r = calculate_current_r(position, bar)
    Decimal.compare(current_r, config.trigger_r) in [:gt, :eq]
  end

  defp calculate_current_r(position, bar) do
    favorable_price = case position.direction do
      :long -> bar.high
      :short -> bar.low
    end

    price_move = case position.direction do
      :long -> Decimal.sub(favorable_price, position.entry_price)
      :short -> Decimal.sub(position.entry_price, favorable_price)
    end

    initial_risk = Decimal.abs(
      Decimal.sub(position.entry_price, position.exit_strategy.initial_stop)
    )

    if Decimal.compare(initial_risk, Decimal.new(0)) == :gt do
      Decimal.div(price_move, initial_risk)
    else
      Decimal.new(0)
    end
  end
end
```

---

### Task 4: Database Schema Updates

**Migration**: `priv/repo/migrations/TIMESTAMP_add_exit_strategy_fields.exs`

```elixir
defmodule Signal.Repo.Migrations.AddExitStrategyFields do
  use Ecto.Migration

  def change do
    # Add new fields to simulated_trades
    alter table(:simulated_trades) do
      # Exit strategy used
      add :exit_strategy_type, :string, default: "fixed"

      # Track if stop was moved to breakeven
      add :stop_moved_to_breakeven, :boolean, default: false

      # Final stop at exit (may differ from original)
      add :final_stop, :decimal

      # Maximum favorable excursion (best R reached)
      add :max_favorable_r, :decimal

      # Maximum adverse excursion (worst R before recovery)
      add :max_adverse_r, :decimal

      # Number of partial exits
      add :partial_exit_count, :integer, default: 0
    end

    # Create partial_exits table for tracking scale-out details
    create table(:partial_exits, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :trade_id, references(:simulated_trades, type: :binary_id, on_delete: :delete_all)

      add :exit_time, :utc_datetime_usec
      add :exit_price, :decimal
      add :shares_exited, :integer
      add :remaining_shares, :integer
      add :exit_reason, :string  # "target_1", "target_2", "trailing_stop"

      add :pnl, :decimal
      add :r_multiple, :decimal

      timestamps(type: :utc_datetime_usec)
    end

    create index(:partial_exits, [:trade_id])
  end
end
```

**Schema**: `lib/signal/backtest/partial_exit.ex`

```elixir
defmodule Signal.Backtest.PartialExit do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "partial_exits" do
    belongs_to :trade, Signal.Backtest.SimulatedTrade

    field :exit_time, :utc_datetime_usec
    field :exit_price, :decimal
    field :shares_exited, :integer
    field :remaining_shares, :integer
    field :exit_reason, :string

    field :pnl, :decimal
    field :r_multiple, :decimal

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(partial_exit, attrs) do
    partial_exit
    |> cast(attrs, [:trade_id, :exit_time, :exit_price, :shares_exited,
                    :remaining_shares, :exit_reason, :pnl, :r_multiple])
    |> validate_required([:trade_id, :exit_time, :exit_price, :shares_exited, :exit_reason])
  end
end
```

---

### Task 5: Update SimulatedTrade Schema

**File**: `lib/signal/backtest/simulated_trade.ex` (additions)

```elixir
# Add new fields to schema
field :exit_strategy_type, :string, default: "fixed"
field :stop_moved_to_breakeven, :boolean, default: false
field :final_stop, :decimal
field :max_favorable_r, :decimal
field :max_adverse_r, :decimal
field :partial_exit_count, :integer, default: 0

has_many :partial_exits, Signal.Backtest.PartialExit, foreign_key: :trade_id

# Add to optional fields
@optional_fields [
  # ... existing fields ...
  :exit_strategy_type,
  :stop_moved_to_breakeven,
  :final_stop,
  :max_favorable_r,
  :max_adverse_r,
  :partial_exit_count
]
```

---

### Task 6: Update VirtualAccount for Partial Closes

**File**: `lib/signal/backtest/virtual_account.ex` (additions)

```elixir
@doc """
Partially closes a position, returning cash for the exited shares.

## Parameters

  * `account` - Current account state
  * `trade_id` - ID of the trade to partially close
  * `params` - Map with:
    * `:exit_price` - Exit price
    * `:exit_time` - Exit timestamp
    * `:shares_to_exit` - Number of shares to exit
    * `:reason` - Exit reason (e.g., :target_1, :target_2)

## Returns

  * `{:ok, updated_account, partial_exit_record}` - Partial close successful
  * `{:error, reason}` - Failed to close
"""
@spec partial_close(t(), String.t(), map()) :: {:ok, t(), map()} | {:error, atom()}
def partial_close(account, trade_id, params) do
  case Map.get(account.open_positions, trade_id) do
    nil ->
      {:error, :not_found}

    trade when trade.position_size < params.shares_to_exit ->
      {:error, :insufficient_shares}

    trade ->
      # Calculate P&L for this partial exit
      pnl_per_share = case trade.direction do
        :long -> Decimal.sub(params.exit_price, trade.entry_price)
        :short -> Decimal.sub(trade.entry_price, params.exit_price)
      end

      partial_pnl = Decimal.mult(pnl_per_share, Decimal.new(params.shares_to_exit))

      # Create partial exit record
      partial_exit = %{
        trade_id: trade_id,
        exit_time: params.exit_time,
        exit_price: params.exit_price,
        shares_exited: params.shares_to_exit,
        remaining_shares: trade.position_size - params.shares_to_exit,
        exit_reason: params.reason,
        pnl: partial_pnl,
        r_multiple: calculate_partial_r(trade, partial_pnl, params.shares_to_exit)
      }

      # Update the trade's position size
      updated_trade = %{trade | position_size: trade.position_size - params.shares_to_exit}

      # Calculate cash returned
      exit_value = Decimal.mult(params.exit_price, Decimal.new(params.shares_to_exit))

      # Update account
      updated_account = %{
        account
        | cash: Decimal.add(account.cash, exit_value),
          current_equity: Decimal.add(account.current_equity, partial_pnl),
          open_positions: Map.put(account.open_positions, trade_id, updated_trade)
      }

      {:ok, updated_account, partial_exit}
  end
end

defp calculate_partial_r(trade, pnl, shares) do
  # R-multiple for partial exit based on proportional risk
  risk_per_share = Decimal.abs(Decimal.sub(trade.entry_price, trade.stop_loss))
  partial_risk = Decimal.mult(risk_per_share, Decimal.new(shares))

  if Decimal.compare(partial_risk, Decimal.new(0)) == :gt do
    Decimal.div(pnl, partial_risk) |> Decimal.round(2)
  else
    Decimal.new(0)
  end
end
```

---

### Task 7: Update TradeSimulator Integration

**File**: `lib/signal/backtest/trade_simulator.ex` (updates)

```elixir
# Add to struct
defstruct [
  # ... existing fields ...
  :position_states  # Map of trade_id => PositionState
]

# Update init
def init(opts) do
  # ... existing init ...
  state = %__MODULE__{
    # ... existing fields ...
    position_states: %{}
  }
  {:ok, state}
end

# Update execute_signal to create PositionState
defp execute_signal(state, signal, bar) do
  # ... existing position opening code ...

  case VirtualAccount.open_position(state.account, params) do
    {:ok, updated_account, trade} ->
      # Create exit strategy from signal
      exit_strategy = build_exit_strategy(signal)

      # Create position state for tracking
      position_state = PositionState.new(trade, exit_strategy)

      %{state |
        account: updated_account,
        position_states: Map.put(state.position_states, trade.id, position_state)
      }

    {:error, reason} ->
      Logger.warning("[TradeSimulator] Failed to open position: #{inspect(reason)}")
      state
  end
end

# New: Build exit strategy from signal configuration
defp build_exit_strategy(signal) do
  case Map.get(signal, :exit_strategy) do
    nil ->
      # Default: fixed strategy (backwards compatible)
      ExitStrategy.fixed(signal.stop_loss, Map.get(signal, :take_profit))

    strategy ->
      strategy
  end
end

# Replace check_trade_exit with new implementation
defp check_trade_exit(state, trade_id, trade, bar) do
  position_state = Map.get(state.position_states, trade_id)

  if position_state do
    {updated_position, actions} = ExitManager.process_bar(position_state, bar)

    # Process all actions
    Enum.reduce(actions, %{state | position_states: Map.put(state.position_states, trade_id, updated_position)}, fn
      {:full_exit, reason, fill_price}, acc_state ->
        close_trade(acc_state, trade_id, fill_price, bar.bar_time, reason, false)

      {:partial_exit, target_idx, shares, fill_price}, acc_state ->
        process_partial_exit(acc_state, trade_id, target_idx, shares, fill_price, bar.bar_time)

      {:update_stop, _new_stop}, acc_state ->
        # Stop already updated in position_state, just log
        Logger.debug("[TradeSimulator] Stop moved to #{inspect(updated_position.current_stop)}")
        acc_state
    end)
  else
    # Fallback to original logic for trades without position state
    check_trade_exit_legacy(state, trade_id, trade, bar)
  end
end

defp process_partial_exit(state, trade_id, target_idx, shares, fill_price, exit_time) do
  reason = "target_#{target_idx + 1}"

  case VirtualAccount.partial_close(state.account, trade_id, %{
    exit_price: fill_price,
    exit_time: exit_time,
    shares_to_exit: shares,
    reason: reason
  }) do
    {:ok, updated_account, partial_exit} ->
      Logger.debug(
        "[TradeSimulator] Partial exit #{reason}: #{shares} shares at #{fill_price}, P&L: #{partial_exit.pnl}"
      )

      # Persist partial exit if enabled
      if state.persist_trades do
        persist_partial_exit(partial_exit)
      end

      # Check if position fully closed
      trade = Map.get(updated_account.open_positions, trade_id)
      if trade && trade.position_size == 0 do
        # Remove from open positions, record as fully closed
        finalize_scaled_trade(state, trade_id, updated_account)
      else
        %{state | account: updated_account}
      end

    {:error, reason} ->
      Logger.warning("[TradeSimulator] Partial exit failed: #{inspect(reason)}")
      state
  end
end
```

---

### Task 8: Analytics Updates

**File**: `lib/signal/analytics/trade_metrics.ex` (additions)

Add metrics for exit strategy analysis:

```elixir
@doc """
Calculates exit strategy effectiveness metrics.
"""
def exit_strategy_analysis(trades) do
  %{
    by_exit_type: group_by_exit_type(trades),
    trailing_stop_effectiveness: trailing_effectiveness(trades),
    scale_out_analysis: scale_out_analysis(trades),
    breakeven_impact: breakeven_impact(trades),
    max_favorable_excursion: mfe_analysis(trades),
    max_adverse_excursion: mae_analysis(trades)
  }
end

defp trailing_effectiveness(trades) do
  trailing_trades = Enum.filter(trades, & &1.exit_strategy_type == "trailing")

  if Enum.empty?(trailing_trades) do
    nil
  else
    %{
      count: length(trailing_trades),
      avg_captured_r: average_r(trailing_trades),
      avg_mfe_captured_pct: avg_mfe_captured(trailing_trades)
    }
  end
end

defp scale_out_analysis(trades) do
  scaled_trades = Enum.filter(trades, & &1.partial_exit_count > 0)

  if Enum.empty?(scaled_trades) do
    nil
  else
    %{
      count: length(scaled_trades),
      avg_partial_exits: avg_partial_exits(scaled_trades),
      avg_total_r: average_r(scaled_trades),
      vs_fixed_comparison: compare_to_fixed(scaled_trades)
    }
  end
end

defp breakeven_impact(trades) do
  be_trades = Enum.filter(trades, & &1.stop_moved_to_breakeven)
  non_be_trades = Enum.reject(trades, & &1.stop_moved_to_breakeven)

  %{
    trades_moved_to_be: length(be_trades),
    be_win_rate: win_rate(be_trades),
    non_be_win_rate: win_rate(non_be_trades),
    be_avg_r: average_r(be_trades),
    non_be_avg_r: average_r(non_be_trades)
  }
end

defp mfe_analysis(trades) do
  trades_with_mfe = Enum.filter(trades, & &1.max_favorable_r)

  %{
    avg_mfe: avg_decimal(trades_with_mfe, :max_favorable_r),
    avg_captured_pct: calculate_capture_rate(trades_with_mfe),
    left_on_table: calculate_left_on_table(trades_with_mfe)
  }
end
```

---

## Test Plan

### Unit Tests

**`test/signal/backtest/exit_strategy_test.exs`**
- Test strategy creation (fixed, trailing, scaled, combined)
- Test validation (targets sum to 100%, valid config)
- Test default values

**`test/signal/backtest/position_state_test.exs`**
- Test price extreme tracking
- Test trailing stop calculation
- Test breakeven movement
- Test R calculation

**`test/signal/backtest/exit_manager_test.exs`**
- Test stop detection (hit, gap through)
- Test target detection (single, multiple)
- Test breakeven trigger
- Test trailing stop updates
- Test action generation

**`test/signal/backtest/virtual_account_partial_close_test.exs`**
- Test partial position closure
- Test P&L calculation for partials
- Test insufficient shares error
- Test full position depletion

### Integration Tests

**`test/signal/backtest/exit_integration_test.exs`**
- Full backtest with trailing stops
- Full backtest with scaled exits
- Full backtest with breakeven management
- Compare fixed vs trailing performance
- Verify partial exits persist correctly

---

## Implementation Order

1. **Exit Strategy Configuration** (Task 1) - Define the configuration structures
2. **Position State Tracking** (Task 2) - Track evolving position state
3. **Database Migrations** (Task 4) - Add new fields/tables
4. **Update SimulatedTrade Schema** (Task 5) - Add new fields
5. **VirtualAccount Partial Close** (Task 6) - Enable partial exits
6. **Exit Manager** (Task 3) - Core exit logic
7. **TradeSimulator Integration** (Task 7) - Wire everything together
8. **Analytics Updates** (Task 8) - Exit strategy metrics
9. **Comprehensive Testing** - Unit and integration tests

---

## Backwards Compatibility

The implementation maintains backwards compatibility:

- Signals without `exit_strategy` field use fixed strategy
- Existing tests continue to work unchanged
- TradeSimulator has fallback to legacy logic
- Database migrations add columns with defaults

---

## Example Usage

### Simple Fixed Strategy (Current Behavior)
```elixir
signal = %{
  symbol: "AAPL",
  direction: :long,
  entry_price: Decimal.new("175.00"),
  stop_loss: Decimal.new("174.00"),
  take_profit: Decimal.new("177.00")
}
```

### Trailing Stop
```elixir
signal = %{
  symbol: "AAPL",
  direction: :long,
  entry_price: Decimal.new("175.00"),
  stop_loss: Decimal.new("174.00"),
  exit_strategy: ExitStrategy.trailing(
    Decimal.new("174.00"),
    type: :fixed_distance,
    value: Decimal.new("0.50"),
    activation_profit: Decimal.new("1.0")  # Start trailing after 1R
  )
}
```

### Scaled Exit with Breakeven
```elixir
signal = %{
  symbol: "AAPL",
  direction: :long,
  entry_price: Decimal.new("175.00"),
  stop_loss: Decimal.new("174.00"),
  exit_strategy: ExitStrategy.scaled(Decimal.new("174.00"), [
    %{price: Decimal.new("176.00"), exit_percent: 50, move_stop_to: :breakeven},
    %{price: Decimal.new("178.00"), exit_percent: 50, move_stop_to: nil}
  ])
}
```

### Full Featured: Scale Out + Trailing on Remainder
```elixir
signal = %{
  symbol: "AAPL",
  direction: :long,
  entry_price: Decimal.new("175.00"),
  exit_strategy: %ExitStrategy{
    type: :combined,
    initial_stop: Decimal.new("174.00"),
    targets: [
      %{price: Decimal.new("176.00"), exit_percent: 33, move_stop_to: :breakeven},
      %{price: Decimal.new("177.00"), exit_percent: 33, move_stop_to: nil}
    ],
    trailing_config: %{
      type: :fixed_distance,
      value: Decimal.new("0.50"),
      activation_profit: Decimal.new("2.0")  # Trail final third after 2R
    },
    breakeven_config: %{
      trigger_r: Decimal.new("1.0"),
      buffer: Decimal.new("0.05")
    }
  }
}
```

---

## Success Criteria

1. All exit strategies configurable via `ExitStrategy` module
2. Trailing stops properly follow price and lock in profits
3. Scaled exits correctly partition position across targets
4. Breakeven management moves stop at configured threshold
5. All partial exits tracked and persisted
6. Analytics provide insight into exit strategy effectiveness
7. Full backwards compatibility with existing signals
8. Comprehensive test coverage
9. Performance acceptable for large backtests (10,000+ trades)
