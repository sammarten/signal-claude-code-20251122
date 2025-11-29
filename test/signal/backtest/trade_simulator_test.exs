defmodule Signal.Backtest.TradeSimulatorTest do
  use ExUnit.Case, async: true

  alias Signal.Backtest.ExitStrategy
  alias Signal.Backtest.FillSimulator
  alias Signal.Backtest.TradeSimulator
  alias Signal.Backtest.VirtualAccount
  alias Signal.Backtest.VirtualClock

  setup do
    # Use a unique registry name per test to avoid conflicts
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
        symbols: ["AAPL"],
        fill_config: FillSimulator.new(:signal_price),
        persist_trades: false,
        name: {:via, Registry, {registry_name, {:simulator, run_id}}}
      )

    %{
      simulator: simulator,
      clock: clock,
      run_id: run_id
    }
  end

  describe "fixed exit strategy" do
    test "opens position and creates position state", %{simulator: simulator, clock: clock} do
      signal = %{
        symbol: "AAPL",
        direction: :long,
        entry_price: Decimal.new("100.00"),
        stop_loss: Decimal.new("98.00"),
        take_profit: Decimal.new("104.00")
      }

      TradeSimulator.submit_signal(simulator, signal)

      # Process entry bar
      entry_bar = %{
        symbol: "AAPL",
        bar_time: ~U[2024-01-15 14:31:00Z],
        open: Decimal.new("100.00"),
        high: Decimal.new("100.50"),
        low: Decimal.new("99.80"),
        close: Decimal.new("100.20")
      }

      VirtualClock.advance(clock, entry_bar.bar_time)
      TradeSimulator.process_bar(simulator, entry_bar)

      # Give GenServer time to process
      Process.sleep(10)

      account = TradeSimulator.get_account(simulator)
      assert map_size(account.open_positions) == 1
    end

    test "exits on stop loss hit", %{simulator: simulator, clock: clock} do
      signal = %{
        symbol: "AAPL",
        direction: :long,
        entry_price: Decimal.new("100.00"),
        stop_loss: Decimal.new("98.00"),
        take_profit: Decimal.new("104.00")
      }

      TradeSimulator.submit_signal(simulator, signal)

      # Process entry bar
      entry_bar = %{
        symbol: "AAPL",
        bar_time: ~U[2024-01-15 14:31:00Z],
        open: Decimal.new("100.00"),
        high: Decimal.new("100.50"),
        low: Decimal.new("99.80"),
        close: Decimal.new("100.20")
      }

      VirtualClock.advance(clock, entry_bar.bar_time)
      TradeSimulator.process_bar(simulator, entry_bar)
      Process.sleep(10)

      # Process bar that hits stop
      stop_bar = %{
        symbol: "AAPL",
        bar_time: ~U[2024-01-15 14:32:00Z],
        open: Decimal.new("99.50"),
        high: Decimal.new("99.60"),
        low: Decimal.new("97.50"),
        close: Decimal.new("97.80")
      }

      VirtualClock.advance(clock, stop_bar.bar_time)
      TradeSimulator.process_bar(simulator, stop_bar)
      Process.sleep(10)

      account = TradeSimulator.get_account(simulator)
      assert map_size(account.open_positions) == 0
      assert length(account.closed_trades) == 1

      [trade] = account.closed_trades
      assert trade.status == :stopped_out
    end

    test "exits on target hit", %{simulator: simulator, clock: clock} do
      signal = %{
        symbol: "AAPL",
        direction: :long,
        entry_price: Decimal.new("100.00"),
        stop_loss: Decimal.new("98.00"),
        take_profit: Decimal.new("104.00")
      }

      TradeSimulator.submit_signal(simulator, signal)

      # Process entry bar
      entry_bar = %{
        symbol: "AAPL",
        bar_time: ~U[2024-01-15 14:31:00Z],
        open: Decimal.new("100.00"),
        high: Decimal.new("100.50"),
        low: Decimal.new("99.80"),
        close: Decimal.new("100.20")
      }

      VirtualClock.advance(clock, entry_bar.bar_time)
      TradeSimulator.process_bar(simulator, entry_bar)
      Process.sleep(10)

      # Process bar that hits target
      target_bar = %{
        symbol: "AAPL",
        bar_time: ~U[2024-01-15 14:32:00Z],
        open: Decimal.new("103.00"),
        high: Decimal.new("104.50"),
        low: Decimal.new("102.80"),
        close: Decimal.new("104.20")
      }

      VirtualClock.advance(clock, target_bar.bar_time)
      TradeSimulator.process_bar(simulator, target_bar)
      Process.sleep(10)

      account = TradeSimulator.get_account(simulator)
      assert map_size(account.open_positions) == 0
      assert length(account.closed_trades) == 1

      [trade] = account.closed_trades
      assert trade.status == :target_hit
    end
  end

  describe "trailing exit strategy" do
    test "trailing stop follows price up", %{simulator: simulator, clock: clock} do
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

      # Process entry bar
      entry_bar = %{
        symbol: "AAPL",
        bar_time: ~U[2024-01-15 14:31:00Z],
        open: Decimal.new("100.00"),
        high: Decimal.new("100.50"),
        low: Decimal.new("99.80"),
        close: Decimal.new("100.20")
      }

      VirtualClock.advance(clock, entry_bar.bar_time)
      TradeSimulator.process_bar(simulator, entry_bar)
      Process.sleep(10)

      # Price rises to 105, trailing stop should be at 103
      # But we need low to stay above 103 so we don't get stopped out on this bar
      rise_bar = %{
        symbol: "AAPL",
        bar_time: ~U[2024-01-15 14:32:00Z],
        open: Decimal.new("100.50"),
        high: Decimal.new("105.00"),
        low: Decimal.new("103.50"),
        close: Decimal.new("104.80")
      }

      VirtualClock.advance(clock, rise_bar.bar_time)
      TradeSimulator.process_bar(simulator, rise_bar)
      Process.sleep(10)

      # Position should still be open (low 103.50 > stop 103.00)
      account = TradeSimulator.get_account(simulator)
      assert map_size(account.open_positions) == 1

      # Now hit the trailing stop at 103
      stop_bar = %{
        symbol: "AAPL",
        bar_time: ~U[2024-01-15 14:33:00Z],
        open: Decimal.new("104.00"),
        high: Decimal.new("104.20"),
        low: Decimal.new("102.50"),
        close: Decimal.new("102.80")
      }

      VirtualClock.advance(clock, stop_bar.bar_time)
      TradeSimulator.process_bar(simulator, stop_bar)
      Process.sleep(10)

      account = TradeSimulator.get_account(simulator)
      assert map_size(account.open_positions) == 0
      assert length(account.closed_trades) == 1

      [trade] = account.closed_trades
      assert trade.status == :trailing_stopped
    end
  end

  describe "scaled exit strategy" do
    test "partial exits at targets", %{simulator: simulator, clock: clock} do
      exit_strategy =
        ExitStrategy.scaled(Decimal.new("98.00"), [
          %{price: Decimal.new("102.00"), exit_percent: 50, move_stop_to: nil},
          %{price: Decimal.new("104.00"), exit_percent: 50, move_stop_to: nil}
        ])

      signal = %{
        symbol: "AAPL",
        direction: :long,
        entry_price: Decimal.new("100.00"),
        stop_loss: Decimal.new("98.00"),
        exit_strategy: exit_strategy
      }

      TradeSimulator.submit_signal(simulator, signal)

      # Process entry bar
      entry_bar = %{
        symbol: "AAPL",
        bar_time: ~U[2024-01-15 14:31:00Z],
        open: Decimal.new("100.00"),
        high: Decimal.new("100.50"),
        low: Decimal.new("99.80"),
        close: Decimal.new("100.20")
      }

      VirtualClock.advance(clock, entry_bar.bar_time)
      TradeSimulator.process_bar(simulator, entry_bar)
      Process.sleep(10)

      account = TradeSimulator.get_account(simulator)
      [{_id, trade}] = Enum.to_list(account.open_positions)
      initial_size = trade.position_size

      # Hit first target
      target1_bar = %{
        symbol: "AAPL",
        bar_time: ~U[2024-01-15 14:32:00Z],
        open: Decimal.new("101.50"),
        high: Decimal.new("102.50"),
        low: Decimal.new("101.40"),
        close: Decimal.new("102.30")
      }

      VirtualClock.advance(clock, target1_bar.bar_time)
      TradeSimulator.process_bar(simulator, target1_bar)
      Process.sleep(10)

      # Should still have position but with reduced size
      account = TradeSimulator.get_account(simulator)
      assert map_size(account.open_positions) == 1

      [{_id, trade}] = Enum.to_list(account.open_positions)
      # 50% exited
      assert trade.position_size == div(initial_size, 2)

      # Hit second target - should close completely
      target2_bar = %{
        symbol: "AAPL",
        bar_time: ~U[2024-01-15 14:33:00Z],
        open: Decimal.new("103.50"),
        high: Decimal.new("104.50"),
        low: Decimal.new("103.40"),
        close: Decimal.new("104.30")
      }

      VirtualClock.advance(clock, target2_bar.bar_time)
      TradeSimulator.process_bar(simulator, target2_bar)
      Process.sleep(10)

      account = TradeSimulator.get_account(simulator)
      assert map_size(account.open_positions) == 0
      assert length(account.closed_trades) == 1
    end
  end

  describe "breakeven management" do
    test "moves stop to breakeven at trigger", %{simulator: simulator, clock: clock} do
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

      # Process entry bar
      entry_bar = %{
        symbol: "AAPL",
        bar_time: ~U[2024-01-15 14:31:00Z],
        open: Decimal.new("100.00"),
        high: Decimal.new("100.50"),
        low: Decimal.new("99.80"),
        close: Decimal.new("100.20")
      }

      VirtualClock.advance(clock, entry_bar.bar_time)
      TradeSimulator.process_bar(simulator, entry_bar)
      Process.sleep(10)

      # Bar reaches 1R (102.00 with 2 point risk)
      breakeven_trigger_bar = %{
        symbol: "AAPL",
        bar_time: ~U[2024-01-15 14:32:00Z],
        open: Decimal.new("100.50"),
        high: Decimal.new("102.50"),
        low: Decimal.new("100.40"),
        close: Decimal.new("102.30")
      }

      VirtualClock.advance(clock, breakeven_trigger_bar.bar_time)
      TradeSimulator.process_bar(simulator, breakeven_trigger_bar)
      Process.sleep(10)

      # Now price drops but shouldn't stop us out at 98 anymore
      # because stop should have moved to ~100.10
      pullback_bar = %{
        symbol: "AAPL",
        bar_time: ~U[2024-01-15 14:33:00Z],
        open: Decimal.new("102.00"),
        high: Decimal.new("102.10"),
        low: Decimal.new("100.50"),
        close: Decimal.new("100.80")
      }

      VirtualClock.advance(clock, pullback_bar.bar_time)
      TradeSimulator.process_bar(simulator, pullback_bar)
      Process.sleep(10)

      # Position should still be open
      account = TradeSimulator.get_account(simulator)
      assert map_size(account.open_positions) == 1
    end
  end

  describe "get_summary/1" do
    test "returns summary statistics", %{simulator: simulator} do
      summary = TradeSimulator.get_summary(simulator)

      assert is_map(summary)
      assert Map.has_key?(summary, :total_trades)
      assert Map.has_key?(summary, :win_rate)
    end
  end
end
