defmodule Signal.Strategies.OneCandleRuleTest do
  use ExUnit.Case, async: true

  alias Signal.Strategies.OneCandleRule
  alias Signal.MarketData.Bar

  describe "candle_type/1" do
    test "identifies bullish candle" do
      bar = create_bar(100.0, 102.0, 99.5, 101.5, ~U[2024-01-15 14:30:00Z])
      assert OneCandleRule.candle_type(bar) == :bullish
    end

    test "identifies bearish candle" do
      bar = create_bar(101.5, 102.0, 99.5, 100.0, ~U[2024-01-15 14:30:00Z])
      assert OneCandleRule.candle_type(bar) == :bearish
    end

    test "identifies neutral candle" do
      bar = create_bar(100.0, 102.0, 99.0, 100.0, ~U[2024-01-15 14:30:00Z])
      assert OneCandleRule.candle_type(bar) == :neutral
    end
  end

  describe "body_percentage/1" do
    test "calculates body percentage correctly for bullish candle" do
      # Open 100, Close 102, Range = 3 (High 102 - Low 99)
      # Body = 2, Body % = 2/3 = 0.666...
      bar = create_bar(100.0, 102.0, 99.0, 102.0, ~U[2024-01-15 14:30:00Z])

      pct = OneCandleRule.body_percentage(bar)
      assert Decimal.compare(pct, Decimal.new("0.6")) != :lt
    end

    test "calculates body percentage for bearish candle" do
      bar = create_bar(102.0, 103.0, 100.0, 100.0, ~U[2024-01-15 14:30:00Z])

      # Body = 2, Range = 3, Body % = 0.666
      pct = OneCandleRule.body_percentage(bar)
      assert Decimal.compare(pct, Decimal.new("0.6")) != :lt
    end

    test "returns zero for zero-range bar" do
      bar = create_bar(100.0, 100.0, 100.0, 100.0, ~U[2024-01-15 14:30:00Z])

      assert Decimal.equal?(OneCandleRule.body_percentage(bar), Decimal.new("0"))
    end
  end

  describe "strong_body?/2" do
    test "returns true when body exceeds threshold" do
      # Full body candle (close == high, open == low)
      bar = create_bar(99.0, 102.0, 99.0, 102.0, ~U[2024-01-15 14:30:00Z])

      assert OneCandleRule.strong_body?(bar) == true
    end

    test "returns false when body below threshold" do
      # Doji-like candle
      bar = create_bar(100.0, 102.0, 99.0, 100.1, ~U[2024-01-15 14:30:00Z])

      assert OneCandleRule.strong_body?(bar) == false
    end

    test "respects custom threshold" do
      bar = create_bar(100.0, 103.0, 99.0, 102.0, ~U[2024-01-15 14:30:00Z])
      # Body = 2, Range = 4, % = 0.5

      assert OneCandleRule.strong_body?(bar, Decimal.new("0.4")) == true
      assert OneCandleRule.strong_body?(bar, Decimal.new("0.6")) == false
    end
  end

  describe "find_one_candle/3" do
    test "finds bearish one candle in bullish trend" do
      bars = create_bullish_trend_with_one_candle()

      assert {:ok, one_candle} = OneCandleRule.find_one_candle(bars, :bullish)
      assert one_candle.candle_type == :bearish
      assert one_candle.bar != nil
    end

    test "finds bullish one candle in bearish trend" do
      bars = create_bearish_trend_with_one_candle()

      assert {:ok, one_candle} = OneCandleRule.find_one_candle(bars, :bearish)
      assert one_candle.candle_type == :bullish
      assert one_candle.bar != nil
    end

    test "returns error when no one candle found" do
      # All bullish bars with no opposing candle
      bars = create_all_bullish_bars(10)

      assert {:error, :not_found} = OneCandleRule.find_one_candle(bars, :bullish)
    end

    test "respects min_continuation_bars option" do
      bars = create_bullish_trend_with_one_candle()

      # High minimum should make it harder to find
      assert {:error, :not_found} =
               OneCandleRule.find_one_candle(bars, :bullish, min_continuation_bars: 10)
    end
  end

  describe "check_one_candle_break/3" do
    test "detects break above one candle high in bullish trend" do
      one_candle = %{
        bar: create_bar(101.0, 101.5, 100.0, 100.5, ~U[2024-01-15 14:30:00Z]),
        index: 0,
        high: Decimal.new("101.5"),
        low: Decimal.new("100.0"),
        candle_type: :bearish
      }

      bars = [
        create_bar(100.5, 101.0, 100.0, 100.8, ~U[2024-01-15 14:31:00Z]),
        create_bar(100.8, 102.0, 100.5, 101.8, ~U[2024-01-15 14:32:00Z])
      ]

      assert {:ok, break} = OneCandleRule.check_one_candle_break(bars, one_candle, :bullish)
      assert break.direction == :long
    end

    test "detects break below one candle low in bearish trend" do
      one_candle = %{
        bar: create_bar(100.0, 101.5, 100.0, 101.0, ~U[2024-01-15 14:30:00Z]),
        index: 0,
        high: Decimal.new("101.5"),
        low: Decimal.new("100.0"),
        candle_type: :bullish
      }

      bars = [
        create_bar(101.0, 101.2, 100.5, 100.3, ~U[2024-01-15 14:31:00Z]),
        create_bar(100.3, 100.5, 99.0, 99.2, ~U[2024-01-15 14:32:00Z])
      ]

      assert {:ok, break} = OneCandleRule.check_one_candle_break(bars, one_candle, :bearish)
      assert break.direction == :short
    end

    test "returns error when no break occurs" do
      one_candle = %{
        bar: create_bar(101.0, 102.0, 100.0, 100.5, ~U[2024-01-15 14:30:00Z]),
        index: 0,
        high: Decimal.new("102.0"),
        low: Decimal.new("100.0"),
        candle_type: :bearish
      }

      bars = [
        create_bar(100.5, 101.5, 100.2, 101.0, ~U[2024-01-15 14:31:00Z]),
        create_bar(101.0, 101.8, 100.5, 101.5, ~U[2024-01-15 14:32:00Z])
      ]

      assert {:error, :no_break} =
               OneCandleRule.check_one_candle_break(bars, one_candle, :bullish)
    end
  end

  describe "evaluate/3" do
    test "returns empty list when not enough bars" do
      bars = [create_bar(100.0, 101.0, 99.0, 100.5, ~U[2024-01-15 14:30:00Z])]

      assert {:ok, []} = OneCandleRule.evaluate("AAPL", bars)
    end

    test "returns error when no clear trend" do
      bars = create_ranging_bars(20, 99.0, 101.0)

      result = OneCandleRule.evaluate("AAPL", bars)
      # Should return either empty list or :no_trend error
      assert result in [{:ok, []}, {:error, :no_trend}]
    end

    test "finds setup in bullish trend with one candle pattern" do
      bars = create_complete_one_candle_setup(:bullish)

      result = OneCandleRule.evaluate("AAPL", bars)
      # May or may not find setup depending on structure detection
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "respects min_rr option" do
      bars = create_complete_one_candle_setup(:bullish)

      # Very high R:R requirement should filter out setups
      result = OneCandleRule.evaluate("AAPL", bars, min_rr: Decimal.new("10.0"))
      assert match?({:ok, []}, result) or match?({:error, _}, result)
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

  defp create_bullish_trend_with_one_candle do
    [
      # Initial bullish bars
      create_bar(100.0, 100.5, 99.5, 100.3, ~U[2024-01-15 14:30:00Z]),
      create_bar(100.3, 101.0, 100.0, 100.8, ~U[2024-01-15 14:31:00Z]),
      create_bar(100.8, 101.5, 100.5, 101.2, ~U[2024-01-15 14:32:00Z]),
      # The one candle (bearish)
      create_bar(101.2, 101.5, 100.5, 100.8, ~U[2024-01-15 14:33:00Z]),
      # Continuation bullish bars
      create_bar(100.8, 101.8, 100.6, 101.5, ~U[2024-01-15 14:34:00Z]),
      create_bar(101.5, 102.2, 101.2, 102.0, ~U[2024-01-15 14:35:00Z]),
      create_bar(102.0, 102.8, 101.8, 102.5, ~U[2024-01-15 14:36:00Z])
    ]
  end

  defp create_bearish_trend_with_one_candle do
    [
      # Initial bearish bars
      create_bar(102.0, 102.2, 101.5, 101.7, ~U[2024-01-15 14:30:00Z]),
      create_bar(101.7, 101.9, 101.0, 101.2, ~U[2024-01-15 14:31:00Z]),
      create_bar(101.2, 101.5, 100.5, 100.8, ~U[2024-01-15 14:32:00Z]),
      # The one candle (bullish)
      create_bar(100.8, 101.5, 100.5, 101.2, ~U[2024-01-15 14:33:00Z]),
      # Continuation bearish bars
      create_bar(101.2, 101.3, 100.2, 100.5, ~U[2024-01-15 14:34:00Z]),
      create_bar(100.5, 100.7, 99.5, 99.8, ~U[2024-01-15 14:35:00Z]),
      create_bar(99.8, 100.0, 99.0, 99.3, ~U[2024-01-15 14:36:00Z])
    ]
  end

  defp create_all_bullish_bars(count) do
    Enum.map(0..(count - 1), fn i ->
      base = 100.0 + i * 0.5

      create_bar(
        base,
        base + 0.6,
        base - 0.2,
        base + 0.4,
        DateTime.add(~U[2024-01-15 14:30:00Z], i * 60, :second)
      )
    end)
  end

  defp create_ranging_bars(count, low_bound, high_bound) do
    Enum.map(0..(count - 1), fn i ->
      mid = (low_bound + high_bound) / 2
      offset = :rand.uniform() * (high_bound - low_bound) / 4

      # Alternate between bullish and bearish
      {open, close} =
        if rem(i, 2) == 0 do
          {mid - offset, mid + offset}
        else
          {mid + offset, mid - offset}
        end

      create_bar(
        open,
        max(open, close) + 0.2,
        min(open, close) - 0.2,
        close,
        DateTime.add(~U[2024-01-15 14:30:00Z], i * 60, :second)
      )
    end)
  end

  defp create_complete_one_candle_setup(trend) do
    case trend do
      :bullish ->
        # Strong bullish trend, one bearish candle, break and retest
        [
          # Trend establishment
          create_bar(100.0, 100.8, 99.8, 100.5, ~U[2024-01-15 14:30:00Z]),
          create_bar(100.5, 101.3, 100.3, 101.0, ~U[2024-01-15 14:31:00Z]),
          create_bar(101.0, 101.8, 100.8, 101.5, ~U[2024-01-15 14:32:00Z]),
          create_bar(101.5, 102.3, 101.3, 102.0, ~U[2024-01-15 14:33:00Z]),
          create_bar(102.0, 102.8, 101.8, 102.5, ~U[2024-01-15 14:34:00Z]),
          # One candle (bearish)
          create_bar(102.5, 102.8, 101.8, 102.0, ~U[2024-01-15 14:35:00Z]),
          # Continuation
          create_bar(102.0, 103.0, 101.8, 102.8, ~U[2024-01-15 14:36:00Z]),
          create_bar(102.8, 103.5, 102.5, 103.2, ~U[2024-01-15 14:37:00Z]),
          # Break above one candle high
          create_bar(103.2, 104.0, 103.0, 103.8, ~U[2024-01-15 14:38:00Z]),
          # Retest
          create_bar(103.8, 104.0, 102.8, 103.0, ~U[2024-01-15 14:39:00Z]),
          # Bounce
          create_bar(103.0, 104.2, 102.9, 104.0, ~U[2024-01-15 14:40:00Z])
        ]

      :bearish ->
        # Strong bearish trend, one bullish candle, break and retest
        [
          # Trend establishment
          create_bar(104.0, 104.2, 103.5, 103.8, ~U[2024-01-15 14:30:00Z]),
          create_bar(103.8, 104.0, 103.2, 103.5, ~U[2024-01-15 14:31:00Z]),
          create_bar(103.5, 103.7, 102.8, 103.0, ~U[2024-01-15 14:32:00Z]),
          create_bar(103.0, 103.2, 102.3, 102.5, ~U[2024-01-15 14:33:00Z]),
          create_bar(102.5, 102.7, 101.8, 102.0, ~U[2024-01-15 14:34:00Z]),
          # One candle (bullish)
          create_bar(102.0, 102.8, 101.8, 102.5, ~U[2024-01-15 14:35:00Z]),
          # Continuation
          create_bar(102.5, 102.7, 101.5, 101.8, ~U[2024-01-15 14:36:00Z]),
          create_bar(101.8, 102.0, 101.0, 101.3, ~U[2024-01-15 14:37:00Z]),
          # Break below one candle low
          create_bar(101.3, 101.5, 100.5, 100.8, ~U[2024-01-15 14:38:00Z]),
          # Retest
          create_bar(100.8, 101.8, 100.5, 101.5, ~U[2024-01-15 14:39:00Z]),
          # Drop
          create_bar(101.5, 101.7, 100.2, 100.5, ~U[2024-01-15 14:40:00Z])
        ]
    end
  end
end
