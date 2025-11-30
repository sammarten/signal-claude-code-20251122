defmodule Signal.Options.ContractTest do
  use ExUnit.Case, async: true

  alias Signal.Options.Contract

  describe "changeset/2" do
    test "valid changeset with all required fields" do
      attrs = %{
        symbol: "AAPL251017C00150000",
        underlying_symbol: "AAPL",
        expiration_date: ~D[2025-10-17],
        strike_price: Decimal.new("150.00"),
        contract_type: "call"
      }

      changeset = Contract.changeset(%Contract{}, attrs)
      assert changeset.valid?
    end

    test "invalid without required fields" do
      changeset = Contract.changeset(%Contract{}, %{})
      refute changeset.valid?

      assert "can't be blank" in errors_on(changeset).symbol
      assert "can't be blank" in errors_on(changeset).underlying_symbol
      assert "can't be blank" in errors_on(changeset).expiration_date
      assert "can't be blank" in errors_on(changeset).strike_price
      assert "can't be blank" in errors_on(changeset).contract_type
    end

    test "invalid contract type" do
      attrs = %{
        symbol: "AAPL251017C00150000",
        underlying_symbol: "AAPL",
        expiration_date: ~D[2025-10-17],
        strike_price: Decimal.new("150.00"),
        contract_type: "invalid"
      }

      changeset = Contract.changeset(%Contract{}, attrs)
      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).contract_type
    end

    test "invalid status" do
      attrs = %{
        symbol: "AAPL251017C00150000",
        underlying_symbol: "AAPL",
        expiration_date: ~D[2025-10-17],
        strike_price: Decimal.new("150.00"),
        contract_type: "call",
        status: "invalid"
      }

      changeset = Contract.changeset(%Contract{}, attrs)
      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).status
    end

    test "invalid negative strike price" do
      attrs = %{
        symbol: "AAPL251017C00150000",
        underlying_symbol: "AAPL",
        expiration_date: ~D[2025-10-17],
        strike_price: Decimal.new("-10.00"),
        contract_type: "call"
      }

      changeset = Contract.changeset(%Contract{}, attrs)
      refute changeset.valid?
      assert "must be greater than 0" in errors_on(changeset).strike_price
    end

    test "defaults status to active" do
      attrs = %{
        symbol: "AAPL251017C00150000",
        underlying_symbol: "AAPL",
        expiration_date: ~D[2025-10-17],
        strike_price: Decimal.new("150.00"),
        contract_type: "call"
      }

      changeset = Contract.changeset(%Contract{}, attrs)
      assert Ecto.Changeset.get_field(changeset, :status) == "active"
    end
  end

  describe "from_alpaca/1" do
    test "converts Alpaca API response to Contract struct" do
      alpaca_contract = %{
        "symbol" => "AAPL251017C00150000",
        "underlying_symbol" => "AAPL",
        "expiration_date" => "2025-10-17",
        "strike_price" => "150.00",
        "type" => "call"
      }

      contract = Contract.from_alpaca(alpaca_contract)

      assert contract.symbol == "AAPL251017C00150000"
      assert contract.underlying_symbol == "AAPL"
      assert contract.expiration_date == ~D[2025-10-17]
      assert Decimal.equal?(contract.strike_price, Decimal.new("150.00"))
      assert contract.contract_type == "call"
      assert contract.status == "active"
    end

    test "handles numeric strike price" do
      alpaca_contract = %{
        "symbol" => "SPY240315P00500000",
        "underlying_symbol" => "SPY",
        "expiration_date" => "2024-03-15",
        "strike_price" => 500,
        "type" => "put"
      }

      contract = Contract.from_alpaca(alpaca_contract)
      assert Decimal.equal?(contract.strike_price, Decimal.new("500"))
    end

    test "uses status from response if provided" do
      alpaca_contract = %{
        "symbol" => "AAPL251017C00150000",
        "underlying_symbol" => "AAPL",
        "expiration_date" => "2025-10-17",
        "strike_price" => "150.00",
        "type" => "call",
        "status" => "expired"
      }

      contract = Contract.from_alpaca(alpaca_contract)
      assert contract.status == "expired"
    end
  end

  describe "build_symbol/4" do
    test "builds OSI symbol for a call" do
      symbol = Contract.build_symbol("AAPL", ~D[2025-10-17], :call, Decimal.new("150"))
      assert symbol == "AAPL251017C00150000"
    end

    test "builds OSI symbol for a put" do
      symbol = Contract.build_symbol("SPY", ~D[2024-03-15], :put, Decimal.new("500"))
      assert symbol == "SPY240315P00500000"
    end
  end

  describe "contract_type_atom/1" do
    test "returns :call for call contracts" do
      contract = %Contract{contract_type: "call"}
      assert Contract.contract_type_atom(contract) == :call
    end

    test "returns :put for put contracts" do
      contract = %Contract{contract_type: "put"}
      assert Contract.contract_type_atom(contract) == :put
    end
  end

  describe "call?/1 and put?/1" do
    test "call? returns true for call contracts" do
      assert Contract.call?(%Contract{contract_type: "call"})
      refute Contract.call?(%Contract{contract_type: "put"})
    end

    test "put? returns true for put contracts" do
      assert Contract.put?(%Contract{contract_type: "put"})
      refute Contract.put?(%Contract{contract_type: "call"})
    end
  end

  describe "expired?/1" do
    test "returns true for expired status" do
      assert Contract.expired?(%Contract{status: "expired", expiration_date: ~D[2099-12-31]})
    end

    test "returns true for past expiration date" do
      assert Contract.expired?(%Contract{status: "active", expiration_date: ~D[2020-01-01]})
    end

    test "returns false for future expiration" do
      refute Contract.expired?(%Contract{status: "active", expiration_date: ~D[2099-12-31]})
    end
  end

  describe "days_to_expiration/1" do
    test "returns positive days for future expiration" do
      future_date = Date.add(Date.utc_today(), 30)
      contract = %Contract{expiration_date: future_date}
      assert Contract.days_to_expiration(contract) == 30
    end

    test "returns 0 for past expiration" do
      past_date = Date.add(Date.utc_today(), -10)
      contract = %Contract{expiration_date: past_date}
      assert Contract.days_to_expiration(contract) == 0
    end

    test "returns 0 for today's expiration" do
      contract = %Contract{expiration_date: Date.utc_today()}
      assert Contract.days_to_expiration(contract) == 0
    end
  end

  # Helper to extract error messages from changeset
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
