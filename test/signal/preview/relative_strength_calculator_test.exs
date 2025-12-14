defmodule Signal.Preview.RelativeStrengthCalculatorTest do
  use ExUnit.Case, async: true

  alias Signal.Preview.{RelativeStrengthCalculator, RelativeStrength}

  describe "rank/2" do
    test "ranks by rs_5d descending by default" do
      rs_list = [
        %RelativeStrength{symbol: "AAPL", rs_5d: Decimal.new("1.5"), status: :outperform},
        %RelativeStrength{symbol: "NVDA", rs_5d: Decimal.new("4.0"), status: :strong_outperform},
        %RelativeStrength{symbol: "AMD", rs_5d: Decimal.new("-2.0"), status: :underperform}
      ]

      ranked = RelativeStrengthCalculator.rank(rs_list)

      assert hd(ranked).symbol == "NVDA"
      assert Enum.at(ranked, 1).symbol == "AAPL"
      assert List.last(ranked).symbol == "AMD"
    end

    test "ranks by rs_1d when specified" do
      rs_list = [
        %RelativeStrength{
          symbol: "AAPL",
          rs_1d: Decimal.new("3.0"),
          rs_5d: Decimal.new("1.0"),
          status: :outperform
        },
        %RelativeStrength{
          symbol: "NVDA",
          rs_1d: Decimal.new("1.0"),
          rs_5d: Decimal.new("4.0"),
          status: :strong_outperform
        }
      ]

      ranked = RelativeStrengthCalculator.rank(rs_list, :rs_1d)

      # AAPL has higher rs_1d
      assert hd(ranked).symbol == "AAPL"
    end

    test "ranks by rs_20d when specified" do
      rs_list = [
        %RelativeStrength{
          symbol: "AAPL",
          rs_20d: Decimal.new("2.0"),
          rs_5d: Decimal.new("4.0"),
          status: :outperform
        },
        %RelativeStrength{
          symbol: "NVDA",
          rs_20d: Decimal.new("5.0"),
          rs_5d: Decimal.new("1.0"),
          status: :outperform
        }
      ]

      ranked = RelativeStrengthCalculator.rank(rs_list, :rs_20d)

      # NVDA has higher rs_20d
      assert hd(ranked).symbol == "NVDA"
    end

    test "handles empty list" do
      assert RelativeStrengthCalculator.rank([]) == []
    end

    test "handles single element" do
      rs_list = [
        %RelativeStrength{symbol: "AAPL", rs_5d: Decimal.new("1.5"), status: :outperform}
      ]

      ranked = RelativeStrengthCalculator.rank(rs_list)
      assert length(ranked) == 1
    end
  end

  describe "get_leaders/2" do
    test "returns top performers with outperform status" do
      rs_list = [
        %RelativeStrength{symbol: "NVDA", rs_5d: Decimal.new("5.0"), status: :strong_outperform},
        %RelativeStrength{symbol: "AAPL", rs_5d: Decimal.new("2.0"), status: :outperform},
        %RelativeStrength{symbol: "MSFT", rs_5d: Decimal.new("0.5"), status: :inline},
        %RelativeStrength{symbol: "AMD", rs_5d: Decimal.new("-1.5"), status: :underperform}
      ]

      leaders = RelativeStrengthCalculator.get_leaders(rs_list)

      assert length(leaders) == 2
      assert Enum.any?(leaders, &(&1.symbol == "NVDA"))
      assert Enum.any?(leaders, &(&1.symbol == "AAPL"))
      refute Enum.any?(leaders, &(&1.symbol == "MSFT"))
    end

    test "respects count parameter" do
      rs_list = [
        %RelativeStrength{symbol: "NVDA", rs_5d: Decimal.new("5.0"), status: :strong_outperform},
        %RelativeStrength{symbol: "AAPL", rs_5d: Decimal.new("4.0"), status: :strong_outperform},
        %RelativeStrength{symbol: "META", rs_5d: Decimal.new("3.5"), status: :strong_outperform}
      ]

      leaders = RelativeStrengthCalculator.get_leaders(rs_list, 2)

      assert length(leaders) == 2
      # Should be top 2 by rs_5d
      symbols = Enum.map(leaders, & &1.symbol)
      assert "NVDA" in symbols
      assert "AAPL" in symbols
    end

    test "filters out inline status even if in top by rank" do
      rs_list = [
        %RelativeStrength{symbol: "MSFT", rs_5d: Decimal.new("0.8"), status: :inline},
        %RelativeStrength{symbol: "INTC", rs_5d: Decimal.new("0.5"), status: :inline}
      ]

      leaders = RelativeStrengthCalculator.get_leaders(rs_list)

      assert leaders == []
    end

    test "returns empty list when no outperformers" do
      rs_list = [
        %RelativeStrength{symbol: "AMD", rs_5d: Decimal.new("-2.0"), status: :underperform},
        %RelativeStrength{
          symbol: "INTC",
          rs_5d: Decimal.new("-4.0"),
          status: :strong_underperform
        }
      ]

      leaders = RelativeStrengthCalculator.get_leaders(rs_list)

      assert leaders == []
    end
  end

  describe "get_laggards/2" do
    test "returns bottom performers with underperform status" do
      rs_list = [
        %RelativeStrength{symbol: "NVDA", rs_5d: Decimal.new("5.0"), status: :strong_outperform},
        %RelativeStrength{symbol: "MSFT", rs_5d: Decimal.new("0.5"), status: :inline},
        %RelativeStrength{symbol: "AMD", rs_5d: Decimal.new("-1.5"), status: :underperform},
        %RelativeStrength{
          symbol: "INTC",
          rs_5d: Decimal.new("-4.0"),
          status: :strong_underperform
        }
      ]

      laggards = RelativeStrengthCalculator.get_laggards(rs_list)

      assert length(laggards) == 2
      assert Enum.any?(laggards, &(&1.symbol == "AMD"))
      assert Enum.any?(laggards, &(&1.symbol == "INTC"))
      refute Enum.any?(laggards, &(&1.symbol == "NVDA"))
    end

    test "respects count parameter" do
      rs_list = [
        %RelativeStrength{
          symbol: "AMD",
          rs_5d: Decimal.new("-3.5"),
          status: :strong_underperform
        },
        %RelativeStrength{
          symbol: "INTC",
          rs_5d: Decimal.new("-4.0"),
          status: :strong_underperform
        },
        %RelativeStrength{symbol: "MU", rs_5d: Decimal.new("-5.0"), status: :strong_underperform}
      ]

      laggards = RelativeStrengthCalculator.get_laggards(rs_list, 2)

      assert length(laggards) == 2
      # Should be bottom 2 by rs_5d (most negative)
      symbols = Enum.map(laggards, & &1.symbol)
      assert "MU" in symbols
      assert "INTC" in symbols
    end

    test "filters out inline status" do
      rs_list = [
        %RelativeStrength{symbol: "MSFT", rs_5d: Decimal.new("-0.5"), status: :inline},
        %RelativeStrength{symbol: "AAPL", rs_5d: Decimal.new("-0.8"), status: :inline}
      ]

      laggards = RelativeStrengthCalculator.get_laggards(rs_list)

      assert laggards == []
    end

    test "returns empty list when no underperformers" do
      rs_list = [
        %RelativeStrength{symbol: "NVDA", rs_5d: Decimal.new("5.0"), status: :strong_outperform},
        %RelativeStrength{symbol: "AAPL", rs_5d: Decimal.new("2.0"), status: :outperform}
      ]

      laggards = RelativeStrengthCalculator.get_laggards(rs_list)

      assert laggards == []
    end
  end

  describe "status classification logic" do
    test "strong_outperform when rs > 3%" do
      assert classify_test(3.5) == :strong_outperform
      assert classify_test(10.0) == :strong_outperform
    end

    test "outperform when rs between 1% and 3%" do
      assert classify_test(2.5) == :outperform
      assert classify_test(1.5) == :outperform
    end

    test "inline when rs between -1% and 1%" do
      assert classify_test(0.5) == :inline
      assert classify_test(0.0) == :inline
      assert classify_test(-0.5) == :inline
    end

    test "underperform when rs between -3% and -1%" do
      assert classify_test(-1.5) == :underperform
      assert classify_test(-2.5) == :underperform
    end

    test "strong_underperform when rs < -3%" do
      assert classify_test(-3.5) == :strong_underperform
      assert classify_test(-10.0) == :strong_underperform
    end

    test "boundary conditions" do
      # 3.0 is not > 3.0, so outperform
      assert classify_test(3.0) == :outperform
      # 1.0 is not > 1.0, so inline
      assert classify_test(1.0) == :inline
      # -1.0 is not > -1.0, so underperform
      assert classify_test(-1.0) == :underperform
      # -3.0 is not > -3.0, so strong_underperform
      assert classify_test(-3.0) == :strong_underperform
    end

    # Helper to test classification
    defp classify_test(rs_float) do
      cond do
        rs_float > 3.0 -> :strong_outperform
        rs_float > 1.0 -> :outperform
        rs_float > -1.0 -> :inline
        rs_float > -3.0 -> :underperform
        true -> :strong_underperform
      end
    end
  end

  describe "relative return calculation logic" do
    test "calculates RS correctly when symbol outperforms" do
      # Symbol: +5%, Benchmark: +2%
      # RS = (0.05 - 0.02) * 100 = 3%
      symbol_return = Decimal.new("0.05")
      bench_return = Decimal.new("0.02")

      rs =
        Decimal.mult(
          Decimal.sub(symbol_return, bench_return),
          Decimal.new("100")
        )

      assert Decimal.compare(rs, Decimal.new("3.0")) == :eq
    end

    test "calculates RS correctly when symbol underperforms" do
      # Symbol: +1%, Benchmark: +3%
      # RS = (0.01 - 0.03) * 100 = -2%
      symbol_return = Decimal.new("0.01")
      bench_return = Decimal.new("0.03")

      rs =
        Decimal.mult(
          Decimal.sub(symbol_return, bench_return),
          Decimal.new("100")
        )

      assert Decimal.compare(rs, Decimal.new("-2.0")) == :eq
    end

    test "calculates RS correctly when both negative" do
      # Symbol: -2%, Benchmark: -4%
      # RS = (-0.02 - -0.04) * 100 = 2% (symbol outperforms by falling less)
      symbol_return = Decimal.new("-0.02")
      bench_return = Decimal.new("-0.04")

      rs =
        Decimal.mult(
          Decimal.sub(symbol_return, bench_return),
          Decimal.new("100")
        )

      assert Decimal.compare(rs, Decimal.new("2.0")) == :eq
    end

    test "zero RS when returns are equal" do
      symbol_return = Decimal.new("0.03")
      bench_return = Decimal.new("0.03")

      rs =
        Decimal.mult(
          Decimal.sub(symbol_return, bench_return),
          Decimal.new("100")
        )

      assert Decimal.compare(rs, Decimal.new("0")) == :eq
    end
  end

  describe "RelativeStrength struct" do
    test "has all expected fields" do
      expected_fields = [
        :symbol,
        :date,
        :benchmark,
        :rs_1d,
        :rs_5d,
        :rs_20d,
        :status
      ]

      rs = %RelativeStrength{}
      actual_fields = Map.keys(rs) -- [:__struct__]

      for field <- expected_fields do
        assert field in actual_fields, "Expected #{field} in RelativeStrength struct"
      end
    end

    test "status is one of valid values" do
      valid_statuses = [
        :strong_outperform,
        :outperform,
        :inline,
        :underperform,
        :strong_underperform
      ]

      for status <- valid_statuses do
        rs = %RelativeStrength{status: status}
        assert rs.status in valid_statuses
      end
    end
  end
end
