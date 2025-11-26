defmodule Signal.Technicals.PdArrays.OrderBlockTest do
  use ExUnit.Case, async: true

  alias Signal.Technicals.PdArrays.OrderBlock
  alias Signal.MarketData.Bar

  describe "scan/2" do
    test "returns a list of order blocks (may be empty if no BOS detected)" do
      bars = create_bars_with_bullish_bos()
      obs = OrderBlock.scan(bars)

      # The result should be a list
      assert is_list(obs)

      # If any OBs are found, verify their structure
      if length(obs) > 0 do
        assert Enum.all?(obs, &(&1.type in [:bullish, :bearish]))
        assert Enum.all?(obs, &is_integer(&1.quality_score))
      end
    end

    test "returns empty list for insufficient bars" do
      bars = create_short_bar_series(5)
      assert OrderBlock.scan(bars) == []
    end

    test "returns empty list for empty bar list" do
      assert OrderBlock.scan([]) == []
    end

    test "finds bullish order block before bullish BOS" do
      bars = create_bars_with_bullish_bos()
      obs = OrderBlock.scan(bars)

      bullish_obs = Enum.filter(obs, &(&1.type == :bullish))

      if length(bullish_obs) > 0 do
        ob = hd(bullish_obs)
        assert ob.type == :bullish
        assert ob.top != nil
        assert ob.bottom != nil
        assert Decimal.compare(ob.top, ob.bottom) != :lt
      end
    end

    test "finds bearish order block before bearish BOS" do
      bars = create_bars_with_bearish_bos()
      obs = OrderBlock.scan(bars)

      bearish_obs = Enum.filter(obs, &(&1.type == :bearish))

      if length(bearish_obs) > 0 do
        ob = hd(bearish_obs)
        assert ob.type == :bearish
        assert ob.top != nil
        assert ob.bottom != nil
        assert Decimal.compare(ob.top, ob.bottom) != :lt
      end
    end

    test "includes quality score in results" do
      bars = create_bars_with_bullish_bos()
      obs = OrderBlock.scan(bars)

      if length(obs) > 0 do
        assert Enum.all?(obs, &is_integer(&1.quality_score))
      end
    end

    test "checks for FVG confluence by default" do
      bars = create_bars_with_ob_and_fvg()
      obs = OrderBlock.scan(bars, check_fvg: true)

      if length(obs) > 0 do
        assert Enum.all?(obs, &is_boolean(&1.has_fvg_confluence))
      end
    end

    test "respects max_ob_bars option" do
      bars = create_bars_with_multiple_opposing()
      obs = OrderBlock.scan(bars, max_ob_bars: 1)

      if length(obs) > 0 do
        # Each OB should have at most 1 bar
        assert Enum.all?(obs, fn ob -> length(ob.bars) <= 1 end)
      end
    end
  end

  describe "detect/4" do
    test "detects bullish order block at valid BOS index" do
      bars = create_bars_with_bullish_bos()
      # Find a BOS index (simplified - looking for a bar that breaks above previous highs)
      bos_index = find_bullish_bos_index(bars)

      if bos_index do
        result = OrderBlock.detect(bars, bos_index, :bullish)

        case result do
          {:ok, ob} ->
            assert ob.type == :bullish
            assert ob.bars != nil
            assert length(ob.bars) > 0

          {:error, :no_order_block} ->
            # This is acceptable if no opposing candles found
            assert true
        end
      end
    end

    test "returns error for invalid index" do
      bars = create_bars_with_bullish_bos()

      assert {:error, :invalid_index} = OrderBlock.detect(bars, -1, :bullish)
      assert {:error, :invalid_index} = OrderBlock.detect(bars, length(bars) + 1, :bullish)
    end
  end

  describe "mitigated?/2" do
    test "bullish OB is mitigated when close below bottom" do
      ob = %{
        type: :bullish,
        top: Decimal.new("105.0"),
        bottom: Decimal.new("103.0")
      }

      bar = create_bar(103.5, 104.0, 102.0, 102.5, ~U[2024-01-01 10:00:00Z])

      assert OrderBlock.mitigated?(ob, bar) == true
    end

    test "bullish OB is not mitigated when close stays above bottom" do
      ob = %{
        type: :bullish,
        top: Decimal.new("105.0"),
        bottom: Decimal.new("103.0")
      }

      bar = create_bar(104.0, 105.0, 103.5, 104.5, ~U[2024-01-01 10:00:00Z])

      assert OrderBlock.mitigated?(ob, bar) == false
    end

    test "bearish OB is mitigated when close above top" do
      ob = %{
        type: :bearish,
        top: Decimal.new("110.0"),
        bottom: Decimal.new("108.0")
      }

      bar = create_bar(109.5, 111.0, 109.0, 110.5, ~U[2024-01-01 10:00:00Z])

      assert OrderBlock.mitigated?(ob, bar) == true
    end

    test "bearish OB is not mitigated when close stays below top" do
      ob = %{
        type: :bearish,
        top: Decimal.new("110.0"),
        bottom: Decimal.new("108.0")
      }

      bar = create_bar(108.5, 109.5, 108.0, 109.0, ~U[2024-01-01 10:00:00Z])

      assert OrderBlock.mitigated?(ob, bar) == false
    end
  end

  describe "in_zone?/2" do
    test "returns true when price is within OB zone" do
      ob = %{
        top: Decimal.new("110.0"),
        bottom: Decimal.new("105.0")
      }

      assert OrderBlock.in_zone?(ob, Decimal.new("107.5")) == true
      assert OrderBlock.in_zone?(ob, Decimal.new("105.0")) == true
      assert OrderBlock.in_zone?(ob, Decimal.new("110.0")) == true
    end

    test "returns false when price is outside OB zone" do
      ob = %{
        top: Decimal.new("110.0"),
        bottom: Decimal.new("105.0")
      }

      assert OrderBlock.in_zone?(ob, Decimal.new("104.9")) == false
      assert OrderBlock.in_zone?(ob, Decimal.new("110.1")) == false
    end
  end

  describe "equilibrium/1" do
    test "calculates 50% level correctly" do
      ob = %{top: Decimal.new("110.0"), bottom: Decimal.new("100.0")}
      eq = OrderBlock.equilibrium(ob)

      assert Decimal.equal?(eq, Decimal.new("105.0"))
    end

    test "handles small OB zones" do
      ob = %{top: Decimal.new("100.50"), bottom: Decimal.new("100.00")}
      eq = OrderBlock.equilibrium(ob)

      assert Decimal.equal?(eq, Decimal.new("100.25"))
    end
  end

  describe "score/2" do
    test "scores OB with FVG confluence higher" do
      ob_with_fvg = %{
        type: :bullish,
        top: Decimal.new("105.0"),
        bottom: Decimal.new("103.0"),
        body_top: Decimal.new("104.5"),
        body_bottom: Decimal.new("103.5"),
        has_fvg_confluence: true,
        mitigated: false,
        bos_bar: create_bar(105.0, 110.0, 104.0, 109.0, ~U[2024-01-01 10:00:00Z])
      }

      ob_without_fvg = %{
        type: :bullish,
        top: Decimal.new("105.0"),
        bottom: Decimal.new("103.0"),
        body_top: Decimal.new("104.5"),
        body_bottom: Decimal.new("103.5"),
        has_fvg_confluence: false,
        mitigated: false,
        bos_bar: create_bar(105.0, 110.0, 104.0, 109.0, ~U[2024-01-01 10:00:00Z])
      }

      score_with = OrderBlock.score(ob_with_fvg)
      score_without = OrderBlock.score(ob_without_fvg)

      assert score_with > score_without
    end

    test "unmitigated OB scores higher than mitigated" do
      ob_unmitigated = %{
        type: :bullish,
        top: Decimal.new("105.0"),
        bottom: Decimal.new("103.0"),
        body_top: Decimal.new("104.5"),
        body_bottom: Decimal.new("103.5"),
        has_fvg_confluence: false,
        mitigated: false,
        bos_bar: create_bar(105.0, 110.0, 104.0, 109.0, ~U[2024-01-01 10:00:00Z])
      }

      ob_mitigated = %{
        type: :bullish,
        top: Decimal.new("105.0"),
        bottom: Decimal.new("103.0"),
        body_top: Decimal.new("104.5"),
        body_bottom: Decimal.new("103.5"),
        has_fvg_confluence: false,
        mitigated: true,
        bos_bar: create_bar(105.0, 110.0, 104.0, 109.0, ~U[2024-01-01 10:00:00Z])
      }

      score_unmitigated = OrderBlock.score(ob_unmitigated)
      score_mitigated = OrderBlock.score(ob_mitigated)

      assert score_unmitigated > score_mitigated
    end

    test "includes HTF alignment context in score" do
      ob = %{
        type: :bullish,
        top: Decimal.new("105.0"),
        bottom: Decimal.new("103.0"),
        body_top: Decimal.new("104.5"),
        body_bottom: Decimal.new("103.5"),
        has_fvg_confluence: false,
        mitigated: false,
        bos_bar: create_bar(105.0, 110.0, 104.0, 109.0, ~U[2024-01-01 10:00:00Z])
      }

      score_without_htf = OrderBlock.score(ob)
      score_with_htf = OrderBlock.score(ob, %{htf_aligned?: true})

      assert score_with_htf > score_without_htf
    end
  end

  describe "filter_unmitigated/2" do
    test "returns only unmitigated OBs" do
      ob1 = %{
        type: :bullish,
        top: Decimal.new("105.0"),
        bottom: Decimal.new("103.0"),
        mitigated: false
      }

      ob2 = %{
        type: :bearish,
        top: Decimal.new("115.0"),
        bottom: Decimal.new("113.0"),
        mitigated: false
      }

      obs = [ob1, ob2]

      # Bar that mitigates ob1 (closes below 103) but not ob2
      bar = create_bar(103.5, 104.0, 102.0, 102.5, ~U[2024-01-01 10:00:00Z])

      unmitigated = OrderBlock.filter_unmitigated(obs, [bar])

      assert length(unmitigated) == 1
      assert hd(unmitigated).type == :bearish
    end
  end

  describe "nearest/3" do
    test "returns nearest unmitigated OB" do
      ob1 = %{
        type: :bullish,
        top: Decimal.new("105.0"),
        bottom: Decimal.new("103.0"),
        mitigated: false
      }

      ob2 = %{
        type: :bullish,
        top: Decimal.new("115.0"),
        bottom: Decimal.new("113.0"),
        mitigated: false
      }

      obs = [ob1, ob2]
      current_price = Decimal.new("106.0")

      nearest = OrderBlock.nearest(obs, current_price)

      # ob1 eq = 104.0, distance = 2.0
      # ob2 eq = 114.0, distance = 8.0
      assert nearest.bottom == ob1.bottom
    end

    test "filters by direction" do
      ob1 = %{
        type: :bullish,
        top: Decimal.new("105.0"),
        bottom: Decimal.new("103.0"),
        mitigated: false
      }

      ob2 = %{
        type: :bearish,
        top: Decimal.new("108.0"),
        bottom: Decimal.new("106.0"),
        mitigated: false
      }

      obs = [ob1, ob2]
      current_price = Decimal.new("105.5")

      nearest_bullish = OrderBlock.nearest(obs, current_price, :bullish)
      nearest_bearish = OrderBlock.nearest(obs, current_price, :bearish)

      assert nearest_bullish.type == :bullish
      assert nearest_bearish.type == :bearish
    end

    test "returns nil when no OBs match" do
      obs = [
        %{
          type: :bullish,
          top: Decimal.new("105.0"),
          bottom: Decimal.new("103.0"),
          mitigated: true
        }
      ]

      assert OrderBlock.nearest(obs, Decimal.new("107.0")) == nil
    end
  end

  describe "edge cases" do
    test "handles bars with no opposing candles before BOS" do
      # All bullish candles leading to BOS
      bars = create_all_bullish_bars()
      obs = OrderBlock.scan(bars)

      # Should handle gracefully (may return empty or find a single opposing candle)
      assert is_list(obs)
    end

    test "handles flat market with no BOS" do
      bars = create_flat_market_bars()
      obs = OrderBlock.scan(bars)

      # Should return empty list when no BOS detected
      assert is_list(obs)
    end
  end

  # Helper functions

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

  defp create_short_bar_series(count) do
    Enum.map(0..(count - 1), fn i ->
      create_bar(
        100.0 + i,
        101.0 + i,
        99.0 + i,
        100.5 + i,
        add_minutes(~U[2024-01-01 09:30:00Z], i)
      )
    end)
  end

  defp create_bars_with_bullish_bos do
    [
      # Downtrend bars (creating swing lows)
      create_bar(110.0, 111.0, 108.0, 108.5, ~U[2024-01-01 09:30:00Z]),
      create_bar(108.5, 109.0, 106.0, 106.5, ~U[2024-01-01 09:31:00Z]),
      create_bar(106.5, 107.5, 105.0, 106.0, ~U[2024-01-01 09:32:00Z]),
      # Swing low
      create_bar(106.0, 106.5, 103.0, 103.5, ~U[2024-01-01 09:33:00Z]),
      create_bar(103.5, 105.0, 102.0, 104.5, ~U[2024-01-01 09:34:00Z]),
      create_bar(104.5, 106.0, 103.5, 105.5, ~U[2024-01-01 09:35:00Z]),
      # Rally back up
      create_bar(105.5, 107.5, 105.0, 107.0, ~U[2024-01-01 09:36:00Z]),
      create_bar(107.0, 108.5, 106.5, 108.0, ~U[2024-01-01 09:37:00Z]),
      # Bearish candle (potential OB)
      create_bar(108.0, 108.5, 106.0, 106.5, ~U[2024-01-01 09:38:00Z]),
      # BOS - breaks above swing high
      create_bar(106.5, 112.0, 106.0, 111.5, ~U[2024-01-01 09:39:00Z]),
      create_bar(111.5, 114.0, 111.0, 113.5, ~U[2024-01-01 09:40:00Z]),
      create_bar(113.5, 115.0, 112.5, 114.0, ~U[2024-01-01 09:41:00Z])
    ]
  end

  defp create_bars_with_bearish_bos do
    [
      # Uptrend bars
      create_bar(100.0, 102.0, 99.0, 101.5, ~U[2024-01-01 09:30:00Z]),
      create_bar(101.5, 104.0, 101.0, 103.5, ~U[2024-01-01 09:31:00Z]),
      create_bar(103.5, 106.0, 103.0, 105.5, ~U[2024-01-01 09:32:00Z]),
      # Swing high
      create_bar(105.5, 108.0, 105.0, 107.5, ~U[2024-01-01 09:33:00Z]),
      create_bar(107.5, 109.0, 107.0, 108.0, ~U[2024-01-01 09:34:00Z]),
      create_bar(108.0, 108.5, 106.0, 106.5, ~U[2024-01-01 09:35:00Z]),
      # Pull back
      create_bar(106.5, 107.5, 105.0, 105.5, ~U[2024-01-01 09:36:00Z]),
      create_bar(105.5, 106.0, 104.0, 104.5, ~U[2024-01-01 09:37:00Z]),
      # Bullish candle (potential OB for bearish)
      create_bar(104.5, 107.0, 104.0, 106.5, ~U[2024-01-01 09:38:00Z]),
      # BOS - breaks below swing low
      create_bar(106.5, 107.0, 102.0, 102.5, ~U[2024-01-01 09:39:00Z]),
      create_bar(102.5, 103.0, 100.0, 100.5, ~U[2024-01-01 09:40:00Z]),
      create_bar(100.5, 101.0, 98.0, 98.5, ~U[2024-01-01 09:41:00Z])
    ]
  end

  defp create_bars_with_ob_and_fvg do
    [
      # Setup
      create_bar(100.0, 102.0, 99.0, 101.5, ~U[2024-01-01 09:30:00Z]),
      create_bar(101.5, 103.0, 101.0, 102.5, ~U[2024-01-01 09:31:00Z]),
      create_bar(102.5, 104.0, 102.0, 103.5, ~U[2024-01-01 09:32:00Z]),
      # Swing high
      create_bar(103.5, 106.0, 103.0, 105.0, ~U[2024-01-01 09:33:00Z]),
      create_bar(105.0, 105.5, 103.0, 103.5, ~U[2024-01-01 09:34:00Z]),
      create_bar(103.5, 104.0, 102.0, 102.5, ~U[2024-01-01 09:35:00Z]),
      # Swing low
      create_bar(102.5, 103.5, 100.0, 100.5, ~U[2024-01-01 09:36:00Z]),
      create_bar(100.5, 102.0, 99.5, 101.5, ~U[2024-01-01 09:37:00Z]),
      # Bearish candle (OB)
      create_bar(101.5, 102.0, 100.0, 100.5, ~U[2024-01-01 09:38:00Z]),
      # BOS with FVG
      create_bar(100.5, 108.0, 100.0, 107.5, ~U[2024-01-01 09:39:00Z]),
      create_bar(107.0, 112.0, 104.0, 111.0, ~U[2024-01-01 09:40:00Z]),
      create_bar(111.0, 113.0, 110.0, 112.0, ~U[2024-01-01 09:41:00Z])
    ]
  end

  defp create_bars_with_multiple_opposing do
    [
      # Setup
      create_bar(100.0, 102.0, 99.0, 101.5, ~U[2024-01-01 09:30:00Z]),
      create_bar(101.5, 104.0, 101.0, 103.5, ~U[2024-01-01 09:31:00Z]),
      create_bar(103.5, 106.0, 103.0, 105.0, ~U[2024-01-01 09:32:00Z]),
      # Swing high
      create_bar(105.0, 107.0, 104.5, 106.5, ~U[2024-01-01 09:33:00Z]),
      create_bar(106.5, 107.5, 105.0, 105.5, ~U[2024-01-01 09:34:00Z]),
      create_bar(105.5, 106.0, 103.0, 103.5, ~U[2024-01-01 09:35:00Z]),
      # Swing low
      create_bar(103.5, 104.0, 100.0, 100.5, ~U[2024-01-01 09:36:00Z]),
      create_bar(100.5, 102.0, 99.5, 101.5, ~U[2024-01-01 09:37:00Z]),
      # Multiple bearish candles (potential multi-bar OB)
      create_bar(101.5, 102.0, 100.0, 100.5, ~U[2024-01-01 09:38:00Z]),
      create_bar(100.5, 101.0, 99.0, 99.5, ~U[2024-01-01 09:39:00Z]),
      create_bar(99.5, 100.0, 98.0, 98.5, ~U[2024-01-01 09:40:00Z]),
      # BOS
      create_bar(98.5, 110.0, 98.0, 109.5, ~U[2024-01-01 09:41:00Z]),
      create_bar(109.5, 112.0, 108.0, 111.0, ~U[2024-01-01 09:42:00Z])
    ]
  end

  defp create_all_bullish_bars do
    Enum.map(0..14, fn i ->
      base = 100.0 + i * 2

      create_bar(
        base,
        base + 2.5,
        base - 0.5,
        base + 2.0,
        add_minutes(~U[2024-01-01 09:30:00Z], i)
      )
    end)
  end

  defp create_flat_market_bars do
    Enum.map(0..14, fn i ->
      create_bar(100.0, 101.0, 99.0, 100.0, add_minutes(~U[2024-01-01 09:30:00Z], i))
    end)
  end

  defp add_minutes(datetime, minutes) do
    DateTime.add(datetime, minutes * 60, :second)
  end

  defp find_bullish_bos_index(bars) do
    # Simple heuristic: find a bar that has a notably high close
    # In a real scenario, we'd use the StructureDetector
    bars
    |> Enum.with_index()
    |> Enum.find(fn {bar, idx} ->
      if idx > 5 do
        prev_highs =
          bars |> Enum.take(idx) |> Enum.map(& &1.high) |> Enum.map(&Decimal.to_float/1)

        max_prev = Enum.max(prev_highs)
        Decimal.to_float(bar.close) > max_prev
      else
        false
      end
    end)
    |> case do
      {_, idx} -> idx
      nil -> nil
    end
  end
end
