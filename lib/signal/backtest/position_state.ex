defmodule Signal.Backtest.PositionState do
  @moduledoc """
  Tracks the evolving state of an open position during trade simulation.

  Unlike `SimulatedTrade` (which records the final outcome), `PositionState`
  tracks the current state of an open position: current stop level, remaining
  size, targets hit, price extremes for trailing, etc.

  ## State Tracking

  - **Current Stop**: May move due to trailing or breakeven rules
  - **Price Extremes**: Highest/lowest prices since entry (for trailing)
  - **Remaining Size**: Decreases as partial exits occur
  - **Targets Hit**: List of target indices that have been hit
  - **Partial Exits**: History of partial exit transactions
  - **R Metrics**: Track max favorable/adverse excursion

  ## Example

      # Create position state from a trade and exit strategy
      position = PositionState.new(trade, exit_strategy)

      # Update with each new bar
      position = PositionState.update(position, bar)

      # Record a partial exit
      position = PositionState.record_partial_exit(position, %{
        exit_time: bar.bar_time,
        exit_price: Decimal.new("176.00"),
        shares_exited: 50,
        target_index: 0,
        pnl: Decimal.new("75.00")
      })
  """

  alias Signal.Backtest.ExitStrategy

  @type partial_exit :: %{
          exit_time: DateTime.t(),
          exit_price: Decimal.t(),
          shares_exited: pos_integer(),
          target_index: non_neg_integer() | nil,
          reason: atom(),
          pnl: Decimal.t(),
          r_multiple: Decimal.t()
        }

  @type t :: %__MODULE__{
          trade_id: String.t(),
          symbol: String.t(),
          direction: :long | :short,
          entry_price: Decimal.t(),
          entry_time: DateTime.t(),
          original_size: pos_integer(),
          remaining_size: pos_integer(),
          risk_per_share: Decimal.t(),
          current_stop: Decimal.t(),
          initial_stop: Decimal.t(),
          highest_price: Decimal.t(),
          lowest_price: Decimal.t(),
          exit_strategy: ExitStrategy.t(),
          targets_hit: [non_neg_integer()],
          partial_exits: [partial_exit()],
          stop_moved_to_breakeven: boolean(),
          max_favorable_r: Decimal.t(),
          max_adverse_r: Decimal.t()
        }

  @enforce_keys [
    :trade_id,
    :symbol,
    :direction,
    :entry_price,
    :entry_time,
    :original_size,
    :remaining_size,
    :risk_per_share,
    :current_stop,
    :initial_stop,
    :exit_strategy
  ]

  defstruct [
    :trade_id,
    :symbol,
    :direction,
    :entry_price,
    :entry_time,
    :original_size,
    :remaining_size,
    :risk_per_share,
    :current_stop,
    :initial_stop,
    :highest_price,
    :lowest_price,
    :exit_strategy,
    targets_hit: [],
    partial_exits: [],
    stop_moved_to_breakeven: false,
    max_favorable_r: Decimal.new(0),
    max_adverse_r: Decimal.new(0)
  ]

  # ============================================================================
  # Constructor
  # ============================================================================

  @doc """
  Creates a new position state from a trade map and exit strategy.

  ## Parameters

    * `trade` - Map with trade details:
      * `:id` - Trade ID (required)
      * `:symbol` - Symbol (required)
      * `:direction` - `:long` or `:short` (required)
      * `:entry_price` - Entry price (required)
      * `:entry_time` - Entry timestamp (required)
      * `:position_size` - Number of shares (required)
    * `exit_strategy` - `ExitStrategy` struct defining exit behavior

  ## Returns

  A new `%PositionState{}` struct.

  ## Example

      trade = %{
        id: "abc123",
        symbol: "AAPL",
        direction: :long,
        entry_price: Decimal.new("175.00"),
        entry_time: ~U[2024-01-15 09:45:00Z],
        position_size: 100
      }

      strategy = ExitStrategy.fixed(Decimal.new("174.00"), Decimal.new("177.00"))

      position = PositionState.new(trade, strategy)
  """
  @spec new(map(), ExitStrategy.t()) :: t()
  def new(trade, %ExitStrategy{} = exit_strategy) do
    entry_price = trade.entry_price
    initial_stop = exit_strategy.initial_stop

    risk_per_share =
      case trade.direction do
        :long -> Decimal.sub(entry_price, initial_stop)
        :short -> Decimal.sub(initial_stop, entry_price)
      end
      |> Decimal.abs()

    %__MODULE__{
      trade_id: trade.id,
      symbol: trade.symbol,
      direction: trade.direction,
      entry_price: entry_price,
      entry_time: trade.entry_time,
      original_size: trade.position_size,
      remaining_size: trade.position_size,
      risk_per_share: risk_per_share,
      current_stop: initial_stop,
      initial_stop: initial_stop,
      highest_price: entry_price,
      lowest_price: entry_price,
      exit_strategy: exit_strategy,
      targets_hit: [],
      partial_exits: [],
      stop_moved_to_breakeven: false,
      max_favorable_r: Decimal.new(0),
      max_adverse_r: Decimal.new(0)
    }
  end

  # ============================================================================
  # Update Functions
  # ============================================================================

  @doc """
  Updates the position state with new bar data.

  This function:
  1. Updates price extremes (highest/lowest since entry)
  2. Updates max favorable/adverse R excursion
  3. Updates trailing stop if configured and conditions met

  ## Parameters

    * `state` - Current position state
    * `bar` - Bar map with `:high`, `:low`, `:close` fields

  ## Returns

  Updated `%PositionState{}` struct.
  """
  @spec update(t(), map()) :: t()
  def update(%__MODULE__{} = state, bar) do
    state
    |> update_price_extremes(bar)
    |> update_r_excursions(bar)
    |> maybe_update_trailing_stop(bar)
  end

  @doc """
  Updates the position state with new bar data and optional ATR value.

  Use this variant when the exit strategy uses ATR-based trailing.

  ## Parameters

    * `state` - Current position state
    * `bar` - Bar map with `:high`, `:low`, `:close` fields
    * `atr` - Current ATR value as Decimal

  ## Returns

  Updated `%PositionState{}` struct.
  """
  @spec update(t(), map(), Decimal.t()) :: t()
  def update(%__MODULE__{} = state, bar, atr) do
    state
    |> update_price_extremes(bar)
    |> update_r_excursions(bar)
    |> maybe_update_trailing_stop(bar, atr)
  end

  # ============================================================================
  # Stop Management
  # ============================================================================

  @doc """
  Moves the stop to breakeven (entry price + buffer).

  The buffer direction depends on trade direction:
  - Long: stop = entry + buffer (slightly above entry)
  - Short: stop = entry - buffer (slightly below entry)

  ## Parameters

    * `state` - Current position state
    * `buffer` - Optional buffer amount (default from exit strategy or 0.05)

  ## Returns

  Updated `%PositionState{}` with stop at breakeven.
  """
  @spec move_to_breakeven(t(), Decimal.t() | nil) :: t()
  def move_to_breakeven(%__MODULE__{} = state, buffer \\ nil) do
    buffer_amount =
      buffer ||
        get_in(state.exit_strategy.breakeven_config || %{}, [:buffer]) ||
        Decimal.new("0.05")

    new_stop =
      case state.direction do
        :long -> Decimal.add(state.entry_price, buffer_amount)
        :short -> Decimal.sub(state.entry_price, buffer_amount)
      end

    # Only move stop if it's an improvement
    if better_stop?(state.direction, new_stop, state.current_stop) do
      %{state | current_stop: new_stop, stop_moved_to_breakeven: true}
    else
      %{state | stop_moved_to_breakeven: true}
    end
  end

  @doc """
  Moves the stop to a specific price.

  Only moves the stop if the new price is more favorable than the current stop.

  ## Parameters

    * `state` - Current position state
    * `new_stop` - New stop price

  ## Returns

  Updated `%PositionState{}` if stop was improved, unchanged otherwise.
  """
  @spec move_stop_to(t(), Decimal.t()) :: t()
  def move_stop_to(%__MODULE__{} = state, new_stop) do
    if better_stop?(state.direction, new_stop, state.current_stop) do
      %{state | current_stop: new_stop}
    else
      state
    end
  end

  # ============================================================================
  # Partial Exit Management
  # ============================================================================

  @doc """
  Records a partial exit from the position.

  ## Parameters

    * `state` - Current position state
    * `exit_record` - Map with:
      * `:exit_time` - Exit timestamp
      * `:exit_price` - Exit price
      * `:shares_exited` - Number of shares exited
      * `:target_index` - Index of target hit (optional, nil for trailing)
      * `:reason` - Exit reason atom (e.g., `:target_1`, `:trailing_stop`)

  ## Returns

  Updated `%PositionState{}` with partial exit recorded.
  """
  @spec record_partial_exit(t(), map()) :: t()
  def record_partial_exit(%__MODULE__{} = state, exit_record) do
    # Calculate P&L for this partial
    pnl = calculate_partial_pnl(state, exit_record.exit_price, exit_record.shares_exited)
    r_multiple = calculate_partial_r(state, pnl, exit_record.shares_exited)

    partial = %{
      exit_time: exit_record.exit_time,
      exit_price: exit_record.exit_price,
      shares_exited: exit_record.shares_exited,
      target_index: Map.get(exit_record, :target_index),
      reason: exit_record.reason,
      pnl: pnl,
      r_multiple: r_multiple
    }

    # Update targets_hit if this was a target exit
    targets_hit =
      case exit_record[:target_index] do
        nil -> state.targets_hit
        idx -> [idx | state.targets_hit]
      end

    %{
      state
      | remaining_size: state.remaining_size - exit_record.shares_exited,
        partial_exits: [partial | state.partial_exits],
        targets_hit: targets_hit
    }
  end

  @doc """
  Marks a target as hit without recording a partial exit.

  Use this when tracking target hits separately from exit execution.
  """
  @spec mark_target_hit(t(), non_neg_integer()) :: t()
  def mark_target_hit(%__MODULE__{} = state, target_index) do
    if target_index in state.targets_hit do
      state
    else
      %{state | targets_hit: [target_index | state.targets_hit]}
    end
  end

  # ============================================================================
  # Query Functions
  # ============================================================================

  @doc """
  Returns true if the position is fully closed (no remaining shares).
  """
  @spec fully_closed?(t()) :: boolean()
  def fully_closed?(%__MODULE__{remaining_size: 0}), do: true
  def fully_closed?(%__MODULE__{}), do: false

  @doc """
  Returns true if the specified target has been hit.
  """
  @spec target_hit?(t(), non_neg_integer()) :: boolean()
  def target_hit?(%__MODULE__{targets_hit: targets_hit}, target_index) do
    target_index in targets_hit
  end

  @doc """
  Returns the number of partial exits that have occurred.
  """
  @spec partial_exit_count(t()) :: non_neg_integer()
  def partial_exit_count(%__MODULE__{partial_exits: exits}), do: length(exits)

  @doc """
  Returns the total P&L from all partial exits.
  """
  @spec realized_pnl(t()) :: Decimal.t()
  def realized_pnl(%__MODULE__{partial_exits: exits}) do
    Enum.reduce(exits, Decimal.new(0), fn exit, acc ->
      Decimal.add(acc, exit.pnl)
    end)
  end

  @doc """
  Calculates the current unrealized P&L based on a given price.
  """
  @spec unrealized_pnl(t(), Decimal.t()) :: Decimal.t()
  def unrealized_pnl(%__MODULE__{} = state, current_price) do
    calculate_partial_pnl(state, current_price, state.remaining_size)
  end

  @doc """
  Calculates the current R multiple based on a given price (for remaining shares).
  """
  @spec current_r(t(), Decimal.t()) :: Decimal.t()
  def current_r(%__MODULE__{} = state, current_price) do
    price_move =
      case state.direction do
        :long -> Decimal.sub(current_price, state.entry_price)
        :short -> Decimal.sub(state.entry_price, current_price)
      end

    if Decimal.compare(state.risk_per_share, Decimal.new(0)) == :gt do
      Decimal.div(price_move, state.risk_per_share) |> Decimal.round(2)
    else
      Decimal.new(0)
    end
  end

  @doc """
  Returns the number of shares to exit for a given percentage of the original position.
  """
  @spec shares_for_percent(t(), pos_integer()) :: pos_integer()
  def shares_for_percent(%__MODULE__{original_size: original}, percent) do
    floor(original * percent / 100)
  end

  @doc """
  Returns the next unhit target, if any.
  """
  @spec next_target(t()) :: {non_neg_integer(), map()} | nil
  def next_target(%__MODULE__{exit_strategy: %{targets: nil}}), do: nil
  def next_target(%__MODULE__{exit_strategy: %{targets: []}}), do: nil

  def next_target(%__MODULE__{exit_strategy: %{targets: targets}, targets_hit: hit}) do
    targets
    |> Enum.with_index()
    |> Enum.find(fn {_target, idx} -> idx not in hit end)
    |> case do
      nil -> nil
      {target, idx} -> {idx, target}
    end
  end

  @doc """
  Returns summary data for converting to a closed trade record.
  """
  @spec to_summary(t()) :: map()
  def to_summary(%__MODULE__{} = state) do
    %{
      trade_id: state.trade_id,
      symbol: state.symbol,
      direction: state.direction,
      entry_price: state.entry_price,
      entry_time: state.entry_time,
      original_size: state.original_size,
      final_stop: state.current_stop,
      stop_moved_to_breakeven: state.stop_moved_to_breakeven,
      max_favorable_r: state.max_favorable_r,
      max_adverse_r: state.max_adverse_r,
      partial_exit_count: length(state.partial_exits),
      exit_strategy_type: ExitStrategy.type_string(state.exit_strategy)
    }
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp update_price_extremes(%__MODULE__{} = state, bar) do
    %{
      state
      | highest_price: Decimal.max(state.highest_price, bar.high),
        lowest_price: Decimal.min(state.lowest_price, bar.low)
    }
  end

  defp update_r_excursions(%__MODULE__{} = state, bar) do
    # Max favorable excursion (best price in our favor)
    favorable_price =
      case state.direction do
        :long -> bar.high
        :short -> bar.low
      end

    favorable_r = current_r(state, favorable_price)

    # Max adverse excursion (worst price against us)
    adverse_price =
      case state.direction do
        :long -> bar.low
        :short -> bar.high
      end

    adverse_r = current_r(state, adverse_price)

    %{
      state
      | max_favorable_r: Decimal.max(state.max_favorable_r, favorable_r),
        max_adverse_r: Decimal.min(state.max_adverse_r, adverse_r)
    }
  end

  defp maybe_update_trailing_stop(
         %__MODULE__{exit_strategy: %{trailing_config: nil}} = state,
         _bar
       ) do
    state
  end

  defp maybe_update_trailing_stop(%__MODULE__{} = state, bar) do
    maybe_update_trailing_stop(state, bar, nil)
  end

  defp maybe_update_trailing_stop(
         %__MODULE__{exit_strategy: %{trailing_config: nil}} = state,
         _bar,
         _atr
       ) do
    state
  end

  defp maybe_update_trailing_stop(%__MODULE__{} = state, bar, atr) do
    config = state.exit_strategy.trailing_config

    if should_activate_trailing?(state, config) do
      new_stop = calculate_trailing_stop(state, bar, config, atr)

      if better_stop?(state.direction, new_stop, state.current_stop) do
        %{state | current_stop: new_stop}
      else
        state
      end
    else
      state
    end
  end

  defp should_activate_trailing?(%__MODULE__{} = state, config) do
    case config.activation_r do
      nil ->
        true

      activation_r ->
        # Check if we've reached the activation threshold
        current_favorable_r = state.max_favorable_r
        Decimal.compare(current_favorable_r, activation_r) in [:gt, :eq]
    end
  end

  defp calculate_trailing_stop(%__MODULE__{} = state, _bar, config, atr) do
    reference_price =
      case state.direction do
        :long -> state.highest_price
        :short -> state.lowest_price
      end

    trail_distance =
      case config.type do
        :fixed_distance ->
          config.value

        :percent ->
          Decimal.mult(reference_price, config.value)

        :atr_multiple ->
          if atr do
            Decimal.mult(atr, config.value)
          else
            # Fallback if ATR not provided - use initial risk as approximation
            Decimal.mult(state.risk_per_share, config.value)
          end
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

  defp calculate_partial_pnl(%__MODULE__{} = state, exit_price, shares) do
    price_move =
      case state.direction do
        :long -> Decimal.sub(exit_price, state.entry_price)
        :short -> Decimal.sub(state.entry_price, exit_price)
      end

    Decimal.mult(price_move, Decimal.new(shares)) |> Decimal.round(2)
  end

  defp calculate_partial_r(%__MODULE__{} = state, pnl, shares) do
    partial_risk = Decimal.mult(state.risk_per_share, Decimal.new(shares))

    if Decimal.compare(partial_risk, Decimal.new(0)) == :gt do
      Decimal.div(pnl, partial_risk) |> Decimal.round(2)
    else
      Decimal.new(0)
    end
  end
end
