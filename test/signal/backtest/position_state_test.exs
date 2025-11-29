defmodule Signal.Backtest.PositionStateTest do
  use ExUnit.Case, async: true

  alias Signal.Backtest.PositionState
  alias Signal.Backtest.ExitStrategy

  # Helper to create a basic trade map
  defp create_trade(overrides \\ %{}) do
    Map.merge(
      %{
        id: "trade-123",
        symbol: "AAPL",
        direction: :long,
        entry_price: Decimal.new("175.00"),
        entry_time: ~U[2024-01-15 09:45:00Z],
        position_size: 100
      },
      overrides
    )
  end

  # Helper to create a basic bar map
  defp create_bar(overrides) do
    Map.merge(
      %{
        symbol: "AAPL",
        bar_time: ~U[2024-01-15 09:46:00Z],
        open: Decimal.new("175.10"),
        high: Decimal.new("175.50"),
        low: Decimal.new("174.80"),
        close: Decimal.new("175.30"),
        volume: 10000
      },
      overrides
    )
  end

  describe "new/2" do
    test "creates position state from trade and fixed strategy" do
      trade = create_trade()
      strategy = ExitStrategy.fixed(Decimal.new("174.00"), Decimal.new("177.00"))

      position = PositionState.new(trade, strategy)

      assert position.trade_id == "trade-123"
      assert position.symbol == "AAPL"
      assert position.direction == :long
      assert position.entry_price == Decimal.new("175.00")
      assert position.entry_time == ~U[2024-01-15 09:45:00Z]
      assert position.original_size == 100
      assert position.remaining_size == 100
      assert position.current_stop == Decimal.new("174.00")
      assert position.initial_stop == Decimal.new("174.00")
      assert position.highest_price == Decimal.new("175.00")
      assert position.lowest_price == Decimal.new("175.00")
      assert position.targets_hit == []
      assert position.partial_exits == []
      assert position.stop_moved_to_breakeven == false
    end

    test "calculates risk per share for long position" do
      trade = create_trade(%{direction: :long, entry_price: Decimal.new("175.00")})
      strategy = ExitStrategy.fixed(Decimal.new("174.00"), Decimal.new("177.00"))

      position = PositionState.new(trade, strategy)

      # Risk = entry - stop = 175 - 174 = 1.00
      assert position.risk_per_share == Decimal.new("1.00")
    end

    test "calculates risk per share for short position" do
      trade = create_trade(%{direction: :short, entry_price: Decimal.new("175.00")})
      strategy = ExitStrategy.fixed(Decimal.new("176.00"), Decimal.new("173.00"))

      position = PositionState.new(trade, strategy)

      # Risk = stop - entry = 176 - 175 = 1.00
      assert position.risk_per_share == Decimal.new("1.00")
    end

    test "initializes max R values to zero" do
      trade = create_trade()
      strategy = ExitStrategy.fixed(Decimal.new("174.00"), Decimal.new("177.00"))

      position = PositionState.new(trade, strategy)

      assert position.max_favorable_r == Decimal.new(0)
      assert position.max_adverse_r == Decimal.new(0)
    end

    test "stores the exit strategy" do
      trade = create_trade()

      strategy =
        ExitStrategy.trailing(Decimal.new("174.00"),
          type: :fixed_distance,
          value: Decimal.new("0.50")
        )

      position = PositionState.new(trade, strategy)

      assert position.exit_strategy == strategy
      assert position.exit_strategy.trailing_config.type == :fixed_distance
    end
  end

  describe "update/2 - price extremes" do
    test "updates highest price for long position" do
      trade = create_trade(%{direction: :long})
      strategy = ExitStrategy.fixed(Decimal.new("174.00"), Decimal.new("177.00"))
      position = PositionState.new(trade, strategy)

      bar = create_bar(%{high: Decimal.new("176.50"), low: Decimal.new("175.00")})
      updated = PositionState.update(position, bar)

      assert updated.highest_price == Decimal.new("176.50")
      assert updated.lowest_price == Decimal.new("175.00")
    end

    test "updates lowest price for short position" do
      trade = create_trade(%{direction: :short, entry_price: Decimal.new("175.00")})
      strategy = ExitStrategy.fixed(Decimal.new("176.00"), Decimal.new("173.00"))
      position = PositionState.new(trade, strategy)

      bar = create_bar(%{high: Decimal.new("175.50"), low: Decimal.new("174.00")})
      updated = PositionState.update(position, bar)

      assert updated.lowest_price == Decimal.new("174.00")
      assert updated.highest_price == Decimal.new("175.50")
    end

    test "only updates extremes in favorable direction" do
      trade = create_trade()
      strategy = ExitStrategy.fixed(Decimal.new("174.00"), Decimal.new("177.00"))
      position = PositionState.new(trade, strategy)

      # First bar goes up
      bar1 = create_bar(%{high: Decimal.new("176.00"), low: Decimal.new("175.00")})
      position = PositionState.update(position, bar1)
      assert position.highest_price == Decimal.new("176.00")

      # Second bar doesn't exceed high
      bar2 = create_bar(%{high: Decimal.new("175.80"), low: Decimal.new("175.20")})
      position = PositionState.update(position, bar2)
      assert position.highest_price == Decimal.new("176.00")

      # Third bar exceeds high
      bar3 = create_bar(%{high: Decimal.new("177.00"), low: Decimal.new("176.50")})
      position = PositionState.update(position, bar3)
      assert position.highest_price == Decimal.new("177.00")
    end
  end

  describe "update/2 - R excursions" do
    test "tracks max favorable R for long position" do
      trade = create_trade(%{direction: :long, entry_price: Decimal.new("175.00")})
      strategy = ExitStrategy.fixed(Decimal.new("174.00"), Decimal.new("177.00"))
      position = PositionState.new(trade, strategy)

      # Bar goes to 176.00 = 1R profit (risk is $1)
      bar = create_bar(%{high: Decimal.new("176.00"), low: Decimal.new("175.00")})
      updated = PositionState.update(position, bar)

      assert Decimal.compare(updated.max_favorable_r, Decimal.new("1.0")) == :eq
    end

    test "tracks max adverse R for long position" do
      trade = create_trade(%{direction: :long, entry_price: Decimal.new("175.00")})
      strategy = ExitStrategy.fixed(Decimal.new("174.00"), Decimal.new("177.00"))
      position = PositionState.new(trade, strategy)

      # Bar drops to 174.50 = -0.5R (risk is $1)
      bar = create_bar(%{high: Decimal.new("175.00"), low: Decimal.new("174.50")})
      updated = PositionState.update(position, bar)

      assert Decimal.compare(updated.max_adverse_r, Decimal.new("-0.5")) == :eq
    end

    test "tracks max favorable R for short position" do
      trade = create_trade(%{direction: :short, entry_price: Decimal.new("175.00")})
      strategy = ExitStrategy.fixed(Decimal.new("176.00"), Decimal.new("173.00"))
      position = PositionState.new(trade, strategy)

      # Bar drops to 174.00 = 1R profit for short
      bar = create_bar(%{high: Decimal.new("175.00"), low: Decimal.new("174.00")})
      updated = PositionState.update(position, bar)

      assert Decimal.compare(updated.max_favorable_r, Decimal.new("1.0")) == :eq
    end

    test "accumulates max R over multiple bars" do
      trade = create_trade(%{direction: :long, entry_price: Decimal.new("175.00")})
      strategy = ExitStrategy.fixed(Decimal.new("174.00"), Decimal.new("177.00"))
      position = PositionState.new(trade, strategy)

      # First bar: 1R profit
      bar1 = create_bar(%{high: Decimal.new("176.00"), low: Decimal.new("175.00")})
      position = PositionState.update(position, bar1)
      assert Decimal.compare(position.max_favorable_r, Decimal.new("1.0")) == :eq

      # Second bar: 2R profit
      bar2 = create_bar(%{high: Decimal.new("177.00"), low: Decimal.new("176.00")})
      position = PositionState.update(position, bar2)
      assert Decimal.compare(position.max_favorable_r, Decimal.new("2.0")) == :eq

      # Third bar: pulls back, max should stay at 2R
      bar3 = create_bar(%{high: Decimal.new("176.50"), low: Decimal.new("175.50")})
      position = PositionState.update(position, bar3)
      assert Decimal.compare(position.max_favorable_r, Decimal.new("2.0")) == :eq
    end
  end

  describe "update/2 - trailing stop" do
    test "does not trail when no trailing config" do
      trade = create_trade()
      strategy = ExitStrategy.fixed(Decimal.new("174.00"), Decimal.new("177.00"))
      position = PositionState.new(trade, strategy)

      bar = create_bar(%{high: Decimal.new("178.00"), low: Decimal.new("177.00")})
      updated = PositionState.update(position, bar)

      # Stop should not move
      assert updated.current_stop == Decimal.new("174.00")
    end

    test "trails stop with fixed distance" do
      trade = create_trade(%{direction: :long, entry_price: Decimal.new("175.00")})

      strategy =
        ExitStrategy.trailing(Decimal.new("174.00"),
          type: :fixed_distance,
          value: Decimal.new("0.50")
        )

      position = PositionState.new(trade, strategy)

      # Price moves to 176.00, trail should be 176.00 - 0.50 = 175.50
      bar = create_bar(%{high: Decimal.new("176.00"), low: Decimal.new("175.50")})
      updated = PositionState.update(position, bar)

      assert updated.current_stop == Decimal.new("175.50")
    end

    test "trails stop with percent" do
      trade = create_trade(%{direction: :long, entry_price: Decimal.new("100.00")})

      strategy =
        ExitStrategy.trailing(Decimal.new("99.00"), type: :percent, value: Decimal.new("0.01"))

      position = PositionState.new(trade, strategy)

      # Price moves to 102.00, trail should be 102.00 - 1% = 102.00 - 1.02 = 100.98
      bar = create_bar(%{high: Decimal.new("102.00"), low: Decimal.new("101.00")})
      updated = PositionState.update(position, bar)

      assert Decimal.equal?(updated.current_stop, Decimal.new("100.98"))
    end

    test "trail stop only moves up for long" do
      trade = create_trade(%{direction: :long, entry_price: Decimal.new("175.00")})

      strategy =
        ExitStrategy.trailing(Decimal.new("174.00"),
          type: :fixed_distance,
          value: Decimal.new("0.50")
        )

      position = PositionState.new(trade, strategy)

      # First bar: price to 176, stop to 175.50
      bar1 = create_bar(%{high: Decimal.new("176.00"), low: Decimal.new("175.00")})
      position = PositionState.update(position, bar1)
      assert position.current_stop == Decimal.new("175.50")

      # Second bar: price drops, stop should NOT move down
      bar2 = create_bar(%{high: Decimal.new("175.50"), low: Decimal.new("175.00")})
      position = PositionState.update(position, bar2)
      assert position.current_stop == Decimal.new("175.50")
    end

    test "trail stop only moves down for short" do
      trade = create_trade(%{direction: :short, entry_price: Decimal.new("175.00")})

      strategy =
        ExitStrategy.trailing(Decimal.new("176.00"),
          type: :fixed_distance,
          value: Decimal.new("0.50")
        )

      position = PositionState.new(trade, strategy)

      # First bar: price drops to 174, stop to 174.50
      bar1 = create_bar(%{high: Decimal.new("175.00"), low: Decimal.new("174.00")})
      position = PositionState.update(position, bar1)
      assert position.current_stop == Decimal.new("174.50")

      # Second bar: price rises, stop should NOT move up
      bar2 = create_bar(%{high: Decimal.new("175.00"), low: Decimal.new("174.50")})
      position = PositionState.update(position, bar2)
      assert position.current_stop == Decimal.new("174.50")
    end

    test "respects activation_r threshold" do
      trade = create_trade(%{direction: :long, entry_price: Decimal.new("175.00")})

      strategy =
        ExitStrategy.trailing(
          Decimal.new("174.00"),
          type: :fixed_distance,
          value: Decimal.new("0.50"),
          activation_r: Decimal.new("1.0")
        )

      position = PositionState.new(trade, strategy)

      # Bar at 0.5R - should not start trailing
      bar1 = create_bar(%{high: Decimal.new("175.50"), low: Decimal.new("175.00")})
      position = PositionState.update(position, bar1)
      # Unchanged
      assert position.current_stop == Decimal.new("174.00")

      # Bar at 1R - should start trailing
      bar2 = create_bar(%{high: Decimal.new("176.00"), low: Decimal.new("175.50")})
      position = PositionState.update(position, bar2)
      # Now trailing
      assert position.current_stop == Decimal.new("175.50")
    end
  end

  describe "update/3 - with ATR" do
    test "uses ATR for atr_multiple trailing" do
      trade = create_trade(%{direction: :long, entry_price: Decimal.new("175.00")})

      strategy =
        ExitStrategy.trailing(Decimal.new("174.00"),
          type: :atr_multiple,
          value: Decimal.new("2.0")
        )

      position = PositionState.new(trade, strategy)

      # Price to 177, with ATR of 0.50, trail should be 177 - (2 * 0.50) = 176.00
      bar = create_bar(%{high: Decimal.new("177.00"), low: Decimal.new("176.00")})
      atr = Decimal.new("0.50")
      updated = PositionState.update(position, bar, atr)

      assert Decimal.equal?(updated.current_stop, Decimal.new("176.00"))
    end
  end

  describe "move_to_breakeven/2" do
    test "moves stop to entry plus buffer for long" do
      trade = create_trade(%{direction: :long, entry_price: Decimal.new("175.00")})
      strategy = ExitStrategy.fixed(Decimal.new("174.00"), Decimal.new("177.00"))
      position = PositionState.new(trade, strategy)

      updated = PositionState.move_to_breakeven(position, Decimal.new("0.10"))

      assert updated.current_stop == Decimal.new("175.10")
      assert updated.stop_moved_to_breakeven == true
    end

    test "moves stop to entry minus buffer for short" do
      trade = create_trade(%{direction: :short, entry_price: Decimal.new("175.00")})
      strategy = ExitStrategy.fixed(Decimal.new("176.00"), Decimal.new("173.00"))
      position = PositionState.new(trade, strategy)

      updated = PositionState.move_to_breakeven(position, Decimal.new("0.10"))

      assert updated.current_stop == Decimal.new("174.90")
      assert updated.stop_moved_to_breakeven == true
    end

    test "uses default buffer when not specified" do
      trade = create_trade(%{direction: :long, entry_price: Decimal.new("175.00")})
      strategy = ExitStrategy.fixed(Decimal.new("174.00"), Decimal.new("177.00"))
      position = PositionState.new(trade, strategy)

      updated = PositionState.move_to_breakeven(position)

      assert updated.current_stop == Decimal.new("175.05")
    end

    test "uses buffer from exit strategy breakeven_config" do
      trade = create_trade(%{direction: :long, entry_price: Decimal.new("175.00")})

      strategy =
        ExitStrategy.fixed(Decimal.new("174.00"), Decimal.new("177.00"))
        |> ExitStrategy.with_breakeven(Decimal.new("1.0"), Decimal.new("0.20"))

      position = PositionState.new(trade, strategy)

      updated = PositionState.move_to_breakeven(position)

      assert updated.current_stop == Decimal.new("175.20")
    end

    test "does not move stop backwards" do
      trade = create_trade(%{direction: :long, entry_price: Decimal.new("175.00")})

      strategy =
        ExitStrategy.trailing(Decimal.new("174.00"),
          type: :fixed_distance,
          value: Decimal.new("0.50")
        )

      position = PositionState.new(trade, strategy)

      # Trail stop up to 176.50
      bar = create_bar(%{high: Decimal.new("177.00"), low: Decimal.new("176.50")})
      position = PositionState.update(position, bar)
      assert position.current_stop == Decimal.new("176.50")

      # Try to move to breakeven (175.05) - should not move backwards
      updated = PositionState.move_to_breakeven(position)
      assert updated.current_stop == Decimal.new("176.50")
      assert updated.stop_moved_to_breakeven == true
    end
  end

  describe "move_stop_to/2" do
    test "moves stop to specified price for long" do
      trade = create_trade(%{direction: :long})
      strategy = ExitStrategy.fixed(Decimal.new("174.00"), Decimal.new("177.00"))
      position = PositionState.new(trade, strategy)

      updated = PositionState.move_stop_to(position, Decimal.new("175.50"))

      assert updated.current_stop == Decimal.new("175.50")
    end

    test "does not move stop backwards for long" do
      trade = create_trade(%{direction: :long})
      strategy = ExitStrategy.fixed(Decimal.new("174.00"), Decimal.new("177.00"))
      position = PositionState.new(trade, strategy)

      # First move up
      position = PositionState.move_stop_to(position, Decimal.new("175.00"))
      assert position.current_stop == Decimal.new("175.00")

      # Try to move down - should not work
      position = PositionState.move_stop_to(position, Decimal.new("174.50"))
      assert position.current_stop == Decimal.new("175.00")
    end

    test "does not move stop upwards for short" do
      trade = create_trade(%{direction: :short})
      strategy = ExitStrategy.fixed(Decimal.new("176.00"), Decimal.new("173.00"))
      position = PositionState.new(trade, strategy)

      # First move down
      position = PositionState.move_stop_to(position, Decimal.new("175.50"))
      assert position.current_stop == Decimal.new("175.50")

      # Try to move up - should not work
      position = PositionState.move_stop_to(position, Decimal.new("175.80"))
      assert position.current_stop == Decimal.new("175.50")
    end
  end

  describe "record_partial_exit/2" do
    test "records partial exit and updates remaining size" do
      trade = create_trade(%{position_size: 100})

      strategy =
        ExitStrategy.scaled(Decimal.new("174.00"), [
          %{price: Decimal.new("176.00"), exit_percent: 50, move_stop_to: :breakeven},
          %{price: Decimal.new("178.00"), exit_percent: 50, move_stop_to: nil}
        ])

      position = PositionState.new(trade, strategy)

      exit_record = %{
        exit_time: ~U[2024-01-15 10:00:00Z],
        exit_price: Decimal.new("176.00"),
        shares_exited: 50,
        target_index: 0,
        reason: :target_1
      }

      updated = PositionState.record_partial_exit(position, exit_record)

      assert updated.remaining_size == 50
      assert length(updated.partial_exits) == 1
      assert 0 in updated.targets_hit
    end

    test "calculates P&L for partial exit" do
      trade =
        create_trade(%{direction: :long, entry_price: Decimal.new("175.00"), position_size: 100})

      strategy = ExitStrategy.fixed(Decimal.new("174.00"), Decimal.new("177.00"))
      position = PositionState.new(trade, strategy)

      exit_record = %{
        exit_time: ~U[2024-01-15 10:00:00Z],
        exit_price: Decimal.new("176.00"),
        shares_exited: 50,
        reason: :target_1
      }

      updated = PositionState.record_partial_exit(position, exit_record)

      [partial] = updated.partial_exits
      # P&L = (176 - 175) * 50 = 50.00
      assert Decimal.equal?(partial.pnl, Decimal.new("50.00"))
      # R = 50 / (1.00 * 50) = 1.0
      assert Decimal.equal?(partial.r_multiple, Decimal.new("1.0"))
    end

    test "records multiple partial exits" do
      trade = create_trade(%{position_size: 100})

      strategy =
        ExitStrategy.scaled(Decimal.new("174.00"), [
          %{price: Decimal.new("176.00"), exit_percent: 50, move_stop_to: :breakeven},
          %{price: Decimal.new("178.00"), exit_percent: 50, move_stop_to: nil}
        ])

      position = PositionState.new(trade, strategy)

      # First partial exit
      position =
        PositionState.record_partial_exit(position, %{
          exit_time: ~U[2024-01-15 10:00:00Z],
          exit_price: Decimal.new("176.00"),
          shares_exited: 50,
          target_index: 0,
          reason: :target_1
        })

      assert position.remaining_size == 50
      assert 0 in position.targets_hit

      # Second partial exit
      position =
        PositionState.record_partial_exit(position, %{
          exit_time: ~U[2024-01-15 10:30:00Z],
          exit_price: Decimal.new("178.00"),
          shares_exited: 50,
          target_index: 1,
          reason: :target_2
        })

      assert position.remaining_size == 0
      assert 0 in position.targets_hit
      assert 1 in position.targets_hit
      assert length(position.partial_exits) == 2
    end
  end

  describe "mark_target_hit/2" do
    test "marks target as hit" do
      trade = create_trade()

      strategy =
        ExitStrategy.scaled(Decimal.new("174.00"), [
          %{price: Decimal.new("176.00"), exit_percent: 50, move_stop_to: nil},
          %{price: Decimal.new("178.00"), exit_percent: 50, move_stop_to: nil}
        ])

      position = PositionState.new(trade, strategy)

      updated = PositionState.mark_target_hit(position, 0)

      assert 0 in updated.targets_hit
    end

    test "does not duplicate target hits" do
      trade = create_trade()

      strategy =
        ExitStrategy.scaled(Decimal.new("174.00"), [
          %{price: Decimal.new("176.00"), exit_percent: 100, move_stop_to: nil}
        ])

      position = PositionState.new(trade, strategy)

      position = PositionState.mark_target_hit(position, 0)
      position = PositionState.mark_target_hit(position, 0)

      assert position.targets_hit == [0]
    end
  end

  describe "query functions" do
    test "fully_closed?/1" do
      trade = create_trade(%{position_size: 100})
      strategy = ExitStrategy.fixed(Decimal.new("174.00"), Decimal.new("177.00"))
      position = PositionState.new(trade, strategy)

      refute PositionState.fully_closed?(position)

      # Exit all shares
      position =
        PositionState.record_partial_exit(position, %{
          exit_time: ~U[2024-01-15 10:00:00Z],
          exit_price: Decimal.new("176.00"),
          shares_exited: 100,
          reason: :target_hit
        })

      assert PositionState.fully_closed?(position)
    end

    test "target_hit?/2" do
      trade = create_trade()

      strategy =
        ExitStrategy.scaled(Decimal.new("174.00"), [
          %{price: Decimal.new("176.00"), exit_percent: 50, move_stop_to: nil},
          %{price: Decimal.new("178.00"), exit_percent: 50, move_stop_to: nil}
        ])

      position = PositionState.new(trade, strategy)

      refute PositionState.target_hit?(position, 0)
      refute PositionState.target_hit?(position, 1)

      position = PositionState.mark_target_hit(position, 0)

      assert PositionState.target_hit?(position, 0)
      refute PositionState.target_hit?(position, 1)
    end

    test "partial_exit_count/1" do
      trade = create_trade(%{position_size: 100})
      strategy = ExitStrategy.fixed(Decimal.new("174.00"), Decimal.new("177.00"))
      position = PositionState.new(trade, strategy)

      assert PositionState.partial_exit_count(position) == 0

      position =
        PositionState.record_partial_exit(position, %{
          exit_time: ~U[2024-01-15 10:00:00Z],
          exit_price: Decimal.new("176.00"),
          shares_exited: 50,
          reason: :target_1
        })

      assert PositionState.partial_exit_count(position) == 1
    end

    test "realized_pnl/1" do
      trade =
        create_trade(%{direction: :long, entry_price: Decimal.new("175.00"), position_size: 100})

      strategy = ExitStrategy.fixed(Decimal.new("174.00"), Decimal.new("177.00"))
      position = PositionState.new(trade, strategy)

      assert PositionState.realized_pnl(position) == Decimal.new(0)

      # Exit 50 shares at $1 profit each = $50
      position =
        PositionState.record_partial_exit(position, %{
          exit_time: ~U[2024-01-15 10:00:00Z],
          exit_price: Decimal.new("176.00"),
          shares_exited: 50,
          reason: :target_1
        })

      assert PositionState.realized_pnl(position) == Decimal.new("50.00")

      # Exit 50 more at $2 profit each = $100
      position =
        PositionState.record_partial_exit(position, %{
          exit_time: ~U[2024-01-15 10:30:00Z],
          exit_price: Decimal.new("177.00"),
          shares_exited: 50,
          reason: :target_2
        })

      assert PositionState.realized_pnl(position) == Decimal.new("150.00")
    end

    test "unrealized_pnl/2" do
      trade =
        create_trade(%{direction: :long, entry_price: Decimal.new("175.00"), position_size: 100})

      strategy = ExitStrategy.fixed(Decimal.new("174.00"), Decimal.new("177.00"))
      position = PositionState.new(trade, strategy)

      # Current price at 176 = $1 * 100 shares = $100
      pnl = PositionState.unrealized_pnl(position, Decimal.new("176.00"))
      assert pnl == Decimal.new("100.00")

      # After partial exit of 50 shares
      position =
        PositionState.record_partial_exit(position, %{
          exit_time: ~U[2024-01-15 10:00:00Z],
          exit_price: Decimal.new("176.00"),
          shares_exited: 50,
          reason: :target_1
        })

      # Unrealized on remaining 50 shares at 177 = $2 * 50 = $100
      pnl = PositionState.unrealized_pnl(position, Decimal.new("177.00"))
      assert pnl == Decimal.new("100.00")
    end

    test "current_r/2" do
      trade = create_trade(%{direction: :long, entry_price: Decimal.new("175.00")})
      strategy = ExitStrategy.fixed(Decimal.new("174.00"), Decimal.new("177.00"))
      position = PositionState.new(trade, strategy)

      # At entry
      assert Decimal.equal?(
               PositionState.current_r(position, Decimal.new("175.00")),
               Decimal.new("0")
             )

      # At 1R profit
      assert Decimal.equal?(
               PositionState.current_r(position, Decimal.new("176.00")),
               Decimal.new("1.0")
             )

      # At 2R profit
      assert Decimal.equal?(
               PositionState.current_r(position, Decimal.new("177.00")),
               Decimal.new("2.0")
             )

      # At 0.5R loss
      assert Decimal.equal?(
               PositionState.current_r(position, Decimal.new("174.50")),
               Decimal.new("-0.5")
             )
    end

    test "shares_for_percent/2" do
      trade = create_trade(%{position_size: 100})
      strategy = ExitStrategy.fixed(Decimal.new("174.00"), Decimal.new("177.00"))
      position = PositionState.new(trade, strategy)

      assert PositionState.shares_for_percent(position, 50) == 50
      assert PositionState.shares_for_percent(position, 33) == 33
      assert PositionState.shares_for_percent(position, 100) == 100
    end

    test "next_target/1" do
      trade = create_trade()

      strategy =
        ExitStrategy.scaled(Decimal.new("174.00"), [
          %{price: Decimal.new("176.00"), exit_percent: 50, move_stop_to: :breakeven},
          %{price: Decimal.new("178.00"), exit_percent: 50, move_stop_to: nil}
        ])

      position = PositionState.new(trade, strategy)

      {idx, target} = PositionState.next_target(position)
      assert idx == 0
      assert target.price == Decimal.new("176.00")

      # After hitting first target
      position = PositionState.mark_target_hit(position, 0)
      {idx, target} = PositionState.next_target(position)
      assert idx == 1
      assert target.price == Decimal.new("178.00")

      # After hitting all targets
      position = PositionState.mark_target_hit(position, 1)
      assert PositionState.next_target(position) == nil
    end

    test "next_target/1 returns nil for fixed strategy" do
      trade = create_trade()
      strategy = ExitStrategy.fixed(Decimal.new("174.00"))
      position = PositionState.new(trade, strategy)

      assert PositionState.next_target(position) == nil
    end

    test "to_summary/1" do
      trade = create_trade()

      strategy =
        ExitStrategy.scaled(Decimal.new("174.00"), [
          %{price: Decimal.new("176.00"), exit_percent: 100, move_stop_to: nil}
        ])
        |> ExitStrategy.with_trailing(type: :fixed_distance, value: Decimal.new("0.50"))

      position = PositionState.new(trade, strategy)

      # Update to get some state
      bar = create_bar(%{high: Decimal.new("177.00"), low: Decimal.new("175.00")})
      position = PositionState.update(position, bar)
      position = PositionState.move_to_breakeven(position)

      summary = PositionState.to_summary(position)

      assert summary.trade_id == "trade-123"
      assert summary.symbol == "AAPL"
      assert summary.direction == :long
      assert summary.stop_moved_to_breakeven == true
      assert summary.exit_strategy_type == "combined"
      assert Decimal.compare(summary.max_favorable_r, Decimal.new(0)) == :gt
    end
  end
end
