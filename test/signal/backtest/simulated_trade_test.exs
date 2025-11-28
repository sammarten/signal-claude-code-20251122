defmodule Signal.Backtest.SimulatedTradeTest do
  use Signal.DataCase, async: true

  alias Signal.Backtest.SimulatedTrade
  alias Signal.Backtest.BacktestRun

  setup do
    # Create a backtest run for foreign key
    {:ok, run} =
      %BacktestRun{}
      |> BacktestRun.changeset(%{
        symbols: ["AAPL"],
        start_date: ~D[2024-01-01],
        end_date: ~D[2024-01-31],
        strategies: ["break_and_retest"],
        initial_capital: Decimal.new("100000"),
        risk_per_trade: Decimal.new("0.01")
      })
      |> Repo.insert()

    %{run: run}
  end

  describe "changeset/2" do
    test "valid changeset with required fields", %{run: run} do
      attrs = %{
        backtest_run_id: run.id,
        symbol: "AAPL",
        direction: :long,
        entry_price: Decimal.new("175.50"),
        entry_time: ~U[2024-01-15 14:30:00Z],
        position_size: 100,
        risk_amount: Decimal.new("1000"),
        stop_loss: Decimal.new("174.50")
      }

      changeset = SimulatedTrade.changeset(%SimulatedTrade{}, attrs)
      assert changeset.valid?
    end

    test "invalid without required fields", %{run: run} do
      changeset = SimulatedTrade.changeset(%SimulatedTrade{}, %{backtest_run_id: run.id})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).symbol
      assert "can't be blank" in errors_on(changeset).direction
      assert "can't be blank" in errors_on(changeset).entry_price
    end

    test "validates entry_price must be positive", %{run: run} do
      attrs = %{
        backtest_run_id: run.id,
        symbol: "AAPL",
        direction: :long,
        entry_price: Decimal.new("-10"),
        entry_time: ~U[2024-01-15 14:30:00Z],
        position_size: 100,
        risk_amount: Decimal.new("1000"),
        stop_loss: Decimal.new("174.50")
      }

      changeset = SimulatedTrade.changeset(%SimulatedTrade{}, attrs)

      refute changeset.valid?
      assert "must be greater than 0" in errors_on(changeset).entry_price
    end
  end

  describe "calculate_pnl/2" do
    test "calculates profit for long position" do
      trade = %SimulatedTrade{
        direction: :long,
        entry_price: Decimal.new("100.00"),
        position_size: 100,
        risk_amount: Decimal.new("500")
      }

      result = SimulatedTrade.calculate_pnl(trade, Decimal.new("105.00"))

      # PnL = (105 - 100) * 100 = 500
      assert Decimal.compare(result.pnl, Decimal.new("500.00")) == :eq
      # R-multiple = 500 / 500 = 1
      assert Decimal.compare(result.r_multiple, Decimal.new("1.00")) == :eq
    end

    test "calculates loss for long position" do
      trade = %SimulatedTrade{
        direction: :long,
        entry_price: Decimal.new("100.00"),
        position_size: 100,
        risk_amount: Decimal.new("500")
      }

      result = SimulatedTrade.calculate_pnl(trade, Decimal.new("95.00"))

      # PnL = (95 - 100) * 100 = -500
      assert Decimal.compare(result.pnl, Decimal.new("-500.00")) == :eq
      # R-multiple = -500 / 500 = -1
      assert Decimal.compare(result.r_multiple, Decimal.new("-1.00")) == :eq
    end

    test "calculates profit for short position" do
      trade = %SimulatedTrade{
        direction: :short,
        entry_price: Decimal.new("100.00"),
        position_size: 100,
        risk_amount: Decimal.new("500")
      }

      result = SimulatedTrade.calculate_pnl(trade, Decimal.new("95.00"))

      # PnL = (100 - 95) * 100 = 500
      assert Decimal.compare(result.pnl, Decimal.new("500.00")) == :eq
    end
  end

  describe "stop_hit?/2" do
    test "returns true when price at or below stop for long" do
      trade = %SimulatedTrade{
        direction: :long,
        stop_loss: Decimal.new("99.00")
      }

      assert SimulatedTrade.stop_hit?(trade, Decimal.new("99.00"))
      assert SimulatedTrade.stop_hit?(trade, Decimal.new("98.00"))
      refute SimulatedTrade.stop_hit?(trade, Decimal.new("100.00"))
    end

    test "returns true when price at or above stop for short" do
      trade = %SimulatedTrade{
        direction: :short,
        stop_loss: Decimal.new("101.00")
      }

      assert SimulatedTrade.stop_hit?(trade, Decimal.new("101.00"))
      assert SimulatedTrade.stop_hit?(trade, Decimal.new("102.00"))
      refute SimulatedTrade.stop_hit?(trade, Decimal.new("100.00"))
    end
  end

  describe "target_hit?/2" do
    test "returns true when price at or above target for long" do
      trade = %SimulatedTrade{
        direction: :long,
        take_profit: Decimal.new("105.00")
      }

      assert SimulatedTrade.target_hit?(trade, Decimal.new("105.00"))
      assert SimulatedTrade.target_hit?(trade, Decimal.new("106.00"))
      refute SimulatedTrade.target_hit?(trade, Decimal.new("104.00"))
    end

    test "returns false when no take_profit set" do
      trade = %SimulatedTrade{
        direction: :long,
        take_profit: nil
      }

      refute SimulatedTrade.target_hit?(trade, Decimal.new("200.00"))
    end

    test "returns true when price at or below target for short" do
      trade = %SimulatedTrade{
        direction: :short,
        take_profit: Decimal.new("95.00")
      }

      assert SimulatedTrade.target_hit?(trade, Decimal.new("95.00"))
      assert SimulatedTrade.target_hit?(trade, Decimal.new("94.00"))
      refute SimulatedTrade.target_hit?(trade, Decimal.new("96.00"))
    end
  end
end
