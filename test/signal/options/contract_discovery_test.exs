defmodule Signal.Options.ContractDiscoveryTest do
  use Signal.DataCase, async: false

  alias Signal.Options.Contract
  alias Signal.Options.ContractDiscovery
  alias Signal.Repo

  describe "get_available_expirations/2" do
    test "returns sorted list of unique expirations" do
      # Insert test contracts
      insert_contract("AAPL", ~D[2025-01-17], "call", "150.00")
      insert_contract("AAPL", ~D[2025-01-24], "call", "150.00")
      insert_contract("AAPL", ~D[2025-01-17], "call", "155.00")
      insert_contract("AAPL", ~D[2025-01-31], "put", "150.00")

      expirations = ContractDiscovery.get_available_expirations("AAPL", :call)

      assert expirations == [~D[2025-01-17], ~D[2025-01-24]]
    end

    test "returns empty list when no contracts exist" do
      expirations = ContractDiscovery.get_available_expirations("UNKNOWN", :call)
      assert expirations == []
    end

    test "filters by contract type" do
      insert_contract("AAPL", ~D[2025-01-17], "call", "150.00")
      insert_contract("AAPL", ~D[2025-01-17], "put", "150.00")
      insert_contract("AAPL", ~D[2025-01-24], "put", "150.00")

      call_expirations = ContractDiscovery.get_available_expirations("AAPL", :call)
      put_expirations = ContractDiscovery.get_available_expirations("AAPL", :put)

      assert call_expirations == [~D[2025-01-17]]
      assert put_expirations == [~D[2025-01-17], ~D[2025-01-24]]
    end

    test "excludes expired contracts" do
      insert_contract("AAPL", ~D[2025-01-17], "call", "150.00", "active")
      insert_contract("AAPL", ~D[2025-01-24], "call", "150.00", "expired")

      expirations = ContractDiscovery.get_available_expirations("AAPL", :call)

      assert expirations == [~D[2025-01-17]]
    end
  end

  describe "find_contract/4" do
    test "finds a contract by all criteria" do
      insert_contract("AAPL", ~D[2025-01-17], "call", "150.00")

      {:ok, contract} =
        ContractDiscovery.find_contract("AAPL", ~D[2025-01-17], :call, Decimal.new("150.00"))

      assert contract.underlying_symbol == "AAPL"
      assert contract.expiration_date == ~D[2025-01-17]
      assert contract.contract_type == "call"
      assert Decimal.equal?(contract.strike_price, Decimal.new("150.00"))
    end

    test "returns error when contract not found" do
      insert_contract("AAPL", ~D[2025-01-17], "call", "150.00")

      assert {:error, :not_found} =
               ContractDiscovery.find_contract(
                 "AAPL",
                 ~D[2025-01-17],
                 :call,
                 Decimal.new("200.00")
               )
    end

    test "does not find expired contracts" do
      insert_contract("AAPL", ~D[2025-01-17], "call", "150.00", "expired")

      assert {:error, :not_found} =
               ContractDiscovery.find_contract(
                 "AAPL",
                 ~D[2025-01-17],
                 :call,
                 Decimal.new("150.00")
               )
    end
  end

  describe "find_contracts_near_strike/5" do
    test "returns contracts near target strike" do
      insert_contract("AAPL", ~D[2025-01-17], "call", "145.00")
      insert_contract("AAPL", ~D[2025-01-17], "call", "150.00")
      insert_contract("AAPL", ~D[2025-01-17], "call", "155.00")
      insert_contract("AAPL", ~D[2025-01-17], "call", "200.00")

      contracts =
        ContractDiscovery.find_contracts_near_strike(
          "AAPL",
          ~D[2025-01-17],
          :call,
          Decimal.new("150"),
          range: Decimal.new("10")
        )

      strikes = Enum.map(contracts, & &1.strike_price)
      assert length(contracts) == 3
      assert Decimal.new("150.00") in strikes
      assert Decimal.new("145.00") in strikes
      assert Decimal.new("155.00") in strikes
      refute Decimal.new("200.00") in strikes
    end

    test "orders by distance from target strike" do
      insert_contract("AAPL", ~D[2025-01-17], "call", "145.00")
      insert_contract("AAPL", ~D[2025-01-17], "call", "150.00")
      insert_contract("AAPL", ~D[2025-01-17], "call", "155.00")

      contracts =
        ContractDiscovery.find_contracts_near_strike(
          "AAPL",
          ~D[2025-01-17],
          :call,
          Decimal.new("151"),
          range: Decimal.new("10")
        )

      # First contract should be closest to 151 (which is 150)
      first = hd(contracts)
      assert Decimal.equal?(first.strike_price, Decimal.new("150.00"))
    end

    test "respects limit option" do
      insert_contract("AAPL", ~D[2025-01-17], "call", "145.00")
      insert_contract("AAPL", ~D[2025-01-17], "call", "150.00")
      insert_contract("AAPL", ~D[2025-01-17], "call", "155.00")

      contracts =
        ContractDiscovery.find_contracts_near_strike(
          "AAPL",
          ~D[2025-01-17],
          :call,
          Decimal.new("150"),
          range: Decimal.new("20"),
          limit: 2
        )

      assert length(contracts) == 2
    end
  end

  describe "find_nearest_weekly/2" do
    test "finds the nearest Friday expiration" do
      # Insert Friday expirations
      insert_contract("AAPL", ~D[2025-01-17], "call", "150.00")
      insert_contract("AAPL", ~D[2025-01-24], "call", "150.00")

      # Search from a Tuesday
      {:ok, date} = ContractDiscovery.find_nearest_weekly("AAPL", ~D[2025-01-14])

      # Should find the Friday of that week (Jan 17)
      assert date == ~D[2025-01-17]
    end

    test "returns error when no weekly expiration found" do
      # No contracts inserted
      result = ContractDiscovery.find_nearest_weekly("AAPL", ~D[2025-01-14])

      assert {:error, :no_expiration_found} = result
    end

    test "finds next week's Friday if this week's not available" do
      # Only insert next week's Friday
      insert_contract("AAPL", ~D[2025-01-24], "call", "150.00")

      {:ok, date} = ContractDiscovery.find_nearest_weekly("AAPL", ~D[2025-01-14])

      assert date == ~D[2025-01-24]
    end
  end

  describe "find_0dte/2" do
    test "finds 0DTE for SPY on Monday" do
      # Monday
      insert_contract("SPY", ~D[2025-01-13], "call", "500.00")

      {:ok, date} = ContractDiscovery.find_0dte("SPY", ~D[2025-01-13])

      assert date == ~D[2025-01-13]
    end

    test "finds 0DTE for SPY on Wednesday" do
      # Wednesday
      insert_contract("SPY", ~D[2025-01-15], "call", "500.00")

      {:ok, date} = ContractDiscovery.find_0dte("SPY", ~D[2025-01-15])

      assert date == ~D[2025-01-15]
    end

    test "finds 0DTE for SPY on Friday" do
      # Friday
      insert_contract("SPY", ~D[2025-01-17], "call", "500.00")

      {:ok, date} = ContractDiscovery.find_0dte("SPY", ~D[2025-01-17])

      assert date == ~D[2025-01-17]
    end

    test "returns error for SPY on Tuesday" do
      # Tuesday - no 0DTE typically
      result = ContractDiscovery.find_0dte("SPY", ~D[2025-01-14])

      assert {:error, :no_0dte_available} = result
    end

    test "finds 0DTE for AAPL only on Friday" do
      insert_contract("AAPL", ~D[2025-01-17], "call", "150.00")

      # Friday - should work
      {:ok, date} = ContractDiscovery.find_0dte("AAPL", ~D[2025-01-17])
      assert date == ~D[2025-01-17]

      # Monday - should fail
      result = ContractDiscovery.find_0dte("AAPL", ~D[2025-01-13])
      assert {:error, :no_0dte_available} = result
    end

    test "returns error when no contract exists for that day" do
      # No contract for this Friday
      result = ContractDiscovery.find_0dte("SPY", ~D[2025-01-17])

      assert {:error, :no_0dte_available} = result
    end
  end

  describe "contract_counts/0" do
    test "returns count by underlying symbol" do
      insert_contract("AAPL", ~D[2025-01-17], "call", "150.00")
      insert_contract("AAPL", ~D[2025-01-17], "call", "155.00")
      insert_contract("SPY", ~D[2025-01-17], "call", "500.00")

      counts = ContractDiscovery.contract_counts()

      assert counts["AAPL"] == 2
      assert counts["SPY"] == 1
    end

    test "excludes expired contracts from count" do
      insert_contract("AAPL", ~D[2025-01-17], "call", "150.00", "active")
      insert_contract("AAPL", ~D[2025-01-17], "call", "155.00", "expired")

      counts = ContractDiscovery.contract_counts()

      assert counts["AAPL"] == 1
    end
  end

  describe "cleanup_expired/1" do
    test "marks expired contracts as expired" do
      insert_contract("AAPL", ~D[2020-01-17], "call", "150.00", "active")
      insert_contract("AAPL", ~D[2030-01-17], "call", "150.00", "active")

      {:ok, count} = ContractDiscovery.cleanup_expired()

      assert count == 1

      expired = Repo.get_by(Contract, expiration_date: ~D[2020-01-17])
      assert expired.status == "expired"

      active = Repo.get_by(Contract, expiration_date: ~D[2030-01-17])
      assert active.status == "active"
    end

    test "deletes expired contracts when delete: true" do
      insert_contract("AAPL", ~D[2020-01-17], "call", "150.00", "active")
      insert_contract("AAPL", ~D[2030-01-17], "call", "150.00", "active")

      {:ok, count} = ContractDiscovery.cleanup_expired(delete: true)

      assert count == 1
      assert Repo.get_by(Contract, expiration_date: ~D[2020-01-17]) == nil
      assert Repo.get_by(Contract, expiration_date: ~D[2030-01-17]) != nil
    end
  end

  # Helper to insert test contracts
  defp insert_contract(underlying, expiration, type, strike, status \\ "active") do
    symbol = build_osi_symbol(underlying, expiration, type, strike)

    %Contract{}
    |> Contract.changeset(%{
      symbol: symbol,
      underlying_symbol: underlying,
      expiration_date: expiration,
      contract_type: type,
      strike_price: Decimal.new(strike),
      status: status
    })
    |> Repo.insert!()
  end

  defp build_osi_symbol(underlying, expiration, type, strike) do
    type_char = if type == "call", do: "C", else: "P"
    date_str = Calendar.strftime(expiration, "%y%m%d")

    strike_int =
      strike
      |> Decimal.new()
      |> Decimal.mult(1000)
      |> Decimal.round(0)
      |> Decimal.to_integer()

    strike_str = Integer.to_string(strike_int) |> String.pad_leading(8, "0")

    "#{underlying}#{date_str}#{type_char}#{strike_str}"
  end
end
