defmodule Signal.Backtest.FillSimulatorTest do
  use ExUnit.Case, async: true

  alias Signal.Backtest.FillSimulator

  describe "new/2" do
    test "creates config with defaults" do
      config = FillSimulator.new()

      assert config.fill_type == :signal_price
      assert config.slippage_type == :none
    end

    test "creates config with custom options" do
      config = FillSimulator.new(:next_bar_open, slippage: :random, max_slippage_pct: 0.002)

      assert config.fill_type == :next_bar_open
      assert config.slippage_type == :random
      assert config.max_slippage_pct == 0.002
    end
  end

  describe "entry_fill/4" do
    test "fills at signal price" do
      config = FillSimulator.new(:signal_price)
      signal_price = Decimal.new("100.00")

      {:ok, fill_price, slippage} = FillSimulator.entry_fill(config, signal_price, :long)

      assert fill_price == signal_price
      assert slippage == Decimal.new(0)
    end

    test "fills at next bar open" do
      config = FillSimulator.new(:next_bar_open)
      signal_price = Decimal.new("100.00")
      next_bar = %{open: Decimal.new("100.50"), close: Decimal.new("101.00")}

      {:ok, fill_price, _slippage} =
        FillSimulator.entry_fill(config, signal_price, :long, next_bar)

      assert fill_price == Decimal.new("100.50")
    end

    test "falls back to signal price when no bar provided" do
      config = FillSimulator.new(:next_bar_open)
      signal_price = Decimal.new("100.00")

      {:ok, fill_price, _slippage} = FillSimulator.entry_fill(config, signal_price, :long, nil)

      assert fill_price == signal_price
    end

    test "applies fixed slippage for long entry" do
      config =
        FillSimulator.new(:signal_price, slippage: :fixed, fixed_slippage: Decimal.new("0.05"))

      signal_price = Decimal.new("100.00")

      {:ok, fill_price, slippage} = FillSimulator.entry_fill(config, signal_price, :long)

      # Long entry: slippage added (we pay more)
      assert fill_price == Decimal.new("100.05")
      assert slippage == Decimal.new("0.05")
    end

    test "applies fixed slippage for short entry" do
      config =
        FillSimulator.new(:signal_price, slippage: :fixed, fixed_slippage: Decimal.new("0.05"))

      signal_price = Decimal.new("100.00")

      {:ok, fill_price, _slippage} = FillSimulator.entry_fill(config, signal_price, :short)

      # Short entry: slippage subtracted (we receive less)
      assert fill_price == Decimal.new("99.95")
    end
  end

  describe "check_stop/3" do
    test "detects stop hit for long position" do
      config = FillSimulator.new()

      trade = %{
        direction: :long,
        stop_loss: Decimal.new("99.00")
      }

      bar = %{
        open: Decimal.new("99.50"),
        high: Decimal.new("100.00"),
        low: Decimal.new("98.50"),
        close: Decimal.new("99.00")
      }

      assert {:stopped, fill_price, false} = FillSimulator.check_stop(config, trade, bar)
      assert fill_price == Decimal.new("99.00")
    end

    test "detects gap through stop for long position" do
      config = FillSimulator.new()

      trade = %{
        direction: :long,
        stop_loss: Decimal.new("99.00")
      }

      bar = %{
        open: Decimal.new("98.00"),
        high: Decimal.new("98.50"),
        low: Decimal.new("97.50"),
        close: Decimal.new("98.00")
      }

      assert {:stopped, fill_price, true} = FillSimulator.check_stop(config, trade, bar)
      # Filled at open when gapping through
      assert fill_price == Decimal.new("98.00")
    end

    test "returns :ok when stop not hit" do
      config = FillSimulator.new()

      trade = %{
        direction: :long,
        stop_loss: Decimal.new("99.00")
      }

      bar = %{
        open: Decimal.new("100.00"),
        high: Decimal.new("101.00"),
        low: Decimal.new("99.50"),
        close: Decimal.new("100.50")
      }

      assert :ok = FillSimulator.check_stop(config, trade, bar)
    end

    test "detects stop hit for short position" do
      config = FillSimulator.new()

      trade = %{
        direction: :short,
        stop_loss: Decimal.new("101.00")
      }

      bar = %{
        open: Decimal.new("100.50"),
        high: Decimal.new("101.50"),
        low: Decimal.new("100.00"),
        close: Decimal.new("101.00")
      }

      assert {:stopped, fill_price, false} = FillSimulator.check_stop(config, trade, bar)
      assert fill_price == Decimal.new("101.00")
    end
  end

  describe "check_target/3" do
    test "detects target hit for long position" do
      config = FillSimulator.new()

      trade = %{
        direction: :long,
        take_profit: Decimal.new("102.00")
      }

      bar = %{
        open: Decimal.new("101.00"),
        high: Decimal.new("102.50"),
        low: Decimal.new("100.50"),
        close: Decimal.new("102.00")
      }

      assert {:target_hit, fill_price} = FillSimulator.check_target(config, trade, bar)
      assert fill_price == Decimal.new("102.00")
    end

    test "returns :ok when no take_profit set" do
      config = FillSimulator.new()

      trade = %{
        direction: :long,
        take_profit: nil
      }

      bar = %{high: Decimal.new("200.00"), low: Decimal.new("100.00")}

      assert :ok = FillSimulator.check_target(config, trade, bar)
    end

    test "returns :ok when target not reached" do
      config = FillSimulator.new()

      trade = %{
        direction: :long,
        take_profit: Decimal.new("102.00")
      }

      bar = %{
        high: Decimal.new("101.50"),
        low: Decimal.new("100.50")
      }

      assert :ok = FillSimulator.check_target(config, trade, bar)
    end

    test "detects target hit for short position" do
      config = FillSimulator.new()

      trade = %{
        direction: :short,
        take_profit: Decimal.new("98.00")
      }

      bar = %{
        high: Decimal.new("99.50"),
        low: Decimal.new("97.50")
      }

      assert {:target_hit, fill_price} = FillSimulator.check_target(config, trade, bar)
      assert fill_price == Decimal.new("98.00")
    end
  end
end
