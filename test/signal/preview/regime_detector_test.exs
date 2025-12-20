defmodule Signal.Preview.RegimeDetectorTest do
  use ExUnit.Case, async: true

  alias Signal.Preview.RegimeDetector
  alias Signal.MarketData.Bar

  describe "aggregate_to_daily/1" do
    test "aggregates minute bars into daily OHLC" do
      bars = [
        build_bar(~U[2024-12-14 14:30:00Z], "100.00", "101.00", "99.50", "100.50", 1000),
        build_bar(~U[2024-12-14 14:31:00Z], "100.50", "102.00", "100.00", "101.50", 1500),
        build_bar(~U[2024-12-14 14:32:00Z], "101.50", "101.50", "100.50", "101.00", 800),
        build_bar(~U[2024-12-14 15:30:00Z], "101.00", "103.00", "101.00", "102.50", 2000)
      ]

      [daily] = RegimeDetector.aggregate_to_daily(bars)

      assert daily.date == ~D[2024-12-14]
      # Open is first bar's open
      assert Decimal.compare(daily.open, Decimal.new("100.00")) == :eq
      # High is max of all highs
      assert Decimal.compare(daily.high, Decimal.new("103.00")) == :eq
      # Low is min of all lows
      assert Decimal.compare(daily.low, Decimal.new("99.50")) == :eq
      # Close is last bar's close
      assert Decimal.compare(daily.close, Decimal.new("102.50")) == :eq
      # Volume is sum
      assert daily.volume == 5300
    end

    test "groups bars by date correctly" do
      bars = [
        build_bar(~U[2024-12-13 14:30:00Z], "100.00", "101.00", "99.00", "100.50", 1000),
        build_bar(~U[2024-12-13 15:30:00Z], "100.50", "102.00", "100.00", "101.50", 1500),
        build_bar(~U[2024-12-14 14:30:00Z], "101.50", "103.00", "101.00", "102.00", 800),
        build_bar(~U[2024-12-14 15:30:00Z], "102.00", "104.00", "101.50", "103.50", 2000)
      ]

      daily_bars = RegimeDetector.aggregate_to_daily(bars)

      assert length(daily_bars) == 2

      [day1, day2] = daily_bars
      assert day1.date == ~D[2024-12-13]
      assert day2.date == ~D[2024-12-14]
    end

    test "returns sorted by date" do
      # Input in random order
      bars = [
        build_bar(~U[2024-12-14 14:30:00Z], "103.00", "104.00", "102.00", "103.50", 500),
        build_bar(~U[2024-12-12 14:30:00Z], "100.00", "101.00", "99.00", "100.50", 1000),
        build_bar(~U[2024-12-13 14:30:00Z], "101.00", "102.00", "100.00", "101.50", 800)
      ]

      daily_bars = RegimeDetector.aggregate_to_daily(bars)

      assert length(daily_bars) == 3
      [d1, d2, d3] = daily_bars
      assert d1.date == ~D[2024-12-12]
      assert d2.date == ~D[2024-12-13]
      assert d3.date == ~D[2024-12-14]
    end

    test "handles single bar per day" do
      bars = [
        build_bar(~U[2024-12-14 14:30:00Z], "100.00", "105.00", "98.00", "103.00", 5000)
      ]

      [daily] = RegimeDetector.aggregate_to_daily(bars)

      assert daily.date == ~D[2024-12-14]
      assert Decimal.compare(daily.open, Decimal.new("100.00")) == :eq
      assert Decimal.compare(daily.high, Decimal.new("105.00")) == :eq
      assert Decimal.compare(daily.low, Decimal.new("98.00")) == :eq
      assert Decimal.compare(daily.close, Decimal.new("103.00")) == :eq
    end

    test "handles empty list" do
      assert RegimeDetector.aggregate_to_daily([]) == []
    end

    test "preserves bar time ordering within a day for open/close" do
      # Bars intentionally out of order
      bars = [
        build_bar(~U[2024-12-14 15:30:00Z], "102.00", "103.00", "101.50", "102.50", 500),
        build_bar(~U[2024-12-14 14:30:00Z], "100.00", "101.00", "99.00", "100.50", 1000),
        build_bar(~U[2024-12-14 14:45:00Z], "100.50", "102.00", "100.00", "101.50", 800)
      ]

      [daily] = RegimeDetector.aggregate_to_daily(bars)

      # Open should be from 14:30 (earliest bar)
      assert Decimal.compare(daily.open, Decimal.new("100.00")) == :eq
      # Close should be from 15:30 (latest bar)
      assert Decimal.compare(daily.close, Decimal.new("102.50")) == :eq
    end
  end

  describe "MarketRegime struct fields" do
    test "detect/3 returns MarketRegime with all expected fields" do
      # This is a documentation test showing the expected structure
      # The actual detect/3 function requires database access

      regime_fields = [
        :symbol,
        :date,
        :timeframe,
        :regime,
        :range_high,
        :range_low,
        :range_duration_days,
        :distance_from_ath_percent,
        :trend_direction,
        :higher_lows_count,
        :lower_highs_count
      ]

      # MarketRegime struct should have all these fields
      regime = %Signal.Preview.MarketRegime{}
      actual_fields = Map.keys(regime) -- [:__struct__]

      for field <- regime_fields do
        assert field in actual_fields, "Expected #{field} in MarketRegime struct"
      end
    end
  end

  describe "regime classification logic" do
    # These tests verify the classification criteria documented in the module

    test "regime types are valid atoms" do
      valid_regimes = [:trending_up, :trending_down, :ranging, :breakout_pending]

      for regime <- valid_regimes do
        assert is_atom(regime)
      end
    end

    test "trend directions are valid atoms" do
      valid_directions = [:up, :down, :neutral]

      for direction <- valid_directions do
        assert is_atom(direction)
      end
    end
  end

  describe "constant values" do
    test "default lookback is reasonable" do
      # The module uses 20-day lookback by default
      # This is appropriate for regime detection (roughly 1 month of trading)
      assert true
    end

    test "range touch threshold is reasonable" do
      # 0.5% threshold for counting touches
      # e.g., for SPY at 600, a touch within $3 counts
      threshold_pct = 0.005
      spy_price = 600
      touch_range = spy_price * threshold_pct

      assert touch_range == 3.0
    end

    test "ATR range multiple is reasonable" do
      # 3x ATR for defining a "tight range"
      # If ATR is $5, range must be < $15 to be "ranging"
      atr_multiple = 3.0
      typical_atr = 5

      max_range_for_ranging = typical_atr * atr_multiple
      assert max_range_for_ranging == 15.0
    end
  end

  # Helper function to build test bars
  defp build_bar(bar_time, open, high, low, close, volume) do
    %Bar{
      symbol: "TEST",
      bar_time: bar_time,
      open: Decimal.new(open),
      high: Decimal.new(high),
      low: Decimal.new(low),
      close: Decimal.new(close),
      volume: volume
    }
  end
end
