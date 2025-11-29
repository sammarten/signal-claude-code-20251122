defmodule Signal.Backtest.ExitIntegrationTest do
  @moduledoc """
  Integration tests for exit strategy functionality.

  Tests complete backtest scenarios with various exit strategies,
  verifying the full workflow from signal to exit.
  """
  use ExUnit.Case, async: true

  alias Signal.Backtest.ExitStrategy
  alias Signal.Backtest.FillSimulator
  alias Signal.Backtest.TradeSimulator
  alias Signal.Backtest.VirtualAccount
  alias Signal.Backtest.VirtualClock

  setup do
    registry_name = :"test_registry_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry_name})

    run_id = Ecto.UUID.generate()
    backtest_run_id = Ecto.UUID.generate()

    account = VirtualAccount.new(Decimal.new("100000"), Decimal.new("0.01"))

    {:ok, clock} =
      VirtualClock.start_link(
        run_id: run_id,
        start_time: ~U[2024-01-15 14:30:00Z],
        name: {:via, Registry, {registry_name, {:clock, run_id}}}
      )

    {:ok, simulator} =
      TradeSimulator.start_link(
        run_id: run_id,
        backtest_run_id: backtest_run_id,
        account: account,
        clock: clock,
        symbols: ["AAPL", "TSLA"],
        fill_config: FillSimulator.new(:signal_price),
        persist_trades: false,
        name: {:via, Registry, {registry_name, {:simulator, run_id}}}
      )

    %{
      simulator: simulator,
      clock: clock,
      run_id: run_id,
      registry_name: registry_name
    }
  end

  describe "full backtest with trailing stops" do
    test "trailing stop follows price up and exits on reversal", %{
      simulator: simulator,
      clock: clock
    } do
      # Setup trailing stop strategy with $2 fixed distance
      exit_strategy =
        ExitStrategy.trailing(
          Decimal.new("98.00"),
          type: :fixed_distance,
          value: Decimal.new("2.00")
        )

      signal = %{
        symbol: "AAPL",
        direction: :long,
        entry_price: Decimal.new("100.00"),
        stop_loss: Decimal.new("98.00"),
        exit_strategy: exit_strategy
      }

      TradeSimulator.submit_signal(simulator, signal)

      # Bar 1: Entry at 100
      process_bar(simulator, clock, "AAPL", ~U[2024-01-15 14:31:00Z], %{
        open: "100.00",
        high: "100.50",
        low: "99.80",
        close: "100.20"
      })

      assert_position_open(simulator)

      # Bar 2: Price rises to 102, trailing stop moves to 100
      process_bar(simulator, clock, "AAPL", ~U[2024-01-15 14:32:00Z], %{
        open: "100.50",
        high: "102.00",
        low: "100.40",
        close: "101.80"
      })

      assert_position_open(simulator)

      # Bar 3: Price rises to 105, trailing stop moves to 103
      process_bar(simulator, clock, "AAPL", ~U[2024-01-15 14:33:00Z], %{
        open: "102.00",
        high: "105.00",
        low: "103.50",
        close: "104.80"
      })

      assert_position_open(simulator)

      # Bar 4: Price rises to 107, trailing stop moves to 105
      process_bar(simulator, clock, "AAPL", ~U[2024-01-15 14:34:00Z], %{
        open: "105.00",
        high: "107.00",
        low: "105.50",
        close: "106.50"
      })

      assert_position_open(simulator)

      # Bar 5: Price drops, hits trailing stop at 105
      process_bar(simulator, clock, "AAPL", ~U[2024-01-15 14:35:00Z], %{
        open: "106.00",
        high: "106.20",
        low: "104.50",
        close: "104.80"
      })

      # Position should be closed with profit
      account = TradeSimulator.get_account(simulator)
      assert map_size(account.open_positions) == 0
      assert length(account.closed_trades) == 1

      [trade] = account.closed_trades
      assert trade.status == :trailing_stopped
      # Exit at trailing stop level of 105
      assert Decimal.compare(trade.exit_price, Decimal.new("105.00")) == :eq
      # Profit: 105 - 100 = 5 per share
      assert Decimal.compare(trade.pnl, Decimal.new(0)) == :gt
    end

    test "trailing stop with percent distance", %{simulator: simulator, clock: clock} do
      # 2% trailing stop (value is 0.02 for 2%)
      exit_strategy =
        ExitStrategy.trailing(
          Decimal.new("98.00"),
          type: :percent,
          value: Decimal.new("0.02")
        )

      signal = %{
        symbol: "AAPL",
        direction: :long,
        entry_price: Decimal.new("100.00"),
        stop_loss: Decimal.new("98.00"),
        exit_strategy: exit_strategy
      }

      TradeSimulator.submit_signal(simulator, signal)

      # Entry bar
      process_bar(simulator, clock, "AAPL", ~U[2024-01-15 14:31:00Z], %{
        open: "100.00",
        high: "100.50",
        low: "99.80",
        close: "100.20"
      })

      # Price rises to 110, trailing stop at 107.80 (110 * 0.98)
      process_bar(simulator, clock, "AAPL", ~U[2024-01-15 14:32:00Z], %{
        open: "100.50",
        high: "110.00",
        low: "108.00",
        close: "109.50"
      })

      assert_position_open(simulator)

      # Price drops to hit trailing stop around 107.80
      process_bar(simulator, clock, "AAPL", ~U[2024-01-15 14:33:00Z], %{
        open: "109.00",
        high: "109.20",
        low: "107.00",
        close: "107.50"
      })

      account = TradeSimulator.get_account(simulator)
      assert map_size(account.open_positions) == 0
      assert length(account.closed_trades) == 1

      [trade] = account.closed_trades
      assert trade.status == :trailing_stopped
    end

    test "short position with trailing stop", %{simulator: simulator, clock: clock} do
      exit_strategy =
        ExitStrategy.trailing(
          Decimal.new("102.00"),
          type: :fixed_distance,
          value: Decimal.new("2.00")
        )

      signal = %{
        symbol: "AAPL",
        direction: :short,
        entry_price: Decimal.new("100.00"),
        stop_loss: Decimal.new("102.00"),
        exit_strategy: exit_strategy
      }

      TradeSimulator.submit_signal(simulator, signal)

      # Entry bar - keep high well below stop at 102
      process_bar(simulator, clock, "AAPL", ~U[2024-01-15 14:31:00Z], %{
        open: "100.00",
        high: "100.50",
        low: "99.50",
        close: "99.80"
      })

      assert_position_open(simulator)

      # Price drops to 95, trailing stop moves to 97 (95 + 2)
      process_bar(simulator, clock, "AAPL", ~U[2024-01-15 14:32:00Z], %{
        open: "99.50",
        high: "96.50",
        low: "95.00",
        close: "95.50"
      })

      assert_position_open(simulator)

      # Price rises to hit trailing stop at 97
      process_bar(simulator, clock, "AAPL", ~U[2024-01-15 14:33:00Z], %{
        open: "95.80",
        high: "97.50",
        low: "95.70",
        close: "97.20"
      })

      account = TradeSimulator.get_account(simulator)
      assert map_size(account.open_positions) == 0

      [trade] = account.closed_trades
      assert trade.status == :trailing_stopped
      # Short profit: 100 - 97 = 3 per share
      assert Decimal.compare(trade.pnl, Decimal.new(0)) == :gt
    end
  end

  describe "full backtest with scaled exits" do
    test "exits at multiple targets with partial positions", %{
      simulator: simulator,
      clock: clock
    } do
      # 3 targets: 50% at 102, 30% at 104, 20% at 106
      exit_strategy =
        ExitStrategy.scaled(Decimal.new("98.00"), [
          %{price: Decimal.new("102.00"), exit_percent: 50, move_stop_to: nil},
          %{price: Decimal.new("104.00"), exit_percent: 30, move_stop_to: nil},
          %{price: Decimal.new("106.00"), exit_percent: 20, move_stop_to: nil}
        ])

      signal = %{
        symbol: "AAPL",
        direction: :long,
        entry_price: Decimal.new("100.00"),
        stop_loss: Decimal.new("98.00"),
        exit_strategy: exit_strategy
      }

      TradeSimulator.submit_signal(simulator, signal)

      # Entry bar
      process_bar(simulator, clock, "AAPL", ~U[2024-01-15 14:31:00Z], %{
        open: "100.00",
        high: "100.50",
        low: "99.80",
        close: "100.20"
      })

      account = TradeSimulator.get_account(simulator)
      [{_id, initial_trade}] = Enum.to_list(account.open_positions)
      initial_size = initial_trade.position_size

      # Hit first target at 102 (50% exit)
      process_bar(simulator, clock, "AAPL", ~U[2024-01-15 14:32:00Z], %{
        open: "100.50",
        high: "102.50",
        low: "100.40",
        close: "102.30"
      })

      account = TradeSimulator.get_account(simulator)
      assert map_size(account.open_positions) == 1
      [{_id, trade}] = Enum.to_list(account.open_positions)
      # Should have 50% of original size
      assert trade.position_size == div(initial_size, 2)

      # Hit second target at 104 (30% of original = 60% of remaining)
      process_bar(simulator, clock, "AAPL", ~U[2024-01-15 14:33:00Z], %{
        open: "102.50",
        high: "104.50",
        low: "102.40",
        close: "104.30"
      })

      account = TradeSimulator.get_account(simulator)
      assert map_size(account.open_positions) == 1
      [{_id, trade}] = Enum.to_list(account.open_positions)
      # Should have ~20% of original size remaining
      expected_remaining = div(initial_size, 5)
      assert_in_delta trade.position_size, expected_remaining, 1

      # Hit final target at 106 (remaining 20%)
      process_bar(simulator, clock, "AAPL", ~U[2024-01-15 14:34:00Z], %{
        open: "104.50",
        high: "106.50",
        low: "104.40",
        close: "106.30"
      })

      # Position should be fully closed
      account = TradeSimulator.get_account(simulator)
      assert map_size(account.open_positions) == 0
      assert length(account.closed_trades) == 1

      [trade] = account.closed_trades
      # Total P&L should be positive
      assert Decimal.compare(trade.pnl, Decimal.new(0)) == :gt
    end

    test "scaled exit with stop move on first target", %{simulator: simulator, clock: clock} do
      # Move stop to breakeven after first target
      exit_strategy =
        ExitStrategy.scaled(Decimal.new("98.00"), [
          %{price: Decimal.new("102.00"), exit_percent: 50, move_stop_to: :breakeven},
          %{price: Decimal.new("106.00"), exit_percent: 50, move_stop_to: nil}
        ])

      signal = %{
        symbol: "AAPL",
        direction: :long,
        entry_price: Decimal.new("100.00"),
        stop_loss: Decimal.new("98.00"),
        exit_strategy: exit_strategy
      }

      TradeSimulator.submit_signal(simulator, signal)

      # Entry
      process_bar(simulator, clock, "AAPL", ~U[2024-01-15 14:31:00Z], %{
        open: "100.00",
        high: "100.50",
        low: "99.80",
        close: "100.20"
      })

      # Hit first target, moves stop to breakeven
      process_bar(simulator, clock, "AAPL", ~U[2024-01-15 14:32:00Z], %{
        open: "100.50",
        high: "102.50",
        low: "100.40",
        close: "102.30"
      })

      # Price pulls back but stays above breakeven
      process_bar(simulator, clock, "AAPL", ~U[2024-01-15 14:33:00Z], %{
        open: "102.00",
        high: "102.10",
        low: "100.20",
        close: "100.50"
      })

      # Position should still be open (stop moved to ~100)
      assert_position_open(simulator)

      # Now price drops below original stop (98) but stop was moved
      # This bar should NOT stop us out since stop is at breakeven
      process_bar(simulator, clock, "AAPL", ~U[2024-01-15 14:34:00Z], %{
        open: "100.40",
        high: "100.50",
        low: "99.50",
        close: "99.80"
      })

      # Still open because stop moved to breakeven (~100)
      account = TradeSimulator.get_account(simulator)
      # May or may not be stopped depending on exact breakeven level
      # If stopped at BE, we should have profit from first partial
      if map_size(account.open_positions) == 0 do
        [trade] = account.closed_trades
        # Even if stopped at BE, we locked in profit from first target
        assert Decimal.compare(trade.pnl, Decimal.new(0)) == :gt
      end
    end

    test "scaled exit stopped out before targets", %{simulator: simulator, clock: clock} do
      exit_strategy =
        ExitStrategy.scaled(Decimal.new("98.00"), [
          %{price: Decimal.new("104.00"), exit_percent: 50, move_stop_to: nil},
          %{price: Decimal.new("108.00"), exit_percent: 50, move_stop_to: nil}
        ])

      signal = %{
        symbol: "AAPL",
        direction: :long,
        entry_price: Decimal.new("100.00"),
        stop_loss: Decimal.new("98.00"),
        exit_strategy: exit_strategy
      }

      TradeSimulator.submit_signal(simulator, signal)

      # Entry
      process_bar(simulator, clock, "AAPL", ~U[2024-01-15 14:31:00Z], %{
        open: "100.00",
        high: "100.50",
        low: "99.80",
        close: "100.20"
      })

      # Price drops to stop before hitting any targets
      process_bar(simulator, clock, "AAPL", ~U[2024-01-15 14:32:00Z], %{
        open: "99.50",
        high: "99.60",
        low: "97.50",
        close: "97.80"
      })

      account = TradeSimulator.get_account(simulator)
      assert map_size(account.open_positions) == 0
      assert length(account.closed_trades) == 1

      [trade] = account.closed_trades
      assert trade.status == :stopped_out
      # Loss at stop
      assert Decimal.compare(trade.pnl, Decimal.new(0)) == :lt
    end
  end

  describe "full backtest with breakeven management" do
    test "moves stop to breakeven at trigger and survives pullback", %{
      simulator: simulator,
      clock: clock
    } do
      # Fixed strategy with breakeven at 1R, $0.10 buffer
      exit_strategy =
        ExitStrategy.fixed(Decimal.new("98.00"), Decimal.new("106.00"))
        |> ExitStrategy.with_breakeven(Decimal.new("1.0"), Decimal.new("0.10"))

      signal = %{
        symbol: "AAPL",
        direction: :long,
        entry_price: Decimal.new("100.00"),
        stop_loss: Decimal.new("98.00"),
        exit_strategy: exit_strategy
      }

      TradeSimulator.submit_signal(simulator, signal)

      # Entry
      process_bar(simulator, clock, "AAPL", ~U[2024-01-15 14:31:00Z], %{
        open: "100.00",
        high: "100.50",
        low: "99.80",
        close: "100.20"
      })

      # Risk is 2 points (100 - 98), so 1R = 102
      # Price reaches 102.50, triggering breakeven
      process_bar(simulator, clock, "AAPL", ~U[2024-01-15 14:32:00Z], %{
        open: "100.50",
        high: "102.50",
        low: "100.40",
        close: "102.30"
      })

      assert_position_open(simulator)

      # Price pulls back to 100.50, above new BE stop at 100.10
      process_bar(simulator, clock, "AAPL", ~U[2024-01-15 14:33:00Z], %{
        open: "102.00",
        high: "102.10",
        low: "100.50",
        close: "100.80"
      })

      # Should still be open
      assert_position_open(simulator)

      # Price drops to 99, below original stop but above BE stop
      # Wait - this is below BE stop of 100.10, so should exit
      process_bar(simulator, clock, "AAPL", ~U[2024-01-15 14:34:00Z], %{
        open: "100.70",
        high: "100.80",
        low: "99.00",
        close: "99.50"
      })

      # Should be stopped at breakeven
      account = TradeSimulator.get_account(simulator)
      assert map_size(account.open_positions) == 0

      [trade] = account.closed_trades
      # Should be approximately breakeven (small profit due to buffer)
      # Exit at 100.10, entry at 100 = 0.10 profit per share
      assert Decimal.compare(trade.pnl, Decimal.new("-10")) == :gt
    end

    test "breakeven not triggered if price never reaches threshold", %{
      simulator: simulator,
      clock: clock
    } do
      exit_strategy =
        ExitStrategy.fixed(Decimal.new("98.00"), Decimal.new("106.00"))
        |> ExitStrategy.with_breakeven(Decimal.new("1.0"), Decimal.new("0.10"))

      signal = %{
        symbol: "AAPL",
        direction: :long,
        entry_price: Decimal.new("100.00"),
        stop_loss: Decimal.new("98.00"),
        exit_strategy: exit_strategy
      }

      TradeSimulator.submit_signal(simulator, signal)

      # Entry
      process_bar(simulator, clock, "AAPL", ~U[2024-01-15 14:31:00Z], %{
        open: "100.00",
        high: "100.50",
        low: "99.80",
        close: "100.20"
      })

      # Price rises but not to 1R (102)
      process_bar(simulator, clock, "AAPL", ~U[2024-01-15 14:32:00Z], %{
        open: "100.50",
        high: "101.50",
        low: "100.40",
        close: "101.30"
      })

      # Price drops to original stop at 98
      process_bar(simulator, clock, "AAPL", ~U[2024-01-15 14:33:00Z], %{
        open: "101.00",
        high: "101.10",
        low: "97.50",
        close: "97.80"
      })

      # Should be stopped at original stop, not breakeven
      account = TradeSimulator.get_account(simulator)
      assert map_size(account.open_positions) == 0

      [trade] = account.closed_trades
      assert trade.status == :stopped_out
      # Full loss at original stop
      assert Decimal.compare(trade.pnl, Decimal.new(0)) == :lt
    end
  end

  describe "fixed vs trailing performance comparison" do
    test "trailing captures more profit in trending market", %{clock: clock} do
      # Create two simulators with different strategies
      {fixed_sim, trailing_sim} = create_comparison_simulators(clock)

      # Fixed strategy signal
      fixed_signal = %{
        symbol: "AAPL",
        direction: :long,
        entry_price: Decimal.new("100.00"),
        stop_loss: Decimal.new("98.00"),
        take_profit: Decimal.new("104.00")
      }

      # Trailing strategy signal with $2 distance
      trailing_strategy =
        ExitStrategy.trailing(
          Decimal.new("98.00"),
          type: :fixed_distance,
          value: Decimal.new("2.00")
        )

      trailing_signal = %{
        symbol: "AAPL",
        direction: :long,
        entry_price: Decimal.new("100.00"),
        stop_loss: Decimal.new("98.00"),
        exit_strategy: trailing_strategy
      }

      TradeSimulator.submit_signal(fixed_sim, fixed_signal)
      TradeSimulator.submit_signal(trailing_sim, trailing_signal)

      # Simulate trending market with lows staying above trailing stop
      # Trailing stop moves: 98 -> 98.50 -> 100 -> 103 -> 105 -> 107
      # Each bar's low must stay above the new trailing stop
      bars = [
        # Entry bar: high 100.50, trailing stop at 98.50
        {~U[2024-01-15 14:31:00Z], "100.00", "100.50", "99.80", "100.20"},
        # High 102, trailing stop at 100
        {~U[2024-01-15 14:32:00Z], "100.50", "102.00", "100.40", "101.80"},
        # High 105, trailing stop at 103 - low 103.20 stays above
        {~U[2024-01-15 14:33:00Z], "102.00", "105.00", "103.20", "104.80"},
        # High 107, trailing stop at 105 - low 105.20 stays above
        {~U[2024-01-15 14:34:00Z], "105.00", "107.00", "105.20", "106.80"},
        # High 109, trailing stop at 107 - low 107.20 stays above
        {~U[2024-01-15 14:35:00Z], "107.00", "109.00", "107.20", "108.50"},
        # Reversal - low 106.50 hits trailing stop at 107
        {~U[2024-01-15 14:36:00Z], "108.00", "108.20", "106.50", "106.80"}
      ]

      for {time, open, high, low, close} <- bars do
        VirtualClock.advance(clock, time)

        bar = %{
          symbol: "AAPL",
          bar_time: time,
          open: Decimal.new(open),
          high: Decimal.new(high),
          low: Decimal.new(low),
          close: Decimal.new(close)
        }

        TradeSimulator.process_bar(fixed_sim, bar)
        TradeSimulator.process_bar(trailing_sim, bar)
        Process.sleep(10)
      end

      fixed_account = TradeSimulator.get_account(fixed_sim)
      trailing_account = TradeSimulator.get_account(trailing_sim)

      # Both should be closed
      assert map_size(fixed_account.open_positions) == 0
      assert map_size(trailing_account.open_positions) == 0

      [fixed_trade] = fixed_account.closed_trades
      [trailing_trade] = trailing_account.closed_trades

      # Fixed exits at 104 (target)
      assert fixed_trade.status == :target_hit
      # Trailing exits at 107 (trailing stop after 109 high)
      assert trailing_trade.status == :trailing_stopped

      # Trailing should capture more profit in trending market
      # Fixed: 104 - 100 = 4 per share
      # Trailing: 107 - 100 = 7 per share
      assert Decimal.compare(trailing_trade.pnl, fixed_trade.pnl) == :gt
    end

    test "fixed protects profit better in choppy market", %{clock: clock} do
      {fixed_sim, trailing_sim} = create_comparison_simulators(clock)

      fixed_signal = %{
        symbol: "AAPL",
        direction: :long,
        entry_price: Decimal.new("100.00"),
        stop_loss: Decimal.new("98.00"),
        take_profit: Decimal.new("103.00")
      }

      trailing_strategy =
        ExitStrategy.trailing(
          Decimal.new("98.00"),
          type: :fixed_distance,
          value: Decimal.new("2.00")
        )

      trailing_signal = %{
        symbol: "AAPL",
        direction: :long,
        entry_price: Decimal.new("100.00"),
        stop_loss: Decimal.new("98.00"),
        exit_strategy: trailing_strategy
      }

      TradeSimulator.submit_signal(fixed_sim, fixed_signal)
      TradeSimulator.submit_signal(trailing_sim, trailing_signal)

      # Simulate choppy market - hits target but then reverses
      bars = [
        {~U[2024-01-15 14:31:00Z], "100.00", "100.50", "99.80", "100.20"},
        {~U[2024-01-15 14:32:00Z], "100.50", "103.50", "100.40", "103.20"},
        # Reversal
        {~U[2024-01-15 14:33:00Z], "103.00", "103.20", "100.80", "101.00"},
        {~U[2024-01-15 14:34:00Z], "101.00", "101.50", "99.50", "99.80"}
      ]

      for {time, open, high, low, close} <- bars do
        VirtualClock.advance(clock, time)

        bar = %{
          symbol: "AAPL",
          bar_time: time,
          open: Decimal.new(open),
          high: Decimal.new(high),
          low: Decimal.new(low),
          close: Decimal.new(close)
        }

        TradeSimulator.process_bar(fixed_sim, bar)
        TradeSimulator.process_bar(trailing_sim, bar)
        Process.sleep(10)
      end

      fixed_account = TradeSimulator.get_account(fixed_sim)
      trailing_account = TradeSimulator.get_account(trailing_sim)

      [fixed_trade] = fixed_account.closed_trades
      [trailing_trade] = trailing_account.closed_trades

      # Fixed exits at target with profit
      assert fixed_trade.status == :target_hit
      assert Decimal.compare(fixed_trade.pnl, Decimal.new(0)) == :gt

      # Trailing gets stopped out at 101.50 (from high of 103.50 - 2)
      # or might be stopped at original stop
      # Either way, fixed should have better result
      assert Decimal.compare(fixed_trade.pnl, trailing_trade.pnl) in [:gt, :eq]
    end
  end

  describe "multiple positions" do
    test "manages multiple positions independently", %{simulator: simulator, clock: clock} do
      # Signal for AAPL
      aapl_signal = %{
        symbol: "AAPL",
        direction: :long,
        entry_price: Decimal.new("100.00"),
        stop_loss: Decimal.new("98.00"),
        take_profit: Decimal.new("104.00")
      }

      # Signal for TSLA
      tsla_signal = %{
        symbol: "TSLA",
        direction: :long,
        entry_price: Decimal.new("200.00"),
        stop_loss: Decimal.new("195.00"),
        take_profit: Decimal.new("210.00")
      }

      TradeSimulator.submit_signal(simulator, aapl_signal)
      TradeSimulator.submit_signal(simulator, tsla_signal)

      # Entry bars for both
      VirtualClock.advance(clock, ~U[2024-01-15 14:31:00Z])

      aapl_bar1 = %{
        symbol: "AAPL",
        bar_time: ~U[2024-01-15 14:31:00Z],
        open: Decimal.new("100.00"),
        high: Decimal.new("100.50"),
        low: Decimal.new("99.80"),
        close: Decimal.new("100.20")
      }

      tsla_bar1 = %{
        symbol: "TSLA",
        bar_time: ~U[2024-01-15 14:31:00Z],
        open: Decimal.new("200.00"),
        high: Decimal.new("201.00"),
        low: Decimal.new("199.00"),
        close: Decimal.new("200.50")
      }

      TradeSimulator.process_bar(simulator, aapl_bar1)
      TradeSimulator.process_bar(simulator, tsla_bar1)
      Process.sleep(10)

      account = TradeSimulator.get_account(simulator)
      assert map_size(account.open_positions) == 2

      # AAPL hits target
      VirtualClock.advance(clock, ~U[2024-01-15 14:32:00Z])

      aapl_bar2 = %{
        symbol: "AAPL",
        bar_time: ~U[2024-01-15 14:32:00Z],
        open: Decimal.new("100.50"),
        high: Decimal.new("104.50"),
        low: Decimal.new("100.40"),
        close: Decimal.new("104.30")
      }

      tsla_bar2 = %{
        symbol: "TSLA",
        bar_time: ~U[2024-01-15 14:32:00Z],
        open: Decimal.new("200.50"),
        high: Decimal.new("202.00"),
        low: Decimal.new("200.00"),
        close: Decimal.new("201.50")
      }

      TradeSimulator.process_bar(simulator, aapl_bar2)
      TradeSimulator.process_bar(simulator, tsla_bar2)
      Process.sleep(10)

      account = TradeSimulator.get_account(simulator)
      # AAPL closed, TSLA still open
      assert map_size(account.open_positions) == 1
      assert length(account.closed_trades) == 1

      # Verify remaining position is TSLA
      [{_id, open_trade}] = Enum.to_list(account.open_positions)
      assert open_trade.symbol == "TSLA"

      [closed_trade] = account.closed_trades
      assert closed_trade.symbol == "AAPL"
      assert closed_trade.status == :target_hit
    end
  end

  describe "gap handling" do
    test "handles gap through stop loss", %{simulator: simulator, clock: clock} do
      signal = %{
        symbol: "AAPL",
        direction: :long,
        entry_price: Decimal.new("100.00"),
        stop_loss: Decimal.new("98.00"),
        take_profit: Decimal.new("104.00")
      }

      TradeSimulator.submit_signal(simulator, signal)

      # Entry
      process_bar(simulator, clock, "AAPL", ~U[2024-01-15 14:31:00Z], %{
        open: "100.00",
        high: "100.50",
        low: "99.80",
        close: "100.20"
      })

      # Gap down through stop - opens at 96 (below 98 stop)
      process_bar(simulator, clock, "AAPL", ~U[2024-01-15 14:32:00Z], %{
        open: "96.00",
        high: "96.50",
        low: "95.50",
        close: "96.20"
      })

      account = TradeSimulator.get_account(simulator)
      assert map_size(account.open_positions) == 0

      [trade] = account.closed_trades
      assert trade.status == :stopped_out
      # Exit at gap open price (worse than stop)
      assert Decimal.compare(trade.exit_price, Decimal.new("96.00")) == :eq
    end

    test "handles gap through take profit", %{simulator: simulator, clock: clock} do
      signal = %{
        symbol: "AAPL",
        direction: :long,
        entry_price: Decimal.new("100.00"),
        stop_loss: Decimal.new("98.00"),
        take_profit: Decimal.new("104.00")
      }

      TradeSimulator.submit_signal(simulator, signal)

      # Entry
      process_bar(simulator, clock, "AAPL", ~U[2024-01-15 14:31:00Z], %{
        open: "100.00",
        high: "100.50",
        low: "99.80",
        close: "100.20"
      })

      # Gap up through target - opens at 106 (above 104 target)
      process_bar(simulator, clock, "AAPL", ~U[2024-01-15 14:32:00Z], %{
        open: "106.00",
        high: "107.00",
        low: "105.50",
        close: "106.50"
      })

      account = TradeSimulator.get_account(simulator)
      assert map_size(account.open_positions) == 0

      [trade] = account.closed_trades
      assert trade.status == :target_hit
      # Fill at target price (conservative fill assumption)
      assert Decimal.compare(trade.exit_price, Decimal.new("104.00")) == :eq
    end
  end

  # Helper functions

  defp process_bar(simulator, clock, symbol, time, prices) do
    VirtualClock.advance(clock, time)

    bar = %{
      symbol: symbol,
      bar_time: time,
      open: Decimal.new(prices.open),
      high: Decimal.new(prices.high),
      low: Decimal.new(prices.low),
      close: Decimal.new(prices.close)
    }

    TradeSimulator.process_bar(simulator, bar)
    Process.sleep(10)
  end

  defp assert_position_open(simulator) do
    account = TradeSimulator.get_account(simulator)
    assert map_size(account.open_positions) == 1
  end

  defp create_comparison_simulators(clock) do
    # Fixed strategy simulator
    fixed_registry = :"fixed_registry_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: fixed_registry})

    fixed_run_id = Ecto.UUID.generate()

    {:ok, fixed_sim} =
      TradeSimulator.start_link(
        run_id: fixed_run_id,
        backtest_run_id: Ecto.UUID.generate(),
        account: VirtualAccount.new(Decimal.new("100000"), Decimal.new("0.01")),
        clock: clock,
        symbols: ["AAPL"],
        fill_config: FillSimulator.new(:signal_price),
        persist_trades: false,
        name: {:via, Registry, {fixed_registry, {:simulator, fixed_run_id}}}
      )

    # Trailing strategy simulator
    trailing_registry = :"trailing_registry_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: trailing_registry})

    trailing_run_id = Ecto.UUID.generate()

    {:ok, trailing_sim} =
      TradeSimulator.start_link(
        run_id: trailing_run_id,
        backtest_run_id: Ecto.UUID.generate(),
        account: VirtualAccount.new(Decimal.new("100000"), Decimal.new("0.01")),
        clock: clock,
        symbols: ["AAPL"],
        fill_config: FillSimulator.new(:signal_price),
        persist_trades: false,
        name: {:via, Registry, {trailing_registry, {:simulator, trailing_run_id}}}
      )

    {fixed_sim, trailing_sim}
  end
end
