defmodule Signal.Preview.PremarketAnalyzerTest do
  use ExUnit.Case, async: true

  alias Signal.Preview.{PremarketAnalyzer, PremarketSnapshot}
  alias Signal.Technicals.KeyLevels

  describe "analyze_with_data/3" do
    setup do
      levels = %KeyLevels{
        symbol: "AAPL",
        date: ~D[2024-12-14],
        previous_day_high: Decimal.new("180.00"),
        previous_day_low: Decimal.new("175.00"),
        previous_day_close: Decimal.new("178.00"),
        premarket_high: Decimal.new("181.00"),
        premarket_low: Decimal.new("177.50")
      }

      {:ok, levels: levels}
    end

    test "returns PremarketSnapshot struct", %{levels: levels} do
      current_price = Decimal.new("179.00")
      snapshot = PremarketAnalyzer.analyze_with_data(:AAPL, current_price, levels)

      assert %PremarketSnapshot{} = snapshot
      assert snapshot.symbol == "AAPL"
      assert Decimal.compare(snapshot.current_price, current_price) == :eq
    end

    test "calculates gap percent correctly", %{levels: levels} do
      # Price at 181.56 is +2% from close of 178.00
      current_price = Decimal.new("181.56")
      snapshot = PremarketAnalyzer.analyze_with_data(:AAPL, current_price, levels)

      expected_gap = Decimal.new("2.0")
      assert Decimal.compare(Decimal.round(snapshot.gap_percent, 1), expected_gap) == :eq
    end

    test "calculates negative gap correctly", %{levels: levels} do
      # Price at 174.78 is -1.8% from close of 178.00
      current_price = Decimal.new("174.78")
      snapshot = PremarketAnalyzer.analyze_with_data(:AAPL, current_price, levels)

      assert Decimal.compare(snapshot.gap_percent, Decimal.new("0")) == :lt
    end

    test "includes premarket high/low from levels", %{levels: levels} do
      current_price = Decimal.new("179.00")
      snapshot = PremarketAnalyzer.analyze_with_data(:AAPL, current_price, levels)

      assert Decimal.compare(snapshot.premarket_high, Decimal.new("181.00")) == :eq
      assert Decimal.compare(snapshot.premarket_low, Decimal.new("177.50")) == :eq
    end

    test "includes timestamp", %{levels: levels} do
      current_price = Decimal.new("179.00")
      snapshot = PremarketAnalyzer.analyze_with_data(:AAPL, current_price, levels)

      assert %DateTime{} = snapshot.timestamp
    end
  end

  describe "gap direction determination" do
    setup do
      levels = %KeyLevels{
        symbol: "AAPL",
        date: ~D[2024-12-14],
        previous_day_high: Decimal.new("180.00"),
        previous_day_low: Decimal.new("175.00"),
        previous_day_close: Decimal.new("100.00")
      }

      {:ok, levels: levels}
    end

    test "gap up when > 0.5%", %{levels: levels} do
      # 1% gap up
      current_price = Decimal.new("101.00")
      snapshot = PremarketAnalyzer.analyze_with_data(:AAPL, current_price, levels)

      assert snapshot.gap_direction == :up
    end

    test "gap down when < -0.5%", %{levels: levels} do
      # 1% gap down
      current_price = Decimal.new("99.00")
      snapshot = PremarketAnalyzer.analyze_with_data(:AAPL, current_price, levels)

      assert snapshot.gap_direction == :down
    end

    test "flat when between -0.5% and 0.5%", %{levels: levels} do
      # 0.3% gap - within threshold
      current_price = Decimal.new("100.30")
      snapshot = PremarketAnalyzer.analyze_with_data(:AAPL, current_price, levels)

      assert snapshot.gap_direction == :flat
    end

    test "flat at exactly 0.5% threshold", %{levels: levels} do
      # Exactly 0.5% gap
      current_price = Decimal.new("100.50")
      snapshot = PremarketAnalyzer.analyze_with_data(:AAPL, current_price, levels)

      # 0.5% is not > 0.5%, so should be flat
      assert snapshot.gap_direction == :flat
    end

    test "gap up just above 0.5% threshold", %{levels: levels} do
      # 0.51% gap
      current_price = Decimal.new("100.51")
      snapshot = PremarketAnalyzer.analyze_with_data(:AAPL, current_price, levels)

      assert snapshot.gap_direction == :up
    end
  end

  describe "position in range determination" do
    setup do
      # Range is 175.00 to 180.00 (5 point range)
      # 10% of range = 0.50
      # Near high threshold = 180.00 - 0.50 = 179.50
      # Near low threshold = 175.00 + 0.50 = 175.50
      levels = %KeyLevels{
        symbol: "AAPL",
        date: ~D[2024-12-14],
        previous_day_high: Decimal.new("180.00"),
        previous_day_low: Decimal.new("175.00"),
        previous_day_close: Decimal.new("177.50")
      }

      {:ok, levels: levels}
    end

    test "above_prev_day_high when price > previous high", %{levels: levels} do
      current_price = Decimal.new("181.00")
      snapshot = PremarketAnalyzer.analyze_with_data(:AAPL, current_price, levels)

      assert snapshot.position_in_range == :above_prev_day_high
    end

    test "near_prev_day_high when price within 10% of high", %{levels: levels} do
      # 179.50 is within 10% of range from high
      current_price = Decimal.new("179.50")
      snapshot = PremarketAnalyzer.analyze_with_data(:AAPL, current_price, levels)

      assert snapshot.position_in_range == :near_prev_day_high
    end

    test "below_prev_day_low when price < previous low", %{levels: levels} do
      current_price = Decimal.new("174.00")
      snapshot = PremarketAnalyzer.analyze_with_data(:AAPL, current_price, levels)

      assert snapshot.position_in_range == :below_prev_day_low
    end

    test "near_prev_day_low when price within 10% of low", %{levels: levels} do
      # 175.50 is within 10% of range from low
      current_price = Decimal.new("175.50")
      snapshot = PremarketAnalyzer.analyze_with_data(:AAPL, current_price, levels)

      assert snapshot.position_in_range == :near_prev_day_low
    end

    test "middle_of_range when price in middle", %{levels: levels} do
      current_price = Decimal.new("177.50")
      snapshot = PremarketAnalyzer.analyze_with_data(:AAPL, current_price, levels)

      assert snapshot.position_in_range == :middle_of_range
    end

    test "exactly at high is not above", %{levels: levels} do
      current_price = Decimal.new("180.00")
      snapshot = PremarketAnalyzer.analyze_with_data(:AAPL, current_price, levels)

      # At high (not above), should be near_prev_day_high
      assert snapshot.position_in_range == :near_prev_day_high
    end

    test "exactly at low is not below", %{levels: levels} do
      current_price = Decimal.new("175.00")
      snapshot = PremarketAnalyzer.analyze_with_data(:AAPL, current_price, levels)

      # At low (not below), should be near_prev_day_low
      assert snapshot.position_in_range == :near_prev_day_low
    end
  end

  describe "position in range with larger range" do
    setup do
      # Range is 100.00 to 200.00 (100 point range)
      # 10% of range = 10.00
      # Near high threshold = 200.00 - 10.00 = 190.00
      # Near low threshold = 100.00 + 10.00 = 110.00
      levels = %KeyLevels{
        symbol: "TEST",
        date: ~D[2024-12-14],
        previous_day_high: Decimal.new("200.00"),
        previous_day_low: Decimal.new("100.00"),
        previous_day_close: Decimal.new("150.00")
      }

      {:ok, levels: levels}
    end

    test "correctly identifies near_high with larger range", %{levels: levels} do
      current_price = Decimal.new("192.00")
      snapshot = PremarketAnalyzer.analyze_with_data(:TEST, current_price, levels)

      assert snapshot.position_in_range == :near_prev_day_high
    end

    test "correctly identifies near_low with larger range", %{levels: levels} do
      current_price = Decimal.new("105.00")
      snapshot = PremarketAnalyzer.analyze_with_data(:TEST, current_price, levels)

      assert snapshot.position_in_range == :near_prev_day_low
    end

    test "correctly identifies middle with larger range", %{levels: levels} do
      current_price = Decimal.new("150.00")
      snapshot = PremarketAnalyzer.analyze_with_data(:TEST, current_price, levels)

      assert snapshot.position_in_range == :middle_of_range
    end
  end

  describe "gap percent calculation edge cases" do
    test "handles nil previous close by falling back to previous_day_low" do
      levels = %KeyLevels{
        symbol: "TEST",
        date: ~D[2024-12-14],
        previous_day_high: Decimal.new("180.00"),
        previous_day_low: Decimal.new("175.00"),
        previous_day_close: nil
      }

      current_price = Decimal.new("180.25")
      snapshot = PremarketAnalyzer.analyze_with_data(:TEST, current_price, levels)

      # Gap calculated from previous_day_low (175.00) to 180.25 = 3%
      assert Decimal.compare(snapshot.previous_close, Decimal.new("175.00")) == :eq
      assert Decimal.compare(snapshot.gap_percent, Decimal.new("0")) != :eq
    end

    test "handles zero gap" do
      levels = %KeyLevels{
        symbol: "TEST",
        date: ~D[2024-12-14],
        previous_day_high: Decimal.new("180.00"),
        previous_day_low: Decimal.new("175.00"),
        previous_day_close: Decimal.new("178.00")
      }

      current_price = Decimal.new("178.00")
      snapshot = PremarketAnalyzer.analyze_with_data(:TEST, current_price, levels)

      assert Decimal.compare(snapshot.gap_percent, Decimal.new("0")) == :eq
      assert snapshot.gap_direction == :flat
    end
  end

  describe "PremarketSnapshot struct" do
    test "has all expected fields" do
      expected_fields = [
        :symbol,
        :timestamp,
        :current_price,
        :previous_close,
        :gap_percent,
        :gap_direction,
        :premarket_high,
        :premarket_low,
        :premarket_volume,
        :position_in_range
      ]

      snapshot = %PremarketSnapshot{}
      actual_fields = Map.keys(snapshot) -- [:__struct__]

      for field <- expected_fields do
        assert field in actual_fields, "Expected #{field} in PremarketSnapshot struct"
      end
    end

    test "gap_direction is one of valid values" do
      valid_directions = [:up, :down, :flat]

      for direction <- valid_directions do
        snapshot = %PremarketSnapshot{gap_direction: direction}
        assert snapshot.gap_direction in valid_directions
      end
    end

    test "position_in_range is one of valid values" do
      valid_positions = [
        :above_prev_day_high,
        :near_prev_day_high,
        :middle_of_range,
        :near_prev_day_low,
        :below_prev_day_low
      ]

      for position <- valid_positions do
        snapshot = %PremarketSnapshot{position_in_range: position}
        assert snapshot.position_in_range in valid_positions
      end
    end
  end
end
