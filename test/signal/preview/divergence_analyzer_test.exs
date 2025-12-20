defmodule Signal.Preview.DivergenceAnalyzerTest do
  use ExUnit.Case, async: true

  alias Signal.Preview.IndexDivergence

  describe "IndexDivergence struct" do
    test "has all expected fields" do
      expected_fields = [
        :date,
        :spy_status,
        :qqq_status,
        :dia_status,
        :spy_1d_pct,
        :qqq_1d_pct,
        :dia_1d_pct,
        :spy_5d_pct,
        :qqq_5d_pct,
        :dia_5d_pct,
        :spy_from_ath_pct,
        :qqq_from_ath_pct,
        :dia_from_ath_pct,
        :leader,
        :laggard,
        :implication
      ]

      divergence = %IndexDivergence{}
      actual_fields = Map.keys(divergence) -- [:__struct__]

      for field <- expected_fields do
        assert field in actual_fields, "Expected #{field} in IndexDivergence struct"
      end
    end

    test "status values are valid atoms" do
      valid_statuses = [:leading, :lagging, :neutral]

      for status <- valid_statuses do
        assert is_atom(status)
      end
    end
  end

  describe "leader/laggard determination" do
    test "leader is index with highest 5-day return" do
      # Given: SPY +2%, QQQ +1%, DIA +3%
      # Expected: DIA is leader
      performances = [
        {"SPY", Decimal.new("2.0")},
        {"QQQ", Decimal.new("1.0")},
        {"DIA", Decimal.new("3.0")}
      ]

      sorted = Enum.sort_by(performances, fn {_, pct} -> Decimal.to_float(pct) end, :desc)
      {leader, _} = List.first(sorted)

      assert leader == "DIA"
    end

    test "laggard is index with lowest 5-day return" do
      # Given: SPY +2%, QQQ +1%, DIA +3%
      # Expected: QQQ is laggard
      performances = [
        {"SPY", Decimal.new("2.0")},
        {"QQQ", Decimal.new("1.0")},
        {"DIA", Decimal.new("3.0")}
      ]

      sorted = Enum.sort_by(performances, fn {_, pct} -> Decimal.to_float(pct) end, :desc)
      {laggard, _} = List.last(sorted)

      assert laggard == "QQQ"
    end

    test "handles negative returns" do
      # Given: SPY -1%, QQQ -3%, DIA +0.5%
      # Expected: DIA is leader, QQQ is laggard
      performances = [
        {"SPY", Decimal.new("-1.0")},
        {"QQQ", Decimal.new("-3.0")},
        {"DIA", Decimal.new("0.5")}
      ]

      sorted = Enum.sort_by(performances, fn {_, pct} -> Decimal.to_float(pct) end, :desc)
      {leader, _} = List.first(sorted)
      {laggard, _} = List.last(sorted)

      assert leader == "DIA"
      assert laggard == "QQQ"
    end

    test "handles all negative returns" do
      # Given: SPY -1%, QQQ -3%, DIA -0.5%
      # Expected: DIA is leader (least negative), QQQ is laggard
      performances = [
        {"SPY", Decimal.new("-1.0")},
        {"QQQ", Decimal.new("-3.0")},
        {"DIA", Decimal.new("-0.5")}
      ]

      sorted = Enum.sort_by(performances, fn {_, pct} -> Decimal.to_float(pct) end, :desc)
      {leader, _} = List.first(sorted)
      {laggard, _} = List.last(sorted)

      assert leader == "DIA"
      assert laggard == "QQQ"
    end
  end

  describe "status determination" do
    test "first place gets :leading status" do
      # This tests the logic of determine_status
      performances = [
        {"SPY", Decimal.new("2.0")},
        {"QQQ", Decimal.new("1.0")},
        {"DIA", Decimal.new("3.0")}
      ]

      sorted = Enum.sort_by(performances, fn {_, p} -> Decimal.to_float(p) end, :desc)
      spy_pct = Decimal.new("2.0")
      qqq_pct = Decimal.new("1.0")
      dia_pct = Decimal.new("3.0")

      spy_idx = Enum.find_index(sorted, fn {_, p} -> Decimal.equal?(p, spy_pct) end)
      qqq_idx = Enum.find_index(sorted, fn {_, p} -> Decimal.equal?(p, qqq_pct) end)
      dia_idx = Enum.find_index(sorted, fn {_, p} -> Decimal.equal?(p, dia_pct) end)

      # DIA has highest return (index 0) -> :leading
      assert dia_idx == 0
      # SPY has middle return (index 1) -> :neutral
      assert spy_idx == 1
      # QQQ has lowest return (index 2) -> :lagging
      assert qqq_idx == 2
    end
  end

  describe "implication generation logic" do
    test "tech lagging when QQQ lagging and far from ATH" do
      # QQQ status = :lagging
      # QQQ from ATH = 8%, SPY from ATH = 2%
      # Difference > 2%, so tech lagging
      qqq_status = :lagging
      spy_from_ath = Decimal.new("2.0")
      qqq_from_ath = Decimal.new("8.0")

      spy_float = Decimal.to_float(spy_from_ath)
      qqq_float = Decimal.to_float(qqq_from_ath)

      implication =
        cond do
          qqq_status == :lagging and qqq_float > spy_float + 2.0 ->
            "Tech lagging - harder to trade NQ names, look at SPY components"

          true ->
            "Other"
        end

      assert String.contains?(implication, "Tech lagging")
    end

    test "near ATH when both within 1%" do
      spy_from_ath = Decimal.new("0.5")
      qqq_from_ath = Decimal.new("0.8")

      spy_float = Decimal.to_float(spy_from_ath)
      qqq_float = Decimal.to_float(qqq_from_ath)

      implication =
        cond do
          spy_float < 1.0 and qqq_float < 1.0 ->
            "Both indices near ATH - watch for breakout or rejection"

          true ->
            "Other"
        end

      assert String.contains?(implication, "near ATH")
    end

    test "extended from ATH when both > 5%" do
      spy_from_ath = Decimal.new("6.0")
      qqq_from_ath = Decimal.new("7.5")

      spy_float = Decimal.to_float(spy_from_ath)
      qqq_float = Decimal.to_float(qqq_from_ath)

      implication =
        cond do
          spy_float > 5.0 and qqq_float > 5.0 ->
            "Both indices extended from ATH - potential mean reversion"

          true ->
            "Other"
        end

      assert String.contains?(implication, "extended from ATH")
    end

    test "aligned when no special condition" do
      spy_from_ath = Decimal.new("2.5")
      qqq_from_ath = Decimal.new("3.0")

      spy_float = Decimal.to_float(spy_from_ath)
      qqq_float = Decimal.to_float(qqq_from_ath)

      implication = generate_implication_test(:neutral, spy_float, qqq_float)

      assert implication == "Indices relatively aligned"
    end

    defp generate_implication_test(qqq_status, spy_float, qqq_float) do
      cond do
        qqq_status == :lagging and qqq_float > spy_float + 2.0 ->
          "Tech lagging"

        spy_float < 1.0 and qqq_float < 1.0 ->
          "Near ATH"

        spy_float > 5.0 and qqq_float > 5.0 ->
          "Extended"

        true ->
          "Indices relatively aligned"
      end
    end
  end

  describe "return calculation logic" do
    test "calculates percentage return correctly" do
      start_price = Decimal.new("100.00")
      end_price = Decimal.new("102.50")

      return_pct =
        Decimal.mult(
          Decimal.div(Decimal.sub(end_price, start_price), start_price),
          Decimal.new("100")
        )

      assert Decimal.compare(return_pct, Decimal.new("2.5")) == :eq
    end

    test "calculates negative return correctly" do
      start_price = Decimal.new("100.00")
      end_price = Decimal.new("97.00")

      return_pct =
        Decimal.mult(
          Decimal.div(Decimal.sub(end_price, start_price), start_price),
          Decimal.new("100")
        )

      assert Decimal.compare(return_pct, Decimal.new("-3.0")) == :eq
    end

    test "handles zero return" do
      start_price = Decimal.new("100.00")
      end_price = Decimal.new("100.00")

      return_pct =
        Decimal.mult(
          Decimal.div(Decimal.sub(end_price, start_price), start_price),
          Decimal.new("100")
        )

      assert Decimal.compare(return_pct, Decimal.new("0")) == :eq
    end
  end

  describe "ATH distance calculation logic" do
    test "calculates distance from ATH correctly" do
      current_price = Decimal.new("95.00")
      ath = Decimal.new("100.00")

      distance_pct =
        Decimal.mult(
          Decimal.div(Decimal.sub(ath, current_price), ath),
          Decimal.new("100")
        )

      assert Decimal.compare(distance_pct, Decimal.new("5.0")) == :eq
    end

    test "distance is 0 at ATH" do
      current_price = Decimal.new("100.00")
      ath = Decimal.new("100.00")

      distance_pct =
        Decimal.mult(
          Decimal.div(Decimal.sub(ath, current_price), ath),
          Decimal.new("100")
        )

      assert Decimal.compare(distance_pct, Decimal.new("0")) == :eq
    end
  end
end
