defmodule Signal.Technicals.SwingsTest do
  use ExUnit.Case, async: true

  alias Signal.Technicals.Swings
  alias Signal.MarketData.Bar

  describe "identify_swings/1 with default lookback" do
    test "finds all swings in a bar series" do
      bars = create_bars_with_swings()

      swings = Swings.identify_swings(bars)

      assert length(swings) > 0
      assert Enum.all?(swings, &(&1.type in [:high, :low]))
      assert Enum.all?(swings, &is_integer(&1.index))
      assert Enum.all?(swings, &(&1.price != nil))
      assert Enum.all?(swings, &(&1.bar_time != nil))
    end

    test "identifies swing highs correctly" do
      bars = [
        create_bar(100.0, ~U[2024-01-01 09:30:00Z]),
        create_bar(101.0, ~U[2024-01-01 09:31:00Z]),
        create_bar(105.0, ~U[2024-01-01 09:32:00Z]),
        # ^^ Swing high at index 2
        create_bar(103.0, ~U[2024-01-01 09:33:00Z]),
        create_bar(102.0, ~U[2024-01-01 09:34:00Z])
      ]

      swings = Swings.identify_swings(bars)

      swing_highs = Enum.filter(swings, &(&1.type == :high))
      assert length(swing_highs) == 1
      assert hd(swing_highs).index == 2
      assert Decimal.equal?(hd(swing_highs).price, Decimal.new("105.0"))
    end

    test "identifies swing lows correctly" do
      bars = [
        create_bar(105.0, ~U[2024-01-01 09:30:00Z]),
        create_bar(103.0, ~U[2024-01-01 09:31:00Z]),
        create_bar(100.0, ~U[2024-01-01 09:32:00Z]),
        # ^^ Swing low at index 2
        create_bar(102.0, ~U[2024-01-01 09:33:00Z]),
        create_bar(104.0, ~U[2024-01-01 09:34:00Z])
      ]

      swings = Swings.identify_swings(bars)

      swing_lows = Enum.filter(swings, &(&1.type == :low))
      assert length(swing_lows) == 1
      assert hd(swing_lows).index == 2
      assert Decimal.equal?(hd(swing_lows).price, Decimal.new("100.0"))
    end
  end

  describe "identify_swings/2 with custom lookback" do
    test "uses custom lookback period" do
      bars = [
        create_bar(100.0, ~U[2024-01-01 09:30:00Z]),
        create_bar(101.0, ~U[2024-01-01 09:31:00Z]),
        create_bar(102.0, ~U[2024-01-01 09:32:00Z]),
        create_bar(110.0, ~U[2024-01-01 09:33:00Z]),
        # ^^ Swing high with lookback 3
        create_bar(105.0, ~U[2024-01-01 09:34:00Z]),
        create_bar(104.0, ~U[2024-01-01 09:35:00Z]),
        create_bar(103.0, ~U[2024-01-01 09:36:00Z])
      ]

      swings = Swings.identify_swings(bars, lookback: 3)

      swing_highs = Enum.filter(swings, &(&1.type == :high))
      assert length(swing_highs) == 1
      assert hd(swing_highs).index == 3
    end

    test "requires more bars with larger lookback" do
      bars = [
        create_bar(100.0, ~U[2024-01-01 09:30:00Z]),
        create_bar(105.0, ~U[2024-01-01 09:31:00Z]),
        create_bar(100.0, ~U[2024-01-01 09:32:00Z])
      ]

      # With lookback 3, need at least 7 bars (3 + 1 + 3)
      swings = Swings.identify_swings(bars, lookback: 3)
      assert swings == []
    end
  end

  describe "identify_swings/1 with insufficient bars" do
    test "returns empty list when not enough bars" do
      bars = [
        create_bar(100.0, ~U[2024-01-01 09:30:00Z]),
        create_bar(105.0, ~U[2024-01-01 09:31:00Z])
      ]

      swings = Swings.identify_swings(bars)
      assert swings == []
    end

    test "returns empty list for empty bars list" do
      swings = Swings.identify_swings([])
      assert swings == []
    end
  end

  describe "swing_high?/3" do
    test "detects valid swing high with lookback 2" do
      bars = [
        create_bar(100.0, ~U[2024-01-01 09:30:00Z]),
        create_bar(101.0, ~U[2024-01-01 09:31:00Z]),
        create_bar(105.0, ~U[2024-01-01 09:32:00Z]),
        create_bar(103.0, ~U[2024-01-01 09:33:00Z]),
        create_bar(102.0, ~U[2024-01-01 09:34:00Z])
      ]

      assert Swings.swing_high?(bars, 2, 2) == true
    end

    test "detects valid swing high with lookback 3" do
      bars = [
        create_bar(100.0, ~U[2024-01-01 09:30:00Z]),
        create_bar(101.0, ~U[2024-01-01 09:31:00Z]),
        create_bar(102.0, ~U[2024-01-01 09:32:00Z]),
        create_bar(110.0, ~U[2024-01-01 09:33:00Z]),
        create_bar(105.0, ~U[2024-01-01 09:34:00Z]),
        create_bar(104.0, ~U[2024-01-01 09:35:00Z]),
        create_bar(103.0, ~U[2024-01-01 09:36:00Z])
      ]

      assert Swings.swing_high?(bars, 3, 3) == true
    end

    test "rejects when bar after is higher" do
      bars = [
        create_bar(100.0, ~U[2024-01-01 09:30:00Z]),
        create_bar(101.0, ~U[2024-01-01 09:31:00Z]),
        create_bar(105.0, ~U[2024-01-01 09:32:00Z]),
        create_bar(106.0, ~U[2024-01-01 09:33:00Z]),
        # Bar after is higher
        create_bar(102.0, ~U[2024-01-01 09:34:00Z])
      ]

      assert Swings.swing_high?(bars, 2, 2) == false
    end

    test "rejects when bar before is higher" do
      bars = [
        create_bar(100.0, ~U[2024-01-01 09:30:00Z]),
        create_bar(106.0, ~U[2024-01-01 09:31:00Z]),
        # Bar before is higher
        create_bar(105.0, ~U[2024-01-01 09:32:00Z]),
        create_bar(103.0, ~U[2024-01-01 09:33:00Z]),
        create_bar(102.0, ~U[2024-01-01 09:34:00Z])
      ]

      assert Swings.swing_high?(bars, 2, 2) == false
    end

    test "handles index out of bounds - too early" do
      bars = create_bars_with_swings()
      assert Swings.swing_high?(bars, 0, 2) == false
      assert Swings.swing_high?(bars, 1, 2) == false
    end

    test "handles index out of bounds - too late" do
      bars = create_bars_with_swings()
      last_index = length(bars) - 1
      assert Swings.swing_high?(bars, last_index, 2) == false
      assert Swings.swing_high?(bars, last_index - 1, 2) == false
    end
  end

  describe "swing_low?/3" do
    test "detects valid swing low with lookback 2" do
      bars = [
        create_bar(105.0, ~U[2024-01-01 09:30:00Z]),
        create_bar(103.0, ~U[2024-01-01 09:31:00Z]),
        create_bar(100.0, ~U[2024-01-01 09:32:00Z]),
        create_bar(102.0, ~U[2024-01-01 09:33:00Z]),
        create_bar(104.0, ~U[2024-01-01 09:34:00Z])
      ]

      assert Swings.swing_low?(bars, 2, 2) == true
    end

    test "detects valid swing low with lookback 3" do
      bars = [
        create_bar(110.0, ~U[2024-01-01 09:30:00Z]),
        create_bar(108.0, ~U[2024-01-01 09:31:00Z]),
        create_bar(106.0, ~U[2024-01-01 09:32:00Z]),
        create_bar(100.0, ~U[2024-01-01 09:33:00Z]),
        create_bar(105.0, ~U[2024-01-01 09:34:00Z]),
        create_bar(106.0, ~U[2024-01-01 09:35:00Z]),
        create_bar(107.0, ~U[2024-01-01 09:36:00Z])
      ]

      assert Swings.swing_low?(bars, 3, 3) == true
    end

    test "rejects when bar after is lower" do
      bars = [
        create_bar(105.0, ~U[2024-01-01 09:30:00Z]),
        create_bar(103.0, ~U[2024-01-01 09:31:00Z]),
        create_bar(100.0, ~U[2024-01-01 09:32:00Z]),
        create_bar(99.0, ~U[2024-01-01 09:33:00Z]),
        # Bar after is lower
        create_bar(104.0, ~U[2024-01-01 09:34:00Z])
      ]

      assert Swings.swing_low?(bars, 2, 2) == false
    end

    test "rejects when bar before is lower" do
      bars = [
        create_bar(105.0, ~U[2024-01-01 09:30:00Z]),
        create_bar(99.0, ~U[2024-01-01 09:31:00Z]),
        # Bar before is lower
        create_bar(100.0, ~U[2024-01-01 09:32:00Z]),
        create_bar(102.0, ~U[2024-01-01 09:33:00Z]),
        create_bar(104.0, ~U[2024-01-01 09:34:00Z])
      ]

      assert Swings.swing_low?(bars, 2, 2) == false
    end

    test "handles index out of bounds - too early" do
      bars = create_bars_with_swings()
      assert Swings.swing_low?(bars, 0, 2) == false
      assert Swings.swing_low?(bars, 1, 2) == false
    end

    test "handles index out of bounds - too late" do
      bars = create_bars_with_swings()
      last_index = length(bars) - 1
      assert Swings.swing_low?(bars, last_index, 2) == false
      assert Swings.swing_low?(bars, last_index - 1, 2) == false
    end
  end

  describe "get_latest_swing/2" do
    test "returns most recent swing high" do
      bars = [
        create_bar(100.0, ~U[2024-01-01 09:30:00Z]),
        create_bar(101.0, ~U[2024-01-01 09:31:00Z]),
        create_bar(105.0, ~U[2024-01-01 09:32:00Z]),
        # First swing high
        create_bar(103.0, ~U[2024-01-01 09:33:00Z]),
        create_bar(102.0, ~U[2024-01-01 09:34:00Z]),
        create_bar(104.0, ~U[2024-01-01 09:35:00Z]),
        create_bar(110.0, ~U[2024-01-01 09:36:00Z]),
        # Second swing high (most recent)
        create_bar(108.0, ~U[2024-01-01 09:37:00Z]),
        create_bar(106.0, ~U[2024-01-01 09:38:00Z])
      ]

      latest = Swings.get_latest_swing(bars, :high)

      assert latest != nil
      assert latest.type == :high
      assert latest.index == 6
      assert Decimal.equal?(latest.price, Decimal.new("110.0"))
    end

    test "returns most recent swing low" do
      bars = [
        create_bar(110.0, ~U[2024-01-01 09:30:00Z]),
        create_bar(108.0, ~U[2024-01-01 09:31:00Z]),
        create_bar(100.0, ~U[2024-01-01 09:32:00Z]),
        # First swing low
        create_bar(102.0, ~U[2024-01-01 09:33:00Z]),
        create_bar(104.0, ~U[2024-01-01 09:34:00Z]),
        create_bar(103.0, ~U[2024-01-01 09:35:00Z]),
        create_bar(95.0, ~U[2024-01-01 09:36:00Z]),
        # Second swing low (most recent)
        create_bar(97.0, ~U[2024-01-01 09:37:00Z]),
        create_bar(99.0, ~U[2024-01-01 09:38:00Z])
      ]

      latest = Swings.get_latest_swing(bars, :low)

      assert latest != nil
      assert latest.type == :low
      assert latest.index == 6
      assert Decimal.equal?(latest.price, Decimal.new("95.0"))
    end

    test "returns nil when no swings of that type exist" do
      bars = [
        create_bar(100.0, ~U[2024-01-01 09:30:00Z]),
        create_bar(101.0, ~U[2024-01-01 09:31:00Z]),
        create_bar(102.0, ~U[2024-01-01 09:32:00Z])
      ]

      assert Swings.get_latest_swing(bars, :high) == nil
      assert Swings.get_latest_swing(bars, :low) == nil
    end
  end

  describe "edge cases" do
    test "single bar - no swings possible" do
      bars = [create_bar(100.0, ~U[2024-01-01 09:30:00Z])]

      swings = Swings.identify_swings(bars)
      assert swings == []
    end

    test "all bars with same high - no swing highs" do
      bars =
        Enum.map(0..10, fn i ->
          %Bar{
            symbol: "TEST",
            bar_time: DateTime.add(~U[2024-01-01 09:30:00Z], i * 60, :second),
            open: Decimal.new("100.0"),
            high: Decimal.new("105.0"),
            # Same high for all
            low: Decimal.new("100.0"),
            close: Decimal.new("100.0"),
            volume: 1000,
            vwap: nil,
            trade_count: nil
          }
        end)

      swings = Swings.identify_swings(bars)
      swing_highs = Enum.filter(swings, &(&1.type == :high))
      assert swing_highs == []
    end

    test "all bars with same low - no swing lows" do
      bars =
        Enum.map(0..10, fn i ->
          %Bar{
            symbol: "TEST",
            bar_time: DateTime.add(~U[2024-01-01 09:30:00Z], i * 60, :second),
            open: Decimal.new("100.0"),
            high: Decimal.new("105.0"),
            low: Decimal.new("95.0"),
            # Same low for all
            close: Decimal.new("100.0"),
            volume: 1000,
            vwap: nil,
            trade_count: nil
          }
        end)

      swings = Swings.identify_swings(bars)
      swing_lows = Enum.filter(swings, &(&1.type == :low))
      assert swing_lows == []
    end

    test "consecutive swing highs" do
      bars = [
        create_bar(100.0, ~U[2024-01-01 09:30:00Z]),
        create_bar(101.0, ~U[2024-01-01 09:31:00Z]),
        create_bar(105.0, ~U[2024-01-01 09:32:00Z]),
        # Swing high 1
        create_bar(103.0, ~U[2024-01-01 09:33:00Z]),
        create_bar(104.0, ~U[2024-01-01 09:34:00Z]),
        create_bar(110.0, ~U[2024-01-01 09:35:00Z]),
        # Swing high 2
        create_bar(108.0, ~U[2024-01-01 09:36:00Z]),
        create_bar(106.0, ~U[2024-01-01 09:37:00Z])
      ]

      swings = Swings.identify_swings(bars)
      swing_highs = Enum.filter(swings, &(&1.type == :high))

      assert length(swing_highs) == 2
      assert Enum.at(swing_highs, 0).index == 2
      assert Enum.at(swing_highs, 1).index == 5
    end

    test "consecutive swing lows" do
      bars = [
        create_bar(110.0, ~U[2024-01-01 09:30:00Z]),
        create_bar(108.0, ~U[2024-01-01 09:31:00Z]),
        create_bar(100.0, ~U[2024-01-01 09:32:00Z]),
        # Swing low 1
        create_bar(102.0, ~U[2024-01-01 09:33:00Z]),
        create_bar(103.0, ~U[2024-01-01 09:34:00Z]),
        create_bar(95.0, ~U[2024-01-01 09:35:00Z]),
        # Swing low 2
        create_bar(97.0, ~U[2024-01-01 09:36:00Z]),
        create_bar(99.0, ~U[2024-01-01 09:37:00Z])
      ]

      swings = Swings.identify_swings(bars)
      swing_lows = Enum.filter(swings, &(&1.type == :low))

      assert length(swing_lows) == 2
      assert Enum.at(swing_lows, 0).index == 2
      assert Enum.at(swing_lows, 1).index == 5
    end
  end

  # Helper functions

  defp create_bar(price, bar_time) do
    %Bar{
      symbol: "TEST",
      bar_time: bar_time,
      open: Decimal.new(to_string(price)),
      high: Decimal.new(to_string(price)),
      low: Decimal.new(to_string(price)),
      close: Decimal.new(to_string(price)),
      volume: 1000,
      vwap: nil,
      trade_count: nil
    }
  end

  defp create_bars_with_swings do
    [
      create_bar(100.0, ~U[2024-01-01 09:30:00Z]),
      create_bar(102.0, ~U[2024-01-01 09:31:00Z]),
      create_bar(105.0, ~U[2024-01-01 09:32:00Z]),
      create_bar(103.0, ~U[2024-01-01 09:33:00Z]),
      create_bar(101.0, ~U[2024-01-01 09:34:00Z]),
      create_bar(103.0, ~U[2024-01-01 09:35:00Z]),
      create_bar(106.0, ~U[2024-01-01 09:36:00Z]),
      create_bar(104.0, ~U[2024-01-01 09:37:00Z]),
      create_bar(102.0, ~U[2024-01-01 09:38:00Z])
    ]
  end
end
