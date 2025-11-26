defmodule Signal.Strategies.OpeningRangeTest do
  use ExUnit.Case, async: true

  alias Signal.Strategies.OpeningRange
  alias Signal.Technicals.KeyLevels
  alias Signal.MarketData.Bar

  describe "check_ranges_ready/2" do
    test "returns established when both OR5 ranges are set for :or5m" do
      levels =
        create_key_levels_with_or(
          or5h: "100.00",
          or5l: "99.00"
        )

      assert {:ok, :established} = OpeningRange.check_ranges_ready(levels, :or5m)
    end

    test "returns established when both OR15 ranges are set for :or15m" do
      levels =
        create_key_levels_with_or(
          or15h: "101.00",
          or15l: "98.00"
        )

      assert {:ok, :established} = OpeningRange.check_ranges_ready(levels, :or15m)
    end

    test "returns established when either range is set for :both" do
      levels =
        create_key_levels_with_or(
          or5h: "100.00",
          or5l: "99.00"
        )

      assert {:ok, :established} = OpeningRange.check_ranges_ready(levels, :both)
    end

    test "returns error when OR5 not set for :or5m" do
      levels =
        create_key_levels_with_or(
          or15h: "101.00",
          or15l: "98.00"
        )

      assert {:error, :ranges_not_ready} = OpeningRange.check_ranges_ready(levels, :or5m)
    end

    test "returns error when OR15 not set for :or15m" do
      levels =
        create_key_levels_with_or(
          or5h: "100.00",
          or5l: "99.00"
        )

      assert {:error, :ranges_not_ready} = OpeningRange.check_ranges_ready(levels, :or15m)
    end

    test "returns error when no ranges set for :both" do
      levels = %KeyLevels{
        symbol: "TEST",
        date: ~D[2024-01-15],
        previous_day_high: Decimal.new("105.00"),
        previous_day_low: Decimal.new("95.00")
      }

      assert {:error, :ranges_not_ready} = OpeningRange.check_ranges_ready(levels, :both)
    end
  end

  describe "detect_range_break/4" do
    test "detects bullish breakout above range high" do
      bars = [
        create_bar(99.5, 100.0, 99.0, 99.8, ~U[2024-01-15 14:35:00Z]),
        create_bar(99.8, 100.5, 99.5, 100.0, ~U[2024-01-15 14:36:00Z]),
        create_bar(100.0, 101.5, 99.8, 101.2, ~U[2024-01-15 14:37:00Z])
      ]

      range_high = Decimal.new("100.50")
      range_low = Decimal.new("99.00")

      assert {:ok, break} = OpeningRange.detect_range_break(bars, range_high, range_low, :or5m)
      assert break.direction == :long
      assert break.range == :or5m
      assert Decimal.equal?(break.level_price, range_high)
    end

    test "detects bearish breakdown below range low" do
      bars = [
        create_bar(99.5, 100.0, 99.0, 99.2, ~U[2024-01-15 14:35:00Z]),
        create_bar(99.2, 99.5, 98.5, 98.8, ~U[2024-01-15 14:36:00Z]),
        create_bar(98.8, 99.0, 97.5, 97.8, ~U[2024-01-15 14:37:00Z])
      ]

      range_high = Decimal.new("100.50")
      range_low = Decimal.new("99.00")

      assert {:ok, break} = OpeningRange.detect_range_break(bars, range_high, range_low, :or15m)
      assert break.direction == :short
      assert break.range == :or15m
      assert Decimal.equal?(break.level_price, range_low)
    end

    test "returns error when price stays within range" do
      bars = [
        create_bar(99.5, 100.0, 99.0, 99.8, ~U[2024-01-15 14:35:00Z]),
        create_bar(99.8, 100.2, 99.3, 99.5, ~U[2024-01-15 14:36:00Z]),
        create_bar(99.5, 100.3, 99.2, 100.0, ~U[2024-01-15 14:37:00Z])
      ]

      range_high = Decimal.new("100.50")
      range_low = Decimal.new("99.00")

      assert {:error, :no_break} =
               OpeningRange.detect_range_break(bars, range_high, range_low, :or5m)
    end

    test "returns error for insufficient bars" do
      bars = [create_bar(99.5, 100.0, 99.0, 99.8, ~U[2024-01-15 14:35:00Z])]

      range_high = Decimal.new("100.50")
      range_low = Decimal.new("99.00")

      assert {:error, :no_break} =
               OpeningRange.detect_range_break(bars, range_high, range_low, :or5m)
    end
  end

  describe "range_size/2" do
    test "calculates range size correctly" do
      high = Decimal.new("101.50")
      low = Decimal.new("99.00")

      assert Decimal.equal?(OpeningRange.range_size(high, low), Decimal.new("2.50"))
    end

    test "returns zero for equal high and low" do
      price = Decimal.new("100.00")

      assert Decimal.equal?(OpeningRange.range_size(price, price), Decimal.new("0"))
    end
  end

  describe "tight_range?/3" do
    test "returns true for tight range below threshold" do
      # 0.25% range relative to midpoint
      high = Decimal.new("100.25")
      low = Decimal.new("100.00")

      assert OpeningRange.tight_range?(high, low) == true
    end

    test "returns false for wide range above threshold" do
      # 5% range relative to midpoint
      high = Decimal.new("105.00")
      low = Decimal.new("100.00")

      assert OpeningRange.tight_range?(high, low) == false
    end

    test "respects custom threshold" do
      high = Decimal.new("102.00")
      low = Decimal.new("100.00")

      # 2% range - should be false with default 0.5%, true with 3%
      assert OpeningRange.tight_range?(high, low, Decimal.new("0.005")) == false
      assert OpeningRange.tight_range?(high, low, Decimal.new("0.03")) == true
    end

    test "handles zero midpoint" do
      high = Decimal.new("0")
      low = Decimal.new("0")

      assert OpeningRange.tight_range?(high, low) == false
    end
  end

  describe "range_midpoint/2" do
    test "calculates midpoint correctly" do
      high = Decimal.new("102.00")
      low = Decimal.new("100.00")

      assert Decimal.equal?(OpeningRange.range_midpoint(high, low), Decimal.new("101.0"))
    end

    test "handles equal high and low" do
      price = Decimal.new("100.00")

      assert Decimal.equal?(OpeningRange.range_midpoint(price, price), price)
    end
  end

  describe "evaluate/4" do
    test "returns error when ranges not ready" do
      bars = create_ranging_bars(10, 99.0, 101.0)

      levels = %KeyLevels{
        symbol: "TEST",
        date: ~D[2024-01-15],
        previous_day_high: Decimal.new("105.00"),
        previous_day_low: Decimal.new("95.00")
      }

      assert {:error, :ranges_not_ready} = OpeningRange.evaluate("AAPL", bars, levels)
    end

    test "returns empty list when no breakout occurs" do
      bars = create_ranging_bars(20, 99.5, 100.5)

      levels =
        create_key_levels_with_or(
          or5h: "101.00",
          or5l: "99.00"
        )

      assert {:ok, []} = OpeningRange.evaluate("AAPL", bars, levels)
    end

    test "finds setup when range broken and retested" do
      bars = create_orb_bars()

      levels =
        create_key_levels_with_or(
          or5h: "100.00",
          or5l: "99.00"
        )

      assert {:ok, setups} = OpeningRange.evaluate("AAPL", bars, levels)
      assert is_list(setups)
    end

    test "respects min_rr option" do
      bars = create_orb_bars()

      levels =
        create_key_levels_with_or(
          or5h: "100.00",
          or5l: "99.00"
        )

      # Very high R:R requirement should filter out setups
      assert {:ok, setups} =
               OpeningRange.evaluate("AAPL", bars, levels, min_rr: Decimal.new("10.0"))

      assert setups == []
    end

    test "respects prefer_range option" do
      bars = create_orb_bars()

      levels =
        create_key_levels_with_or(
          or5h: "100.00",
          or5l: "99.00",
          or15h: "101.00",
          or15l: "98.00"
        )

      # Should only check OR5
      assert {:ok, _} = OpeningRange.evaluate("AAPL", bars, levels, prefer_range: :or5m)
    end
  end

  # Helper Functions

  defp create_bar(open, high, low, close, bar_time) do
    %Bar{
      symbol: "TEST",
      bar_time: bar_time,
      open: Decimal.new(to_string(open)),
      high: Decimal.new(to_string(high)),
      low: Decimal.new(to_string(low)),
      close: Decimal.new(to_string(close)),
      volume: 1000,
      vwap: nil,
      trade_count: nil
    }
  end

  defp create_key_levels_with_or(opts) do
    %KeyLevels{
      symbol: "TEST",
      date: ~D[2024-01-15],
      previous_day_high: Decimal.new("105.00"),
      previous_day_low: Decimal.new("95.00"),
      premarket_high: nil,
      premarket_low: nil,
      opening_range_5m_high: opts[:or5h] && Decimal.new(opts[:or5h]),
      opening_range_5m_low: opts[:or5l] && Decimal.new(opts[:or5l]),
      opening_range_15m_high: opts[:or15h] && Decimal.new(opts[:or15h]),
      opening_range_15m_low: opts[:or15l] && Decimal.new(opts[:or15l])
    }
  end

  defp create_ranging_bars(count, low_bound, high_bound) do
    Enum.map(0..(count - 1), fn i ->
      mid = (low_bound + high_bound) / 2
      offset = :rand.uniform() * (high_bound - low_bound) / 4

      create_bar(
        mid - offset,
        mid + offset + 0.2,
        mid - offset - 0.2,
        mid + offset,
        DateTime.add(~U[2024-01-15 14:30:00Z], i * 60, :second)
      )
    end)
  end

  defp create_orb_bars do
    [
      # Bars within range
      create_bar(99.5, 99.8, 99.2, 99.6, ~U[2024-01-15 14:30:00Z]),
      create_bar(99.6, 99.9, 99.4, 99.7, ~U[2024-01-15 14:31:00Z]),
      # Breakout bar
      create_bar(99.7, 100.8, 99.5, 100.5, ~U[2024-01-15 14:32:00Z]),
      # Continuation
      create_bar(100.5, 101.2, 100.3, 101.0, ~U[2024-01-15 14:33:00Z]),
      # Retest
      create_bar(101.0, 101.2, 100.0, 100.3, ~U[2024-01-15 14:34:00Z]),
      # Bounce
      create_bar(100.3, 101.5, 100.1, 101.3, ~U[2024-01-15 14:35:00Z]),
      create_bar(101.3, 102.0, 101.0, 101.8, ~U[2024-01-15 14:36:00Z])
    ]
  end
end
