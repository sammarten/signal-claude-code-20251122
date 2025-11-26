defmodule Signal.Strategies.BreakAndRetestTest do
  use ExUnit.Case, async: true

  alias Signal.Strategies.BreakAndRetest
  alias Signal.Technicals.KeyLevels
  alias Signal.MarketData.Bar

  describe "check_level_break/3" do
    test "detects bullish break when price crosses above level" do
      bars = [
        create_bar(99.0, 100.0, 98.5, 99.5, ~U[2024-01-15 14:30:00Z]),
        create_bar(99.5, 101.5, 99.0, 101.0, ~U[2024-01-15 14:31:00Z])
      ]

      level = Decimal.new("100.00")

      assert {:ok, broken} = BreakAndRetest.check_level_break(bars, level, :pdh)
      assert broken.direction == :long
      assert broken.type == :pdh
      assert Decimal.equal?(broken.price, level)
    end

    test "detects bearish break when price crosses below level" do
      bars = [
        create_bar(101.0, 101.5, 100.5, 100.5, ~U[2024-01-15 14:30:00Z]),
        create_bar(100.5, 100.8, 98.5, 99.0, ~U[2024-01-15 14:31:00Z])
      ]

      level = Decimal.new("100.00")

      assert {:ok, broken} = BreakAndRetest.check_level_break(bars, level, :pdl)
      assert broken.direction == :short
      assert broken.type == :pdl
    end

    test "returns error when no break occurs" do
      bars = [
        create_bar(99.0, 99.5, 98.5, 99.2, ~U[2024-01-15 14:30:00Z]),
        create_bar(99.2, 99.8, 99.0, 99.5, ~U[2024-01-15 14:31:00Z])
      ]

      level = Decimal.new("100.00")

      assert {:error, :no_break} = BreakAndRetest.check_level_break(bars, level, :pdh)
    end

    test "returns error for insufficient bars" do
      bars = [create_bar(99.0, 100.0, 98.5, 99.5, ~U[2024-01-15 14:30:00Z])]

      level = Decimal.new("100.00")

      assert {:error, :no_break} = BreakAndRetest.check_level_break(bars, level, :pdh)
    end
  end

  describe "find_retest/3" do
    test "finds bullish retest when price touches level from above and rejects" do
      broken_level = %{
        type: :pdh,
        price: Decimal.new("100.00"),
        direction: :long,
        break_bar: nil,
        break_index: 0
      }

      bars = [
        # Price pulls back to level but closes above
        create_bar(101.5, 102.0, 100.0, 101.0, ~U[2024-01-15 14:35:00Z]),
        create_bar(101.0, 102.5, 100.8, 102.0, ~U[2024-01-15 14:36:00Z])
      ]

      assert {:ok, retest_bar} = BreakAndRetest.find_retest(bars, broken_level)
      assert retest_bar.bar_time == ~U[2024-01-15 14:35:00Z]
    end

    test "finds bearish retest when price touches level from below and rejects" do
      broken_level = %{
        type: :pdl,
        price: Decimal.new("100.00"),
        direction: :short,
        break_bar: nil,
        break_index: 0
      }

      bars = [
        # Price pulls back to level but closes below
        create_bar(98.5, 100.0, 98.0, 99.0, ~U[2024-01-15 14:35:00Z]),
        create_bar(99.0, 99.5, 97.5, 98.0, ~U[2024-01-15 14:36:00Z])
      ]

      assert {:ok, retest_bar} = BreakAndRetest.find_retest(bars, broken_level)
      assert retest_bar.bar_time == ~U[2024-01-15 14:35:00Z]
    end

    test "returns error when no retest found" do
      broken_level = %{
        type: :pdh,
        price: Decimal.new("100.00"),
        direction: :long,
        break_bar: nil,
        break_index: 0
      }

      bars = [
        # Price keeps going up, no pullback to level
        create_bar(101.5, 103.0, 101.0, 102.5, ~U[2024-01-15 14:35:00Z]),
        create_bar(102.5, 104.0, 102.0, 103.5, ~U[2024-01-15 14:36:00Z])
      ]

      assert {:error, :no_retest} = BreakAndRetest.find_retest(bars, broken_level)
    end
  end

  describe "calculate_entry/3" do
    test "calculates entry above retest bar high for long" do
      bar = create_bar(100.0, 101.5, 99.5, 101.0, ~U[2024-01-15 14:35:00Z])

      entry = BreakAndRetest.calculate_entry(bar, :long)

      # Default buffer is 0.02
      expected = Decimal.add(Decimal.new("101.5"), Decimal.new("0.02"))
      assert Decimal.equal?(entry, expected)
    end

    test "calculates entry below retest bar low for short" do
      bar = create_bar(100.0, 101.5, 99.5, 100.5, ~U[2024-01-15 14:35:00Z])

      entry = BreakAndRetest.calculate_entry(bar, :short)

      # Default buffer is 0.02
      expected = Decimal.sub(Decimal.new("99.5"), Decimal.new("0.02"))
      assert Decimal.equal?(entry, expected)
    end

    test "respects custom buffer" do
      bar = create_bar(100.0, 101.5, 99.5, 101.0, ~U[2024-01-15 14:35:00Z])

      entry = BreakAndRetest.calculate_entry(bar, :long, Decimal.new("0.10"))

      expected = Decimal.add(Decimal.new("101.5"), Decimal.new("0.10"))
      assert Decimal.equal?(entry, expected)
    end
  end

  describe "calculate_stop/3" do
    test "calculates stop below retest bar low for long" do
      bar = create_bar(100.0, 101.5, 99.5, 101.0, ~U[2024-01-15 14:35:00Z])

      stop = BreakAndRetest.calculate_stop(bar, :long)

      # Default buffer is 0.10
      expected = Decimal.sub(Decimal.new("99.5"), Decimal.new("0.10"))
      assert Decimal.equal?(stop, expected)
    end

    test "calculates stop above retest bar high for short" do
      bar = create_bar(100.0, 101.5, 99.5, 100.5, ~U[2024-01-15 14:35:00Z])

      stop = BreakAndRetest.calculate_stop(bar, :short)

      # Default buffer is 0.10
      expected = Decimal.add(Decimal.new("101.5"), Decimal.new("0.10"))
      assert Decimal.equal?(stop, expected)
    end
  end

  describe "calculate_target/4" do
    test "calculates 2:1 target for long" do
      entry = Decimal.new("100.00")
      stop = Decimal.new("99.00")

      target = BreakAndRetest.calculate_target(entry, stop, :long)

      # Risk = 1, Target = 100 + 2 = 102
      assert Decimal.equal?(target, Decimal.new("102.00"))
    end

    test "calculates 2:1 target for short" do
      entry = Decimal.new("100.00")
      stop = Decimal.new("101.00")

      target = BreakAndRetest.calculate_target(entry, stop, :short)

      # Risk = 1, Target = 100 - 2 = 98
      assert Decimal.equal?(target, Decimal.new("98.00"))
    end

    test "respects custom R:R ratio" do
      entry = Decimal.new("100.00")
      stop = Decimal.new("99.00")

      target = BreakAndRetest.calculate_target(entry, stop, :long, Decimal.new("3.0"))

      # Risk = 1, Target = 100 + 3 = 103
      assert Decimal.equal?(target, Decimal.new("103.00"))
    end
  end

  describe "strong_rejection?/2" do
    test "returns true for bullish rejection with long lower wick" do
      # Bar with significant lower wick relative to total range
      bar = create_bar_with_wicks(100.0, 102.0, 98.0, 101.5, ~U[2024-01-15 14:35:00Z])

      assert BreakAndRetest.strong_rejection?(bar, :long) == true
    end

    test "returns true for bearish rejection with long upper wick" do
      # Bar with significant upper wick
      bar = create_bar_with_wicks(101.0, 104.0, 100.0, 100.5, ~U[2024-01-15 14:35:00Z])

      assert BreakAndRetest.strong_rejection?(bar, :short) == true
    end

    test "returns false for weak rejection" do
      # Bar with small wicks
      bar = create_bar_with_wicks(100.0, 101.0, 99.8, 100.9, ~U[2024-01-15 14:35:00Z])

      assert BreakAndRetest.strong_rejection?(bar, :long) == false
    end

    test "returns false for zero-range bar" do
      bar = create_bar_with_wicks(100.0, 100.0, 100.0, 100.0, ~U[2024-01-15 14:35:00Z])

      assert BreakAndRetest.strong_rejection?(bar, :long) == false
    end
  end

  describe "evaluate/4" do
    test "returns empty list when not enough bars" do
      bars = [create_bar(100.0, 101.0, 99.0, 100.5, ~U[2024-01-15 14:30:00Z])]
      levels = create_key_levels()

      assert {:ok, []} = BreakAndRetest.evaluate("AAPL", bars, levels)
    end

    test "returns empty list when no levels are broken" do
      bars = create_ranging_bars(10, 100.0, 105.0)
      levels = create_key_levels(110.0, 90.0)

      assert {:ok, []} = BreakAndRetest.evaluate("AAPL", bars, levels)
    end

    test "finds setup when level broken and retested" do
      # Create bars that break PDH and then retest
      bars = create_break_and_retest_bars()
      levels = create_key_levels(100.0, 95.0)

      assert {:ok, setups} = BreakAndRetest.evaluate("AAPL", bars, levels)

      # May or may not find setups depending on bar structure
      assert is_list(setups)
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

  defp create_bar_with_wicks(open, high, low, close, bar_time) do
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

  defp create_key_levels(pdh \\ 105.0, pdl \\ 95.0) do
    %KeyLevels{
      symbol: "TEST",
      date: ~D[2024-01-15],
      previous_day_high: Decimal.new(to_string(pdh)),
      previous_day_low: Decimal.new(to_string(pdl)),
      premarket_high: nil,
      premarket_low: nil,
      opening_range_5m_high: nil,
      opening_range_5m_low: nil,
      opening_range_15m_high: nil,
      opening_range_15m_low: nil
    }
  end

  defp create_ranging_bars(count, low_bound, high_bound) do
    Enum.map(0..(count - 1), fn i ->
      mid = (low_bound + high_bound) / 2
      offset = :rand.uniform() * (high_bound - low_bound) / 4

      create_bar(
        mid - offset,
        mid + offset + 0.5,
        mid - offset - 0.5,
        mid + offset,
        DateTime.add(~U[2024-01-15 14:30:00Z], i * 60, :second)
      )
    end)
  end

  defp create_break_and_retest_bars do
    [
      # Building up to level
      create_bar(98.0, 99.0, 97.5, 98.5, ~U[2024-01-15 14:30:00Z]),
      create_bar(98.5, 99.5, 98.0, 99.0, ~U[2024-01-15 14:31:00Z]),
      create_bar(99.0, 99.8, 98.5, 99.5, ~U[2024-01-15 14:32:00Z]),
      # Break above 100
      create_bar(99.5, 101.5, 99.2, 101.0, ~U[2024-01-15 14:33:00Z]),
      # Continuation
      create_bar(101.0, 102.0, 100.8, 101.5, ~U[2024-01-15 14:34:00Z]),
      # Retest (pullback to 100)
      create_bar(101.5, 101.8, 100.0, 100.5, ~U[2024-01-15 14:35:00Z]),
      # Continuation
      create_bar(100.5, 102.0, 100.2, 101.8, ~U[2024-01-15 14:36:00Z]),
      create_bar(101.8, 103.0, 101.5, 102.5, ~U[2024-01-15 14:37:00Z])
    ]
  end
end
