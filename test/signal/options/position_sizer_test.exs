defmodule Signal.Options.PositionSizerTest do
  use ExUnit.Case, async: true

  alias Signal.Options.PositionSizer

  describe "calculate/1" do
    test "calculates contracts from risk amount and premium" do
      # Risk $1000, premium $5.00 per share
      # Cost per contract = $5.00 × 100 = $500
      # Contracts = $1000 / $500 = 2
      assert {:ok, 2, cost} =
               PositionSizer.calculate(
                 entry_premium: Decimal.new("5.00"),
                 risk_amount: Decimal.new("1000")
               )

      assert Decimal.equal?(cost, Decimal.new("1000"))
    end

    test "rounds down to whole contracts" do
      # Risk $1000, premium $3.00 per share
      # Cost per contract = $3.00 × 100 = $300
      # Contracts = $1000 / $300 = 3.33... = 3 (floor)
      assert {:ok, 3, cost} =
               PositionSizer.calculate(
                 entry_premium: Decimal.new("3.00"),
                 risk_amount: Decimal.new("1000")
               )

      assert Decimal.equal?(cost, Decimal.new("900"))
    end

    test "ensures minimum 1 contract" do
      # Risk $100, premium $5.00 per share
      # Cost per contract = $500, which exceeds risk
      # But minimum is 1 contract
      assert {:ok, 1, cost} =
               PositionSizer.calculate(
                 entry_premium: Decimal.new("5.00"),
                 risk_amount: Decimal.new("100")
               )

      assert Decimal.equal?(cost, Decimal.new("500"))
    end

    test "respects available cash constraint" do
      # Risk $5000, premium $2.00 per share
      # Cost per contract = $200
      # From risk: 25 contracts
      # From cash ($1000): 5 contracts
      # Should be limited to 5
      assert {:ok, 5, cost} =
               PositionSizer.calculate(
                 entry_premium: Decimal.new("2.00"),
                 risk_amount: Decimal.new("5000"),
                 available_cash: Decimal.new("1000")
               )

      assert Decimal.equal?(cost, Decimal.new("1000"))
    end

    test "respects max_contracts constraint" do
      # Risk $10000, premium $2.00 per share
      # Cost per contract = $200
      # From risk: 50 contracts
      # Max allowed: 10
      assert {:ok, 10, cost} =
               PositionSizer.calculate(
                 entry_premium: Decimal.new("2.00"),
                 risk_amount: Decimal.new("10000"),
                 max_contracts: 10
               )

      assert Decimal.equal?(cost, Decimal.new("2000"))
    end

    test "returns error for insufficient funds" do
      # Risk $10, premium $50 per share
      # Cost per contract = $5000
      # Available cash = $100
      # Can't afford even 1 contract
      assert {:error, :insufficient_funds} =
               PositionSizer.calculate(
                 entry_premium: Decimal.new("50.00"),
                 risk_amount: Decimal.new("10"),
                 available_cash: Decimal.new("100")
               )
    end

    test "returns error for zero premium" do
      assert {:error, :invalid_premium} =
               PositionSizer.calculate(
                 entry_premium: Decimal.new("0"),
                 risk_amount: Decimal.new("1000")
               )
    end

    test "returns error for negative premium" do
      assert {:error, :invalid_premium} =
               PositionSizer.calculate(
                 entry_premium: Decimal.new("-5.00"),
                 risk_amount: Decimal.new("1000")
               )
    end

    test "returns error for missing entry_premium" do
      assert {:error, {:missing_option, :entry_premium}} =
               PositionSizer.calculate(risk_amount: Decimal.new("1000"))
    end

    test "returns error for missing risk_amount" do
      assert {:error, {:missing_option, :risk_amount}} =
               PositionSizer.calculate(entry_premium: Decimal.new("5.00"))
    end

    test "works with numeric values" do
      assert {:ok, 2, _cost} =
               PositionSizer.calculate(
                 entry_premium: 5.0,
                 risk_amount: 1000
               )
    end

    test "works with string values" do
      assert {:ok, 2, _cost} =
               PositionSizer.calculate(
                 entry_premium: "5.00",
                 risk_amount: "1000"
               )
    end

    test "uses custom multiplier" do
      # Mini options have 10 multiplier
      # Risk $500, premium $5.00
      # Cost per contract = $5.00 × 10 = $50
      # Contracts = $500 / $50 = 10
      assert {:ok, 10, cost} =
               PositionSizer.calculate(
                 entry_premium: Decimal.new("5.00"),
                 risk_amount: Decimal.new("500"),
                 multiplier: 10
               )

      assert Decimal.equal?(cost, Decimal.new("500"))
    end

    test "uses custom min_contracts" do
      # Risk $50, premium $5.00
      # Cost per contract = $500
      # From risk: 0.1 contracts = 0 (floor)
      # Min contracts = 2
      # But cash constraint kicks in
      assert {:ok, 2, cost} =
               PositionSizer.calculate(
                 entry_premium: Decimal.new("5.00"),
                 risk_amount: Decimal.new("50"),
                 min_contracts: 2,
                 available_cash: Decimal.new("10000")
               )

      assert Decimal.equal?(cost, Decimal.new("1000"))
    end
  end

  describe "from_equity/1" do
    test "calculates risk amount from equity and percentage" do
      # $100,000 equity, 1% risk = $1000 risk budget
      # Premium $5.00 per share, cost $500 per contract
      # Contracts = 2
      assert {:ok, 2, cost} =
               PositionSizer.from_equity(
                 account_equity: Decimal.new("100000"),
                 risk_percentage: Decimal.new("0.01"),
                 entry_premium: Decimal.new("5.00")
               )

      assert Decimal.equal?(cost, Decimal.new("1000"))
    end

    test "returns error for missing account_equity" do
      assert {:error, {:missing_option, :account_equity}} =
               PositionSizer.from_equity(
                 risk_percentage: Decimal.new("0.01"),
                 entry_premium: Decimal.new("5.00")
               )
    end

    test "returns error for missing risk_percentage" do
      assert {:error, {:missing_option, :risk_percentage}} =
               PositionSizer.from_equity(
                 account_equity: Decimal.new("100000"),
                 entry_premium: Decimal.new("5.00")
               )
    end
  end

  describe "max_loss/3" do
    test "calculates max loss for long options" do
      # 5 contracts, $3.00 premium, standard 100 multiplier
      # Max loss = $3.00 × 100 × 5 = $1500
      max = PositionSizer.max_loss(5, Decimal.new("3.00"))
      assert Decimal.equal?(max, Decimal.new("1500"))
    end

    test "calculates max loss with custom multiplier" do
      # 10 contracts, $3.00 premium, 10 multiplier (mini)
      # Max loss = $3.00 × 10 × 10 = $300
      max = PositionSizer.max_loss(10, Decimal.new("3.00"), 10)
      assert Decimal.equal?(max, Decimal.new("300"))
    end
  end

  describe "breakeven/3" do
    test "calculates breakeven for call option" do
      # Strike $150, premium $5.25
      # Breakeven = $155.25
      be = PositionSizer.breakeven(Decimal.new("150"), Decimal.new("5.25"), :call)
      assert Decimal.equal?(be, Decimal.new("155.25"))
    end

    test "calculates breakeven for put option" do
      # Strike $150, premium $3.50
      # Breakeven = $146.50
      be = PositionSizer.breakeven(Decimal.new("150"), Decimal.new("3.50"), :put)
      assert Decimal.equal?(be, Decimal.new("146.50"))
    end
  end
end
