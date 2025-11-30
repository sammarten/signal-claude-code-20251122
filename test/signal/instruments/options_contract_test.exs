defmodule Signal.Instruments.OptionsContractTest do
  use ExUnit.Case, async: true

  alias Signal.Instruments.OptionsContract
  alias Signal.Instruments.Instrument

  describe "new/1" do
    test "creates options contract from valid attrs" do
      attrs = %{
        underlying_symbol: "AAPL",
        contract_symbol: "AAPL250117C00150000",
        contract_type: :call,
        strike: Decimal.new("150.00"),
        expiration: ~D[2025-01-17],
        entry_premium: Decimal.new("5.25")
      }

      assert {:ok, option} = OptionsContract.new(attrs)
      assert option.underlying_symbol == "AAPL"
      assert option.contract_symbol == "AAPL250117C00150000"
      assert option.contract_type == :call
      assert Decimal.equal?(option.strike, Decimal.new("150.00"))
      assert option.expiration == ~D[2025-01-17]
      assert Decimal.equal?(option.entry_premium, Decimal.new("5.25"))
      assert option.direction == :long
    end

    test "works with string contract type" do
      attrs = %{
        underlying_symbol: "AAPL",
        contract_symbol: "AAPL250117P00150000",
        contract_type: "put",
        strike: Decimal.new("150.00"),
        expiration: ~D[2025-01-17],
        entry_premium: Decimal.new("3.50")
      }

      assert {:ok, option} = OptionsContract.new(attrs)
      assert option.contract_type == :put
    end

    test "works with numeric strike and premium" do
      attrs = %{
        underlying_symbol: "AAPL",
        contract_symbol: "AAPL250117C00150000",
        contract_type: :call,
        strike: 150.0,
        expiration: ~D[2025-01-17],
        entry_premium: 5.25
      }

      assert {:ok, option} = OptionsContract.new(attrs)
      assert Decimal.equal?(option.strike, Decimal.new("150.0"))
      assert Decimal.equal?(option.entry_premium, Decimal.new("5.25"))
    end

    test "works with string expiration" do
      attrs = %{
        underlying_symbol: "AAPL",
        contract_symbol: "AAPL250117C00150000",
        contract_type: :call,
        strike: Decimal.new("150.00"),
        expiration: "2025-01-17",
        entry_premium: Decimal.new("5.25")
      }

      assert {:ok, option} = OptionsContract.new(attrs)
      assert option.expiration == ~D[2025-01-17]
    end

    test "returns error for missing underlying_symbol" do
      attrs = %{
        contract_symbol: "AAPL250117C00150000",
        contract_type: :call,
        strike: Decimal.new("150.00"),
        expiration: ~D[2025-01-17],
        entry_premium: Decimal.new("5.25")
      }

      assert {:error, {:missing_field, :underlying_symbol}} = OptionsContract.new(attrs)
    end

    test "returns error for missing contract_symbol" do
      attrs = %{
        underlying_symbol: "AAPL",
        contract_type: :call,
        strike: Decimal.new("150.00"),
        expiration: ~D[2025-01-17],
        entry_premium: Decimal.new("5.25")
      }

      assert {:error, {:missing_field, :contract_symbol}} = OptionsContract.new(attrs)
    end

    test "returns error for invalid contract type" do
      attrs = %{
        underlying_symbol: "AAPL",
        contract_symbol: "AAPL250117C00150000",
        contract_type: :invalid,
        strike: Decimal.new("150.00"),
        expiration: ~D[2025-01-17],
        entry_premium: Decimal.new("5.25")
      }

      assert {:error, {:invalid_contract_type, :invalid}} = OptionsContract.new(attrs)
    end
  end

  describe "new!/1" do
    test "returns options contract for valid attrs" do
      attrs = %{
        underlying_symbol: "AAPL",
        contract_symbol: "AAPL250117C00150000",
        contract_type: :call,
        strike: Decimal.new("150.00"),
        expiration: ~D[2025-01-17],
        entry_premium: Decimal.new("5.25")
      }

      option = OptionsContract.new!(attrs)
      assert option.underlying_symbol == "AAPL"
    end

    test "raises for invalid attrs" do
      assert_raise ArgumentError, fn ->
        OptionsContract.new!(%{})
      end
    end
  end

  describe "entry_cost/1" do
    test "calculates cost without quantity" do
      option = %OptionsContract{
        underlying_symbol: "AAPL",
        contract_symbol: "AAPL250117C00150000",
        contract_type: :call,
        strike: Decimal.new("150.00"),
        expiration: ~D[2025-01-17],
        entry_premium: Decimal.new("5.25"),
        quantity: nil
      }

      # 5.25 * 100 = 525
      assert Decimal.equal?(OptionsContract.entry_cost(option), Decimal.new("525"))
    end

    test "calculates cost with quantity" do
      option = %OptionsContract{
        underlying_symbol: "AAPL",
        contract_symbol: "AAPL250117C00150000",
        contract_type: :call,
        strike: Decimal.new("150.00"),
        expiration: ~D[2025-01-17],
        entry_premium: Decimal.new("5.25"),
        quantity: 2
      }

      # 5.25 * 100 * 2 = 1050
      assert Decimal.equal?(OptionsContract.entry_cost(option), Decimal.new("1050"))
    end
  end

  describe "call?/1 and put?/1" do
    test "call? returns true for call options" do
      option = %OptionsContract{
        underlying_symbol: "AAPL",
        contract_symbol: "AAPL250117C00150000",
        contract_type: :call,
        strike: Decimal.new("150.00"),
        expiration: ~D[2025-01-17],
        entry_premium: Decimal.new("5.25")
      }

      assert OptionsContract.call?(option)
      refute OptionsContract.put?(option)
    end

    test "put? returns true for put options" do
      option = %OptionsContract{
        underlying_symbol: "AAPL",
        contract_symbol: "AAPL250117P00150000",
        contract_type: :put,
        strike: Decimal.new("150.00"),
        expiration: ~D[2025-01-17],
        entry_premium: Decimal.new("3.50")
      }

      assert OptionsContract.put?(option)
      refute OptionsContract.call?(option)
    end
  end

  describe "moneyness/2" do
    test "returns :itm for in-the-money call" do
      option = %OptionsContract{
        underlying_symbol: "AAPL",
        contract_symbol: "AAPL250117C00150000",
        contract_type: :call,
        strike: Decimal.new("150.00"),
        expiration: ~D[2025-01-17],
        entry_premium: Decimal.new("5.25")
      }

      assert OptionsContract.moneyness(option, Decimal.new("160.00")) == :itm
    end

    test "returns :otm for out-of-the-money call" do
      option = %OptionsContract{
        underlying_symbol: "AAPL",
        contract_symbol: "AAPL250117C00150000",
        contract_type: :call,
        strike: Decimal.new("150.00"),
        expiration: ~D[2025-01-17],
        entry_premium: Decimal.new("5.25")
      }

      assert OptionsContract.moneyness(option, Decimal.new("140.00")) == :otm
    end

    test "returns :atm for at-the-money call" do
      option = %OptionsContract{
        underlying_symbol: "AAPL",
        contract_symbol: "AAPL250117C00150000",
        contract_type: :call,
        strike: Decimal.new("150.00"),
        expiration: ~D[2025-01-17],
        entry_premium: Decimal.new("5.25")
      }

      # Within 1% of strike
      assert OptionsContract.moneyness(option, Decimal.new("150.50")) == :atm
    end

    test "returns :itm for in-the-money put" do
      option = %OptionsContract{
        underlying_symbol: "AAPL",
        contract_symbol: "AAPL250117P00150000",
        contract_type: :put,
        strike: Decimal.new("150.00"),
        expiration: ~D[2025-01-17],
        entry_premium: Decimal.new("3.50")
      }

      assert OptionsContract.moneyness(option, Decimal.new("140.00")) == :itm
    end

    test "returns :otm for out-of-the-money put" do
      option = %OptionsContract{
        underlying_symbol: "AAPL",
        contract_symbol: "AAPL250117P00150000",
        contract_type: :put,
        strike: Decimal.new("150.00"),
        expiration: ~D[2025-01-17],
        entry_premium: Decimal.new("3.50")
      }

      assert OptionsContract.moneyness(option, Decimal.new("160.00")) == :otm
    end
  end

  describe "with_quantity/2" do
    test "sets quantity on instrument" do
      option = %OptionsContract{
        underlying_symbol: "AAPL",
        contract_symbol: "AAPL250117C00150000",
        contract_type: :call,
        strike: Decimal.new("150.00"),
        expiration: ~D[2025-01-17],
        entry_premium: Decimal.new("5.25")
      }

      updated = OptionsContract.with_quantity(option, 5)
      assert updated.quantity == 5
    end
  end

  describe "contract_multiplier/0" do
    test "returns 100" do
      assert OptionsContract.contract_multiplier() == 100
    end
  end

  describe "Instrument protocol" do
    setup do
      option = %OptionsContract{
        underlying_symbol: "AAPL",
        contract_symbol: "AAPL250117C00150000",
        contract_type: :call,
        strike: Decimal.new("150.00"),
        expiration: ~D[2025-01-17],
        entry_premium: Decimal.new("5.25")
      }

      {:ok, option: option}
    end

    test "symbol/1 returns the contract symbol", %{option: option} do
      assert Instrument.symbol(option) == "AAPL250117C00150000"
    end

    test "underlying_symbol/1 returns the underlying symbol", %{option: option} do
      assert Instrument.underlying_symbol(option) == "AAPL"
    end

    test "instrument_type/1 returns :options", %{option: option} do
      assert Instrument.instrument_type(option) == :options
    end

    test "direction/1 returns :long", %{option: option} do
      assert Instrument.direction(option) == :long
    end

    test "entry_value/1 returns the entry premium", %{option: option} do
      assert Decimal.equal?(Instrument.entry_value(option), Decimal.new("5.25"))
    end

    test "multiplier/1 returns 100", %{option: option} do
      assert Instrument.multiplier(option) == 100
    end
  end
end
