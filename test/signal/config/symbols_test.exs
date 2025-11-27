defmodule Signal.Config.SymbolsTest do
  use ExUnit.Case, async: true

  alias Signal.Config.Symbols

  describe "list/0" do
    test "returns a list of symbols" do
      symbols = Symbols.list()
      assert is_list(symbols)
      assert length(symbols) > 0
      assert "AAPL" in symbols
    end
  end

  describe "default_list/0" do
    test "returns the default symbols" do
      defaults = Symbols.default_list()
      assert is_list(defaults)
      assert "AAPL" in defaults
      assert "SPY" in defaults
    end
  end

  describe "count/0" do
    test "returns the number of symbols" do
      count = Symbols.count()
      assert is_integer(count)
      assert count > 0
      assert count == length(Symbols.list())
    end
  end

  describe "member?/1" do
    test "returns true for configured symbols" do
      assert Symbols.member?("AAPL")
      assert Symbols.member?("TSLA")
      assert Symbols.member?("SPY")
    end

    test "returns false for non-configured symbols" do
      refute Symbols.member?("INVALID")
      refute Symbols.member?("FAKE")
    end

    test "handles atom symbols" do
      assert Symbols.member?(:AAPL)
      refute Symbols.member?(:INVALID)
    end
  end

  describe "validate/1" do
    test "returns valid symbols from the list" do
      assert {:ok, valid} = Symbols.validate(["AAPL", "TSLA", "INVALID"])
      assert "AAPL" in valid
      assert "TSLA" in valid
      refute "INVALID" in valid
    end

    test "returns error when no valid symbols" do
      assert {:error, :no_valid_symbols} = Symbols.validate(["INVALID", "FAKE"])
    end

    test "returns error for empty list" do
      assert {:error, :no_valid_symbols} = Symbols.validate([])
    end

    test "returns all symbols when all are valid" do
      assert {:ok, ["AAPL", "TSLA"]} = Symbols.validate(["AAPL", "TSLA"])
    end
  end

  describe "parse/1" do
    test "parses comma-separated string" do
      assert {:ok, symbols} = Symbols.parse("AAPL,TSLA,NVDA")
      assert "AAPL" in symbols
      assert "TSLA" in symbols
      assert "NVDA" in symbols
    end

    test "handles whitespace" do
      assert {:ok, symbols} = Symbols.parse("AAPL, TSLA , NVDA")
      assert "AAPL" in symbols
      assert "TSLA" in symbols
      assert "NVDA" in symbols
    end

    test "converts to uppercase" do
      assert {:ok, symbols} = Symbols.parse("aapl,tsla")
      assert "AAPL" in symbols
      assert "TSLA" in symbols
    end

    test "filters out invalid symbols" do
      assert {:ok, symbols} = Symbols.parse("AAPL,INVALID,TSLA")
      assert "AAPL" in symbols
      assert "TSLA" in symbols
      refute "INVALID" in symbols
    end

    test "returns error when all symbols invalid" do
      assert {:error, :no_valid_symbols} = Symbols.parse("INVALID,FAKE")
    end

    test "handles empty string" do
      assert {:error, :no_valid_symbols} = Symbols.parse("")
    end
  end
end
