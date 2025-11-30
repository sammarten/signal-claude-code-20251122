defmodule Signal.Instruments.EquityTest do
  use ExUnit.Case, async: true

  alias Signal.Instruments.Equity
  alias Signal.Instruments.Instrument

  describe "from_signal/1" do
    test "creates equity from valid signal" do
      signal = %{
        symbol: "AAPL",
        direction: :long,
        entry_price: Decimal.new("150.00"),
        stop_loss: Decimal.new("145.00"),
        take_profit: Decimal.new("160.00")
      }

      assert {:ok, equity} = Equity.from_signal(signal)
      assert equity.symbol == "AAPL"
      assert equity.direction == :long
      assert Decimal.equal?(equity.entry_price, Decimal.new("150.00"))
      assert Decimal.equal?(equity.stop_loss, Decimal.new("145.00"))
      assert Decimal.equal?(equity.take_profit, Decimal.new("160.00"))
    end

    test "works with string direction" do
      signal = %{
        symbol: "AAPL",
        direction: "long",
        entry_price: Decimal.new("150.00"),
        stop_loss: Decimal.new("145.00")
      }

      assert {:ok, equity} = Equity.from_signal(signal)
      assert equity.direction == :long
    end

    test "works with numeric prices" do
      signal = %{
        symbol: "AAPL",
        direction: :long,
        entry_price: 150.0,
        stop_loss: 145.0
      }

      assert {:ok, equity} = Equity.from_signal(signal)
      assert Decimal.equal?(equity.entry_price, Decimal.new("150.0"))
    end

    test "returns error for missing symbol" do
      signal = %{
        direction: :long,
        entry_price: Decimal.new("150.00"),
        stop_loss: Decimal.new("145.00")
      }

      assert {:error, {:missing_field, :symbol}} = Equity.from_signal(signal)
    end

    test "returns error for missing direction" do
      signal = %{
        symbol: "AAPL",
        entry_price: Decimal.new("150.00"),
        stop_loss: Decimal.new("145.00")
      }

      assert {:error, {:missing_field, :direction}} = Equity.from_signal(signal)
    end

    test "handles short direction" do
      signal = %{
        symbol: "AAPL",
        direction: :short,
        entry_price: Decimal.new("150.00"),
        stop_loss: Decimal.new("155.00")
      }

      assert {:ok, equity} = Equity.from_signal(signal)
      assert equity.direction == :short
    end
  end

  describe "from_signal!/1" do
    test "returns equity for valid signal" do
      signal = %{
        symbol: "AAPL",
        direction: :long,
        entry_price: Decimal.new("150.00"),
        stop_loss: Decimal.new("145.00")
      }

      equity = Equity.from_signal!(signal)
      assert equity.symbol == "AAPL"
    end

    test "raises for invalid signal" do
      assert_raise ArgumentError, fn ->
        Equity.from_signal!(%{})
      end
    end
  end

  describe "risk_per_share/1" do
    test "calculates risk for long position" do
      equity = %Equity{
        symbol: "AAPL",
        direction: :long,
        entry_price: Decimal.new("150.00"),
        stop_loss: Decimal.new("145.00")
      }

      assert Decimal.equal?(Equity.risk_per_share(equity), Decimal.new("5.00"))
    end

    test "calculates risk for short position" do
      equity = %Equity{
        symbol: "AAPL",
        direction: :short,
        entry_price: Decimal.new("150.00"),
        stop_loss: Decimal.new("155.00")
      }

      assert Decimal.equal?(Equity.risk_per_share(equity), Decimal.new("5.00"))
    end
  end

  describe "risk_reward/1" do
    test "calculates R:R for long position" do
      equity = %Equity{
        symbol: "AAPL",
        direction: :long,
        entry_price: Decimal.new("150.00"),
        stop_loss: Decimal.new("145.00"),
        take_profit: Decimal.new("160.00")
      }

      assert {:ok, rr} = Equity.risk_reward(equity)
      assert Decimal.equal?(rr, Decimal.new("2"))
    end

    test "calculates R:R for short position" do
      equity = %Equity{
        symbol: "AAPL",
        direction: :short,
        entry_price: Decimal.new("150.00"),
        stop_loss: Decimal.new("155.00"),
        take_profit: Decimal.new("140.00")
      }

      assert {:ok, rr} = Equity.risk_reward(equity)
      assert Decimal.equal?(rr, Decimal.new("2"))
    end

    test "returns error when no target" do
      equity = %Equity{
        symbol: "AAPL",
        direction: :long,
        entry_price: Decimal.new("150.00"),
        stop_loss: Decimal.new("145.00"),
        take_profit: nil
      }

      assert {:error, :no_target} = Equity.risk_reward(equity)
    end
  end

  describe "with_quantity/2" do
    test "sets quantity on instrument" do
      equity = %Equity{
        symbol: "AAPL",
        direction: :long,
        entry_price: Decimal.new("150.00"),
        stop_loss: Decimal.new("145.00")
      }

      updated = Equity.with_quantity(equity, 100)
      assert updated.quantity == 100
    end
  end

  describe "Instrument protocol" do
    setup do
      equity = %Equity{
        symbol: "AAPL",
        direction: :long,
        entry_price: Decimal.new("150.00"),
        stop_loss: Decimal.new("145.00")
      }

      {:ok, equity: equity}
    end

    test "symbol/1 returns the stock symbol", %{equity: equity} do
      assert Instrument.symbol(equity) == "AAPL"
    end

    test "underlying_symbol/1 returns the same symbol", %{equity: equity} do
      assert Instrument.underlying_symbol(equity) == "AAPL"
    end

    test "instrument_type/1 returns :equity", %{equity: equity} do
      assert Instrument.instrument_type(equity) == :equity
    end

    test "direction/1 returns the direction", %{equity: equity} do
      assert Instrument.direction(equity) == :long
    end

    test "entry_value/1 returns the entry price", %{equity: equity} do
      assert Decimal.equal?(Instrument.entry_value(equity), Decimal.new("150.00"))
    end

    test "multiplier/1 returns 1", %{equity: equity} do
      assert Instrument.multiplier(equity) == 1
    end
  end
end
