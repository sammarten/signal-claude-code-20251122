defmodule Signal.Backtest.ExitManagerTest do
  use ExUnit.Case, async: true

  alias Signal.Backtest.ExitManager
  alias Signal.Backtest.ExitStrategy
  alias Signal.Backtest.PositionState

  # ============================================================================
  # Test Helpers
  # ============================================================================

  defp create_trade(overrides \\ []) do
    defaults = %{
      id: "trade-123",
      symbol: "AAPL",
      direction: :long,
      entry_price: Decimal.new("100.00"),
      entry_time: ~U[2024-01-15 09:45:00Z],
      position_size: 100
    }

    Enum.into(overrides, defaults)
  end

  defp create_bar(overrides \\ []) do
    defaults = %{
      open: Decimal.new("100.50"),
      high: Decimal.new("101.00"),
      low: Decimal.new("100.00"),
      close: Decimal.new("100.75"),
      bar_time: ~U[2024-01-15 10:00:00Z]
    }

    Enum.into(overrides, defaults)
  end

  # ============================================================================
  # process_bar/2 - General Tests
  # ============================================================================

  describe "process_bar/2" do
    test "returns empty actions when no exit conditions met" do
      strategy = ExitStrategy.fixed(Decimal.new("98.00"), Decimal.new("105.00"))
      trade = create_trade()
      position = PositionState.new(trade, strategy)

      bar = create_bar()

      {updated_position, actions} = ExitManager.process_bar(position, bar)

      assert actions == []
      # Position state should be updated with price extremes
      assert Decimal.compare(updated_position.highest_price, bar.high) == :eq
      assert Decimal.compare(updated_position.lowest_price, bar.low) == :eq
    end

    test "updates position state even when no exits" do
      strategy = ExitStrategy.fixed(Decimal.new("98.00"), Decimal.new("105.00"))
      trade = create_trade()
      position = PositionState.new(trade, strategy)

      bar = create_bar(high: Decimal.new("103.00"), low: Decimal.new("99.50"))

      {updated_position, _actions} = ExitManager.process_bar(position, bar)

      assert Decimal.compare(updated_position.highest_price, Decimal.new("103.00")) == :eq
      assert Decimal.compare(updated_position.lowest_price, Decimal.new("99.50")) == :eq
      # Max favorable R: (103 - 100) / (100 - 98) = 3 / 2 = 1.5R
      assert Decimal.compare(updated_position.max_favorable_r, Decimal.new("1.50")) == :eq
    end
  end

  # ============================================================================
  # Stop Hit Detection - Long Positions
  # ============================================================================

  describe "check_stop_hit/2 for long positions" do
    test "detects stop hit when low touches stop" do
      strategy = ExitStrategy.fixed(Decimal.new("98.00"), Decimal.new("105.00"))
      trade = create_trade()
      position = PositionState.new(trade, strategy)

      bar = create_bar(low: Decimal.new("98.00"))

      {_position, actions} = ExitManager.check_stop_hit(position, bar)

      assert [{:full_exit, :stopped_out, fill_price}] = actions
      assert Decimal.compare(fill_price, Decimal.new("98.00")) == :eq
    end

    test "detects stop hit when low goes below stop" do
      strategy = ExitStrategy.fixed(Decimal.new("98.00"), Decimal.new("105.00"))
      trade = create_trade()
      position = PositionState.new(trade, strategy)

      bar = create_bar(low: Decimal.new("97.50"))

      {_position, actions} = ExitManager.check_stop_hit(position, bar)

      assert [{:full_exit, :stopped_out, fill_price}] = actions
      # Fill at stop, not low
      assert Decimal.compare(fill_price, Decimal.new("98.00")) == :eq
    end

    test "handles gap through stop with fill at open" do
      strategy = ExitStrategy.fixed(Decimal.new("98.00"), Decimal.new("105.00"))
      trade = create_trade()
      position = PositionState.new(trade, strategy)

      # Gap down through stop
      bar = create_bar(open: Decimal.new("97.00"), low: Decimal.new("96.50"))

      {_position, actions} = ExitManager.check_stop_hit(position, bar)

      assert [{:full_exit, :stopped_out, fill_price}] = actions
      # Fill at open (gap through)
      assert Decimal.compare(fill_price, Decimal.new("97.00")) == :eq
    end

    test "no stop hit when low above stop" do
      strategy = ExitStrategy.fixed(Decimal.new("98.00"), Decimal.new("105.00"))
      trade = create_trade()
      position = PositionState.new(trade, strategy)

      bar = create_bar(low: Decimal.new("98.50"))

      {_position, actions} = ExitManager.check_stop_hit(position, bar)

      assert actions == []
    end

    test "returns trailing_stopped reason when trailing stop hit" do
      strategy =
        ExitStrategy.trailing(
          Decimal.new("98.00"),
          type: :fixed_distance,
          value: Decimal.new("2.00")
        )

      trade = create_trade()
      position = PositionState.new(trade, strategy)

      # First, move the trailing stop by updating with a higher high
      high_bar = create_bar(high: Decimal.new("105.00"), low: Decimal.new("104.00"))
      position = PositionState.update(position, high_bar)

      # Trailing stop should now be at 103.00 (105 - 2)
      assert Decimal.compare(position.current_stop, Decimal.new("103.00")) == :eq

      # Now hit the trailing stop
      stop_bar = create_bar(high: Decimal.new("103.50"), low: Decimal.new("102.50"))

      {_position, actions} = ExitManager.check_stop_hit(position, stop_bar)

      assert [{:full_exit, :trailing_stopped, _fill_price}] = actions
    end
  end

  # ============================================================================
  # Stop Hit Detection - Short Positions
  # ============================================================================

  describe "check_stop_hit/2 for short positions" do
    test "detects stop hit when high touches stop" do
      strategy = ExitStrategy.fixed(Decimal.new("102.00"), Decimal.new("95.00"))
      trade = create_trade(direction: :short)
      position = PositionState.new(trade, strategy)

      bar = create_bar(high: Decimal.new("102.00"))

      {_position, actions} = ExitManager.check_stop_hit(position, bar)

      assert [{:full_exit, :stopped_out, fill_price}] = actions
      assert Decimal.compare(fill_price, Decimal.new("102.00")) == :eq
    end

    test "handles gap through stop for shorts" do
      strategy = ExitStrategy.fixed(Decimal.new("102.00"), Decimal.new("95.00"))
      trade = create_trade(direction: :short)
      position = PositionState.new(trade, strategy)

      # Gap up through stop
      bar = create_bar(open: Decimal.new("103.00"), high: Decimal.new("103.50"))

      {_position, actions} = ExitManager.check_stop_hit(position, bar)

      assert [{:full_exit, :stopped_out, fill_price}] = actions
      # Fill at open (gap through)
      assert Decimal.compare(fill_price, Decimal.new("103.00")) == :eq
    end

    test "no stop hit when high below stop for short" do
      strategy = ExitStrategy.fixed(Decimal.new("102.00"), Decimal.new("95.00"))
      trade = create_trade(direction: :short)
      position = PositionState.new(trade, strategy)

      bar = create_bar(high: Decimal.new("101.50"))

      {_position, actions} = ExitManager.check_stop_hit(position, bar)

      assert actions == []
    end
  end

  # ============================================================================
  # Target Detection - Single Target
  # ============================================================================

  describe "check_targets/2 with single target" do
    test "detects target hit for long" do
      strategy = ExitStrategy.fixed(Decimal.new("98.00"), Decimal.new("105.00"))
      trade = create_trade()
      position = PositionState.new(trade, strategy)

      bar = create_bar(high: Decimal.new("105.50"))

      {position, []} = ExitManager.check_stop_hit(position, bar)
      {_position, actions} = ExitManager.check_targets({position, []}, bar)

      assert [{:partial_exit, 0, shares, fill_price}] = actions
      assert shares == 100
      assert Decimal.compare(fill_price, Decimal.new("105.00")) == :eq
    end

    test "detects target hit for short" do
      strategy = ExitStrategy.fixed(Decimal.new("102.00"), Decimal.new("95.00"))
      trade = create_trade(direction: :short)
      position = PositionState.new(trade, strategy)

      bar = create_bar(low: Decimal.new("94.50"))

      {position, []} = ExitManager.check_stop_hit(position, bar)
      {_position, actions} = ExitManager.check_targets({position, []}, bar)

      assert [{:partial_exit, 0, shares, fill_price}] = actions
      assert shares == 100
      assert Decimal.compare(fill_price, Decimal.new("95.00")) == :eq
    end

    test "skips targets if stop already triggered" do
      strategy = ExitStrategy.fixed(Decimal.new("98.00"), Decimal.new("105.00"))
      trade = create_trade()
      position = PositionState.new(trade, strategy)

      # Bar that hits both stop and target (rare but possible)
      bar = create_bar(low: Decimal.new("97.00"), high: Decimal.new("106.00"))

      {position, stop_actions} = ExitManager.check_stop_hit(position, bar)
      assert [{:full_exit, :stopped_out, _}] = stop_actions

      # Targets should be skipped since we're already stopping out
      {_position, actions} = ExitManager.check_targets({position, stop_actions}, bar)

      # Only the stop action, no target actions added
      assert actions == stop_actions
    end
  end

  # ============================================================================
  # Target Detection - Scaled Exits
  # ============================================================================

  describe "check_targets/2 with scaled exits" do
    test "hits first target only when price reaches T1 but not T2" do
      strategy =
        ExitStrategy.scaled(Decimal.new("98.00"), [
          %{price: Decimal.new("102.00"), exit_percent: 50, move_stop_to: nil},
          %{price: Decimal.new("105.00"), exit_percent: 50, move_stop_to: nil}
        ])

      trade = create_trade()
      position = PositionState.new(trade, strategy)

      # Hits T1 but not T2
      bar = create_bar(high: Decimal.new("103.00"))

      {position, []} = ExitManager.check_stop_hit(position, bar)
      {updated_position, actions} = ExitManager.check_targets({position, []}, bar)

      assert [{:partial_exit, 0, 50, fill_price}] = actions
      assert Decimal.compare(fill_price, Decimal.new("102.00")) == :eq

      # Target 0 should be marked as hit
      assert 0 in updated_position.targets_hit
      assert updated_position.remaining_size == 50
    end

    test "hits multiple targets on same bar" do
      strategy =
        ExitStrategy.scaled(Decimal.new("98.00"), [
          %{price: Decimal.new("102.00"), exit_percent: 50, move_stop_to: nil},
          %{price: Decimal.new("105.00"), exit_percent: 50, move_stop_to: nil}
        ])

      trade = create_trade()
      position = PositionState.new(trade, strategy)

      # Hits both targets
      bar = create_bar(high: Decimal.new("106.00"))

      {position, []} = ExitManager.check_stop_hit(position, bar)
      {updated_position, actions} = ExitManager.check_targets({position, []}, bar)

      # Both targets hit
      assert length(actions) >= 2
      assert 0 in updated_position.targets_hit
      assert 1 in updated_position.targets_hit
      assert updated_position.remaining_size == 0
    end

    test "does not re-hit already hit targets" do
      strategy =
        ExitStrategy.scaled(Decimal.new("98.00"), [
          %{price: Decimal.new("102.00"), exit_percent: 50, move_stop_to: nil},
          %{price: Decimal.new("105.00"), exit_percent: 50, move_stop_to: nil}
        ])

      trade = create_trade()
      position = PositionState.new(trade, strategy)

      # First bar hits T1
      bar1 = create_bar(high: Decimal.new("103.00"))
      {position, []} = ExitManager.check_stop_hit(position, bar1)
      {position, actions1} = ExitManager.check_targets({position, []}, bar1)
      assert length(actions1) == 1

      # Update position for second bar
      position = PositionState.update(position, bar1)

      # Second bar touches T1 again but should not trigger
      bar2 = create_bar(high: Decimal.new("102.50"))
      {position, []} = ExitManager.check_stop_hit(position, bar2)
      {_position, actions2} = ExitManager.check_targets({position, []}, bar2)

      assert actions2 == []
    end

    test "moves stop to breakeven on target hit when configured" do
      strategy =
        ExitStrategy.scaled(Decimal.new("98.00"), [
          %{price: Decimal.new("102.00"), exit_percent: 50, move_stop_to: :breakeven},
          %{price: Decimal.new("105.00"), exit_percent: 50, move_stop_to: nil}
        ])

      trade = create_trade()
      position = PositionState.new(trade, strategy)

      bar = create_bar(high: Decimal.new("103.00"))

      {position, []} = ExitManager.check_stop_hit(position, bar)
      {updated_position, actions} = ExitManager.check_targets({position, []}, bar)

      # Should have partial exit + stop update
      assert Enum.any?(actions, fn
               {:partial_exit, 0, _, _} -> true
               _ -> false
             end)

      assert Enum.any?(actions, fn
               {:update_stop, _} -> true
               _ -> false
             end)

      # Stop should be at or near entry
      assert updated_position.stop_moved_to_breakeven == true
      # Default buffer is 0.05, so stop should be 100.05
      assert Decimal.compare(updated_position.current_stop, Decimal.new("100.05")) == :eq
    end

    test "moves stop to specific price on target hit" do
      strategy =
        ExitStrategy.scaled(Decimal.new("98.00"), [
          %{
            price: Decimal.new("102.00"),
            exit_percent: 50,
            move_stop_to: {:price, Decimal.new("99.50")}
          },
          %{price: Decimal.new("105.00"), exit_percent: 50, move_stop_to: nil}
        ])

      trade = create_trade()
      position = PositionState.new(trade, strategy)

      bar = create_bar(high: Decimal.new("103.00"))

      {position, []} = ExitManager.check_stop_hit(position, bar)
      {updated_position, _actions} = ExitManager.check_targets({position, []}, bar)

      assert Decimal.compare(updated_position.current_stop, Decimal.new("99.50")) == :eq
    end
  end

  # ============================================================================
  # Breakeven Management
  # ============================================================================

  describe "check_breakeven_trigger/2" do
    test "moves to breakeven when R threshold reached" do
      strategy =
        ExitStrategy.fixed(Decimal.new("98.00"), Decimal.new("105.00"))
        |> ExitStrategy.with_breakeven(Decimal.new("1.0"), Decimal.new("0.10"))

      trade = create_trade()
      position = PositionState.new(trade, strategy)

      # Bar reaches 1R (entry 100, stop 98, so 1R = 102)
      bar = create_bar(high: Decimal.new("102.50"))

      # First update position and check for stops
      position = PositionState.update(position, bar)
      {position, []} = ExitManager.check_stop_hit(position, bar)
      {position, []} = ExitManager.check_targets({position, []}, bar)
      {updated_position, actions} = ExitManager.check_breakeven_trigger({position, []}, bar)

      assert [{:update_stop, new_stop}] = actions
      # Breakeven with 0.10 buffer
      assert Decimal.compare(new_stop, Decimal.new("100.10")) == :eq
      assert updated_position.stop_moved_to_breakeven == true
    end

    test "does not trigger breakeven twice" do
      strategy =
        ExitStrategy.fixed(Decimal.new("98.00"), Decimal.new("105.00"))
        |> ExitStrategy.with_breakeven(Decimal.new("1.0"))

      trade = create_trade()
      position = PositionState.new(trade, strategy)

      # First bar triggers breakeven
      bar1 = create_bar(high: Decimal.new("102.50"))
      {updated, _actions} = ExitManager.process_bar(position, bar1)

      # Second bar should not trigger again
      bar2 = create_bar(high: Decimal.new("103.00"))
      {_updated2, actions2} = ExitManager.process_bar(updated, bar2)

      # No breakeven update action
      refute Enum.any?(actions2, fn
               {:update_stop, _} -> true
               _ -> false
             end)
    end

    test "does not trigger breakeven if already stopped out" do
      strategy =
        ExitStrategy.fixed(Decimal.new("98.00"), Decimal.new("105.00"))
        |> ExitStrategy.with_breakeven(Decimal.new("1.0"))

      trade = create_trade()
      position = PositionState.new(trade, strategy)

      # Bar hits stop but also would trigger breakeven
      bar = create_bar(high: Decimal.new("103.00"), low: Decimal.new("97.00"))

      {position, stop_actions} = ExitManager.check_stop_hit(position, bar)
      assert [{:full_exit, :stopped_out, _}] = stop_actions

      {_position, actions} = ExitManager.check_breakeven_trigger({position, stop_actions}, bar)

      # Only the stop action, no breakeven
      assert length(actions) == 1
      assert {:full_exit, :stopped_out, _} = hd(actions)
    end

    test "breakeven trigger for short position" do
      strategy =
        ExitStrategy.fixed(Decimal.new("102.00"), Decimal.new("95.00"))
        |> ExitStrategy.with_breakeven(Decimal.new("1.0"), Decimal.new("0.10"))

      trade = create_trade(direction: :short)
      position = PositionState.new(trade, strategy)

      # Bar reaches 1R for short (entry 100, stop 102, so 1R = 98)
      bar = create_bar(low: Decimal.new("97.50"))

      {updated_position, actions} = ExitManager.process_bar(position, bar)

      assert Enum.any?(actions, fn
               {:update_stop, _} -> true
               _ -> false
             end)

      # Breakeven for short is entry - buffer
      assert Decimal.compare(updated_position.current_stop, Decimal.new("99.90")) == :eq
    end
  end

  # ============================================================================
  # Combined Scenarios
  # ============================================================================

  describe "process_bar/2 - combined scenarios" do
    test "trailing stop with breakeven" do
      strategy =
        ExitStrategy.trailing(
          Decimal.new("98.00"),
          type: :fixed_distance,
          value: Decimal.new("2.00")
        )
        |> ExitStrategy.with_breakeven(Decimal.new("1.0"))

      trade = create_trade()
      position = PositionState.new(trade, strategy)

      # First bar: trigger breakeven (1R at 102)
      bar1 = create_bar(high: Decimal.new("102.50"), low: Decimal.new("101.50"))
      {position, actions1} = ExitManager.process_bar(position, bar1)

      # Breakeven should have triggered
      assert position.stop_moved_to_breakeven == true

      assert Enum.any?(actions1, fn
               {:update_stop, _} -> true
               _ -> false
             end)

      # Second bar: trailing should continue from new high
      bar2 = create_bar(high: Decimal.new("105.00"), low: Decimal.new("104.00"))
      {position, _actions2} = ExitManager.process_bar(position, bar2)

      # Trailing stop should be at 103 (105 - 2)
      assert Decimal.compare(position.current_stop, Decimal.new("103.00")) == :eq
    end

    test "scaled exit with trailing on remainder" do
      # 50% at T1, remaining 50% has no target (will be trailed)
      strategy =
        ExitStrategy.scaled(Decimal.new("98.00"), [
          %{price: Decimal.new("102.00"), exit_percent: 50, move_stop_to: :breakeven},
          %{price: Decimal.new("110.00"), exit_percent: 50, move_stop_to: nil}
        ])
        |> ExitStrategy.with_trailing(type: :fixed_distance, value: Decimal.new("1.50"))

      trade = create_trade()
      position = PositionState.new(trade, strategy)

      # Bar 1: Hit T1, move to breakeven. Low stays above trailing stop level.
      # With high=103 and trail=1.5, trailing stop would be 101.50.
      # Keep low above that to not trigger the stop yet.
      bar1 = create_bar(high: Decimal.new("103.00"), low: Decimal.new("102.00"))
      {position, actions1} = ExitManager.process_bar(position, bar1)

      assert Enum.any?(actions1, fn
               {:partial_exit, 0, 50, _} -> true
               _ -> false
             end)

      assert position.stop_moved_to_breakeven == true
      assert position.remaining_size == 50

      # Bar 2: Price rises, trailing should kick in
      bar2 = create_bar(high: Decimal.new("106.00"), low: Decimal.new("105.00"))
      {position, _actions2} = ExitManager.process_bar(position, bar2)

      # Trailing stop should be at 104.50 (106 - 1.5)
      assert Decimal.compare(position.current_stop, Decimal.new("104.50")) == :eq
    end
  end

  # ============================================================================
  # Query Functions
  # ============================================================================

  describe "stop_triggered?/2" do
    test "returns true when stop exactly touched for long" do
      strategy = ExitStrategy.fixed(Decimal.new("98.00"), nil)
      trade = create_trade()
      position = PositionState.new(trade, strategy)

      bar = create_bar(low: Decimal.new("98.00"))
      assert ExitManager.stop_triggered?(position, bar) == true
    end

    test "returns false when stop not reached for long" do
      strategy = ExitStrategy.fixed(Decimal.new("98.00"), nil)
      trade = create_trade()
      position = PositionState.new(trade, strategy)

      bar = create_bar(low: Decimal.new("98.50"))
      assert ExitManager.stop_triggered?(position, bar) == false
    end
  end

  describe "target_reached?/3" do
    test "returns true when target reached for long" do
      strategy = ExitStrategy.fixed(Decimal.new("98.00"), Decimal.new("105.00"))
      trade = create_trade()
      position = PositionState.new(trade, strategy)

      bar = create_bar(high: Decimal.new("105.00"))
      assert ExitManager.target_reached?(position, bar, Decimal.new("105.00")) == true
    end

    test "returns false when target not reached for long" do
      strategy = ExitStrategy.fixed(Decimal.new("98.00"), Decimal.new("105.00"))
      trade = create_trade()
      position = PositionState.new(trade, strategy)

      bar = create_bar(high: Decimal.new("104.50"))
      assert ExitManager.target_reached?(position, bar, Decimal.new("105.00")) == false
    end
  end
end
