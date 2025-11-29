defmodule Signal.Backtest.ExitManager do
  @moduledoc """
  Manages position exits including trailing stops, scaling out, and breakeven management.

  The ExitManager is called by the TradeSimulator on each bar to check for exit
  conditions and determine what actions to take.

  ## Exit Actions

  The `process_bar/2` function returns a tuple of `{updated_position, actions}` where
  actions is a list of exit actions to execute:

  - `{:full_exit, reason, fill_price}` - Close entire remaining position
  - `{:partial_exit, target_index, shares, fill_price}` - Scale out at a target
  - `{:update_stop, new_stop}` - Stop has been moved (trailing or breakeven)

  ## Processing Order

  1. Update position state with new bar data (price extremes, trailing stop)
  2. Check if stop has been hit (full exit)
  3. Check if any targets have been reached (partial exits)
  4. Check if breakeven trigger has been reached (stop update)

  ## Example

      position = PositionState.new(trade, exit_strategy)

      # On each new bar
      {updated_position, actions} = ExitManager.process_bar(position, bar)

      Enum.each(actions, fn
        {:full_exit, :stopped_out, price} ->
          # Close entire position at price

        {:partial_exit, 0, 50, price} ->
          # Exit 50 shares at target 0

        {:update_stop, new_stop} ->
          # Stop moved to new_stop
      end)
  """

  alias Signal.Backtest.PositionState
  alias Signal.Backtest.ExitStrategy

  @type exit_reason :: :stopped_out | :trailing_stopped | :target_hit | :time_exit
  @type exit_action ::
          {:full_exit, exit_reason(), Decimal.t()}
          | {:partial_exit, non_neg_integer(), pos_integer(), Decimal.t()}
          | {:update_stop, Decimal.t()}

  # ============================================================================
  # Main API
  # ============================================================================

  @doc """
  Processes a bar and returns any exit actions needed.

  This is the main entry point called by TradeSimulator on each bar for each
  open position.

  ## Parameters

    * `position` - Current PositionState
    * `bar` - Bar map with `:open`, `:high`, `:low`, `:close`, `:bar_time`
    * `opts` - Optional keyword list:
      * `:atr` - Current ATR value for ATR-based trailing (optional)

  ## Returns

  A tuple of `{updated_position, actions}` where:
    * `updated_position` - PositionState with updated stop, price extremes, etc.
    * `actions` - List of exit actions to execute (may be empty)

  ## Example

      {position, actions} = ExitManager.process_bar(position, bar)

      case actions do
        [] -> # No exit conditions met
        [{:full_exit, :stopped_out, price}] -> # Stop hit
        [{:partial_exit, 0, 50, price}, {:update_stop, new_stop}] -> # Target + BE move
      end
  """
  @spec process_bar(PositionState.t(), map(), keyword()) :: {PositionState.t(), [exit_action()]}
  def process_bar(%PositionState{} = position, bar, opts \\ []) do
    atr = Keyword.get(opts, :atr)

    # First update the position state with new bar data
    updated_position =
      if atr do
        PositionState.update(position, bar, atr)
      else
        PositionState.update(position, bar)
      end

    # Check for exit conditions in order of priority
    updated_position
    |> check_stop_hit(bar)
    |> check_targets(bar)
    |> check_breakeven_trigger(bar)
  end

  # ============================================================================
  # Stop Hit Detection
  # ============================================================================

  @doc """
  Checks if the current stop has been hit.

  For longs, stop is hit if bar.low <= current_stop.
  For shorts, stop is hit if bar.high >= current_stop.

  Handles gap-through scenarios where the bar opens beyond the stop.
  """
  @spec check_stop_hit(PositionState.t(), map()) :: {PositionState.t(), [exit_action()]}
  def check_stop_hit(%PositionState{} = position, bar) do
    if stop_triggered?(position, bar) do
      fill_price = determine_stop_fill_price(position, bar)
      reason = determine_stop_reason(position)
      {position, [{:full_exit, reason, fill_price}]}
    else
      {position, []}
    end
  end

  # ============================================================================
  # Target Detection
  # ============================================================================

  @doc """
  Checks if any take profit targets have been hit.

  Only checks targets that haven't been hit yet. For scaled exits, multiple
  targets can be hit on the same bar (though this is rare).

  Does not check targets if a stop exit is already pending.
  """
  @spec check_targets({PositionState.t(), [exit_action()]}, map()) ::
          {PositionState.t(), [exit_action()]}
  def check_targets({position, actions}, bar) do
    # Don't check targets if already stopped out
    if has_full_exit?(actions) do
      {position, actions}
    else
      case position.exit_strategy.targets do
        nil -> {position, actions}
        [] -> {position, actions}
        targets -> check_target_levels(position, bar, targets, actions)
      end
    end
  end

  # ============================================================================
  # Breakeven Management
  # ============================================================================

  @doc """
  Checks if breakeven trigger has been reached.

  If the position has a breakeven_config and hasn't already moved to breakeven,
  checks if the current bar reached the trigger R level.

  Does not trigger if a full exit is already pending.
  """
  @spec check_breakeven_trigger({PositionState.t(), [exit_action()]}, map()) ::
          {PositionState.t(), [exit_action()]}
  def check_breakeven_trigger({position, actions}, bar) do
    cond do
      # Already exiting
      has_full_exit?(actions) ->
        {position, actions}

      # No breakeven config
      is_nil(position.exit_strategy.breakeven_config) ->
        {position, actions}

      # Already moved to breakeven
      position.stop_moved_to_breakeven ->
        {position, actions}

      # Check if trigger reached
      breakeven_triggered?(position, bar) ->
        new_position = PositionState.move_to_breakeven(position)
        {new_position, [{:update_stop, new_position.current_stop} | actions]}

      true ->
        {position, actions}
    end
  end

  # ============================================================================
  # Query Functions
  # ============================================================================

  @doc """
  Returns true if a stop would be triggered at the given bar.
  """
  @spec stop_triggered?(PositionState.t(), map()) :: boolean()
  def stop_triggered?(%PositionState{direction: :long, current_stop: stop}, bar) do
    Decimal.compare(bar.low, stop) in [:lt, :eq]
  end

  def stop_triggered?(%PositionState{direction: :short, current_stop: stop}, bar) do
    Decimal.compare(bar.high, stop) in [:gt, :eq]
  end

  @doc """
  Returns true if a target price would be reached at the given bar.
  """
  @spec target_reached?(PositionState.t(), map(), Decimal.t()) :: boolean()
  def target_reached?(%PositionState{direction: :long}, bar, target_price) do
    Decimal.compare(bar.high, target_price) in [:gt, :eq]
  end

  def target_reached?(%PositionState{direction: :short}, bar, target_price) do
    Decimal.compare(bar.low, target_price) in [:lt, :eq]
  end

  # ============================================================================
  # Private Functions - Stop Handling
  # ============================================================================

  defp determine_stop_fill_price(%PositionState{direction: :long} = position, bar) do
    # Check for gap through stop (opened below stop)
    if Decimal.compare(bar.open, position.current_stop) == :lt do
      bar.open
    else
      position.current_stop
    end
  end

  defp determine_stop_fill_price(%PositionState{direction: :short} = position, bar) do
    # Check for gap through stop (opened above stop)
    if Decimal.compare(bar.open, position.current_stop) == :gt do
      bar.open
    else
      position.current_stop
    end
  end

  defp determine_stop_reason(%PositionState{} = position) do
    cond do
      # If stop has moved from initial, it was trailing
      ExitStrategy.trailing?(position.exit_strategy) and
          Decimal.compare(position.current_stop, position.initial_stop) != :eq ->
        :trailing_stopped

      # Otherwise regular stop out
      true ->
        :stopped_out
    end
  end

  # ============================================================================
  # Private Functions - Target Handling
  # ============================================================================

  defp check_target_levels(position, bar, targets, existing_actions) do
    # Find all unhit targets that have been reached
    {updated_position, new_actions} =
      targets
      |> Enum.with_index()
      |> Enum.filter(fn {_target, idx} -> idx not in position.targets_hit end)
      |> Enum.sort_by(fn {target, _idx} -> target.price end, &compare_target_order/2)
      |> Enum.reduce({position, []}, fn {target, idx}, {pos, acts} ->
        if target_reached?(pos, bar, target.price) and pos.remaining_size > 0 do
          process_target_hit(pos, bar, target, idx, acts)
        else
          {pos, acts}
        end
      end)

    # Combine with existing actions, maintaining order
    {updated_position, existing_actions ++ Enum.reverse(new_actions)}
  end

  defp compare_target_order(price1, price2) do
    # Sort targets by price (ascending for longs, descending for shorts)
    # This ensures we hit nearer targets first
    Decimal.compare(price1, price2) == :lt
  end

  defp process_target_hit(position, _bar, target, target_index, actions) do
    # Calculate shares to exit for this target
    shares_to_exit = calculate_shares_for_target(position, target)

    # Ensure we don't exit more than remaining
    shares_to_exit = min(shares_to_exit, position.remaining_size)

    if shares_to_exit > 0 do
      # Record the partial exit in position state
      updated_position =
        PositionState.record_partial_exit(position, %{
          exit_time: nil,
          exit_price: target.price,
          shares_exited: shares_to_exit,
          target_index: target_index,
          reason: target_reason(target_index)
        })

      # Maybe move stop after hitting target
      updated_position = maybe_move_stop_on_target(updated_position, target)

      # Create the action
      action = {:partial_exit, target_index, shares_to_exit, target.price}

      # Add stop update action if stop was moved
      stop_actions =
        if updated_position.current_stop != position.current_stop do
          [{:update_stop, updated_position.current_stop}]
        else
          []
        end

      {updated_position, [action | stop_actions] ++ actions}
    else
      {position, actions}
    end
  end

  defp calculate_shares_for_target(position, target) do
    # Calculate based on original size to ensure consistent sizing
    PositionState.shares_for_percent(position, target.exit_percent)
  end

  defp target_reason(target_index) do
    String.to_atom("target_#{target_index + 1}")
  end

  defp maybe_move_stop_on_target(position, target) do
    case target.move_stop_to do
      nil ->
        position

      :breakeven ->
        PositionState.move_to_breakeven(position)

      :entry ->
        PositionState.move_stop_to(position, position.entry_price)

      {:price, price} ->
        PositionState.move_stop_to(position, price)
    end
  end

  # ============================================================================
  # Private Functions - Breakeven
  # ============================================================================

  defp breakeven_triggered?(%PositionState{} = position, bar) do
    config = position.exit_strategy.breakeven_config
    trigger_r = config.trigger_r

    # Check if the favorable price reached the trigger R
    favorable_price =
      case position.direction do
        :long -> bar.high
        :short -> bar.low
      end

    current_r = PositionState.current_r(position, favorable_price)
    Decimal.compare(current_r, trigger_r) in [:gt, :eq]
  end

  # ============================================================================
  # Private Functions - Helpers
  # ============================================================================

  defp has_full_exit?(actions) do
    Enum.any?(actions, fn
      {:full_exit, _, _} -> true
      _ -> false
    end)
  end
end
