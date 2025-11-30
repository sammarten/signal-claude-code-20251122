defmodule Signal.Options.OSITest do
  use ExUnit.Case, async: true

  alias Signal.Options.OSI

  describe "build/4" do
    test "builds OSI symbol for a call option" do
      assert OSI.build("AAPL", ~D[2025-10-17], :call, Decimal.new("150")) ==
               "AAPL251017C00150000"
    end

    test "builds OSI symbol for a put option" do
      assert OSI.build("SPY", ~D[2024-03-15], :put, Decimal.new("500")) ==
               "SPY240315P00500000"
    end

    test "handles decimal strikes with fractions" do
      assert OSI.build("TSLA", ~D[2025-01-10], :call, Decimal.new("250.50")) ==
               "TSLA250110C00250500"
    end

    test "handles integer strikes" do
      assert OSI.build("NVDA", ~D[2025-06-20], :put, 100) ==
               "NVDA250620P00100000"
    end

    test "handles single-digit months and days" do
      assert OSI.build("QQQ", ~D[2025-01-03], :call, Decimal.new("400")) ==
               "QQQ250103C00400000"
    end

    test "handles small strikes" do
      assert OSI.build("F", ~D[2025-01-17], :call, Decimal.new("12.50")) ==
               "F250117C00012500"
    end

    test "handles large strikes" do
      assert OSI.build("AMZN", ~D[2025-12-19], :put, Decimal.new("3500")) ==
               "AMZN251219P03500000"
    end
  end

  describe "parse/1" do
    test "parses a valid call option symbol" do
      assert {:ok, parsed} = OSI.parse("AAPL251017C00150000")
      assert parsed.underlying == "AAPL"
      assert parsed.expiration == ~D[2025-10-17]
      assert parsed.contract_type == :call
      assert Decimal.equal?(parsed.strike, Decimal.new("150"))
    end

    test "parses a valid put option symbol" do
      assert {:ok, parsed} = OSI.parse("SPY240315P00500000")
      assert parsed.underlying == "SPY"
      assert parsed.expiration == ~D[2024-03-15]
      assert parsed.contract_type == :put
      assert Decimal.equal?(parsed.strike, Decimal.new("500"))
    end

    test "parses symbol with decimal strike" do
      assert {:ok, parsed} = OSI.parse("TSLA250110C00250500")
      assert Decimal.equal?(parsed.strike, Decimal.new("250.5"))
    end

    test "parses symbol with single-character underlying" do
      assert {:ok, parsed} = OSI.parse("F250117C00012500")
      assert parsed.underlying == "F"
      assert Decimal.equal?(parsed.strike, Decimal.new("12.5"))
    end

    test "returns error for invalid format - too short" do
      assert {:error, :invalid_format} = OSI.parse("AAPL")
    end

    test "returns error for invalid format - bad date" do
      assert {:error, :invalid_date} = OSI.parse("AAPL999999C00150000")
    end

    test "returns error for invalid format - bad contract type" do
      assert {:error, :invalid_contract_type} = OSI.parse("AAPL251017X00150000")
    end

    test "returns error for non-string input" do
      assert {:error, :invalid_format} = OSI.parse(123)
    end

    test "parses lowercase contract type" do
      assert {:ok, parsed} = OSI.parse("AAPL251017c00150000")
      assert parsed.contract_type == :call

      assert {:ok, parsed} = OSI.parse("AAPL251017p00150000")
      assert parsed.contract_type == :put
    end
  end

  describe "parse!/1" do
    test "returns parsed result for valid symbol" do
      result = OSI.parse!("AAPL251017C00150000")
      assert result.underlying == "AAPL"
    end

    test "raises ArgumentError for invalid symbol" do
      assert_raise ArgumentError, fn ->
        OSI.parse!("invalid")
      end
    end
  end

  describe "underlying/1" do
    test "extracts underlying from valid symbol" do
      assert {:ok, "AAPL"} = OSI.underlying("AAPL251017C00150000")
      assert {:ok, "SPY"} = OSI.underlying("SPY240315P00500000")
      assert {:ok, "F"} = OSI.underlying("F250117C00012500")
    end

    test "returns error for invalid symbol" do
      assert {:error, _} = OSI.underlying("invalid")
    end
  end

  describe "expiration/1" do
    test "extracts expiration date from valid symbol" do
      assert {:ok, ~D[2025-10-17]} = OSI.expiration("AAPL251017C00150000")
      assert {:ok, ~D[2024-03-15]} = OSI.expiration("SPY240315P00500000")
    end

    test "returns error for invalid symbol" do
      assert {:error, _} = OSI.expiration("invalid")
    end
  end

  describe "strike/1" do
    test "extracts strike price from valid symbol" do
      assert {:ok, strike} = OSI.strike("AAPL251017C00150000")
      assert Decimal.equal?(strike, Decimal.new("150"))

      assert {:ok, strike} = OSI.strike("TSLA250110C00250500")
      assert Decimal.equal?(strike, Decimal.new("250.5"))
    end

    test "returns error for invalid symbol" do
      assert {:error, _} = OSI.strike("invalid")
    end
  end

  describe "contract_type/1" do
    test "extracts contract type from valid symbol" do
      assert {:ok, :call} = OSI.contract_type("AAPL251017C00150000")
      assert {:ok, :put} = OSI.contract_type("SPY240315P00500000")
    end

    test "returns error for invalid symbol" do
      assert {:error, _} = OSI.contract_type("invalid")
    end
  end

  describe "valid?/1" do
    test "returns true for valid symbols" do
      assert OSI.valid?("AAPL251017C00150000")
      assert OSI.valid?("SPY240315P00500000")
      assert OSI.valid?("F250117C00012500")
    end

    test "returns false for invalid symbols" do
      refute OSI.valid?("AAPL")
      refute OSI.valid?("invalid")
      refute OSI.valid?("")
    end
  end

  describe "round trip" do
    test "build and parse are inverse operations" do
      underlying = "AAPL"
      expiration = ~D[2025-10-17]
      contract_type = :call
      strike = Decimal.new("150.50")

      symbol = OSI.build(underlying, expiration, contract_type, strike)
      {:ok, parsed} = OSI.parse(symbol)

      assert parsed.underlying == underlying
      assert parsed.expiration == expiration
      assert parsed.contract_type == contract_type
      assert Decimal.equal?(parsed.strike, strike)
    end

    test "round trip with various underlyings" do
      for underlying <- ["SPY", "AAPL", "TSLA", "NVDA", "QQQ", "F", "MSFT"] do
        symbol = OSI.build(underlying, ~D[2025-06-20], :put, Decimal.new("200"))
        {:ok, parsed} = OSI.parse(symbol)
        assert parsed.underlying == underlying
      end
    end
  end
end
