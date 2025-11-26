defmodule Signal.Technicals.PdArrays.FairValueGapTest do
  use ExUnit.Case, async: true

  alias Signal.Technicals.PdArrays.FairValueGap
  alias Signal.MarketData.Bar

  describe "detect/3" do
    test "detects bullish FVG when bar3.low > bar1.high" do
      bar1 = create_bar(100.0, 105.0, 100.0, 104.0, ~U[2024-01-01 09:30:00Z])
      bar2 = create_bar(104.5, 110.0, 104.0, 109.5, ~U[2024-01-01 09:31:00Z])
      bar3 = create_bar(109.0, 112.0, 106.0, 111.0, ~U[2024-01-01 09:32:00Z])

      assert {:ok, fvg} = FairValueGap.detect(bar1, bar2, bar3)
      assert fvg.symbol == "TEST"
      assert fvg.type == :bullish
      assert Decimal.equal?(fvg.top, Decimal.new("106.0"))
      assert Decimal.equal?(fvg.bottom, Decimal.new("105.0"))
      assert fvg.bar_time == bar2.bar_time
      assert fvg.mitigated == false
      assert Decimal.compare(fvg.size, Decimal.new(0)) == :gt
    end

    test "detects bearish FVG when bar1.low > bar3.high" do
      bar1 = create_bar(110.0, 112.0, 108.0, 109.0, ~U[2024-01-01 09:30:00Z])
      bar2 = create_bar(108.5, 109.0, 102.0, 102.5, ~U[2024-01-01 09:31:00Z])
      bar3 = create_bar(103.0, 106.0, 100.0, 101.0, ~U[2024-01-01 09:32:00Z])

      assert {:ok, fvg} = FairValueGap.detect(bar1, bar2, bar3)
      assert fvg.type == :bearish
      assert Decimal.equal?(fvg.top, Decimal.new("108.0"))
      assert Decimal.equal?(fvg.bottom, Decimal.new("106.0"))
      assert fvg.bar_time == bar2.bar_time
      assert fvg.mitigated == false
    end

    test "returns error when no gap exists" do
      bar1 = create_bar(100.0, 105.0, 100.0, 104.0, ~U[2024-01-01 09:30:00Z])
      bar2 = create_bar(104.0, 106.0, 103.0, 105.5, ~U[2024-01-01 09:31:00Z])
      bar3 = create_bar(105.0, 107.0, 104.0, 106.0, ~U[2024-01-01 09:32:00Z])

      assert {:error, :no_gap} = FairValueGap.detect(bar1, bar2, bar3)
    end

    test "returns error when bars overlap" do
      bar1 = create_bar(100.0, 105.0, 100.0, 104.0, ~U[2024-01-01 09:30:00Z])
      bar2 = create_bar(103.0, 106.0, 102.0, 105.5, ~U[2024-01-01 09:31:00Z])
      bar3 = create_bar(105.0, 107.0, 103.0, 106.0, ~U[2024-01-01 09:32:00Z])

      assert {:error, :no_gap} = FairValueGap.detect(bar1, bar2, bar3)
    end

    test "returns error for invalid bars" do
      assert {:error, :invalid_bars} = FairValueGap.detect(nil, nil, nil)
    end

    test "calculates correct gap size for bullish FVG" do
      bar1 = create_bar(100.0, 105.0, 100.0, 104.0, ~U[2024-01-01 09:30:00Z])
      bar2 = create_bar(104.5, 110.0, 104.0, 109.5, ~U[2024-01-01 09:31:00Z])
      bar3 = create_bar(109.0, 112.0, 108.0, 111.0, ~U[2024-01-01 09:32:00Z])

      assert {:ok, fvg} = FairValueGap.detect(bar1, bar2, bar3)
      # Gap size = bar3.low - bar1.high = 108.0 - 105.0 = 3.0
      assert Decimal.equal?(fvg.size, Decimal.new("3.0"))
    end

    test "calculates correct gap size for bearish FVG" do
      bar1 = create_bar(110.0, 115.0, 108.0, 109.0, ~U[2024-01-01 09:30:00Z])
      bar2 = create_bar(108.5, 109.0, 102.0, 102.5, ~U[2024-01-01 09:31:00Z])
      bar3 = create_bar(103.0, 105.0, 100.0, 101.0, ~U[2024-01-01 09:32:00Z])

      assert {:ok, fvg} = FairValueGap.detect(bar1, bar2, bar3)
      # Gap size = bar1.low - bar3.high = 108.0 - 105.0 = 3.0
      assert Decimal.equal?(fvg.size, Decimal.new("3.0"))
    end
  end

  describe "scan/2" do
    test "finds all FVGs in a bar series" do
      bars = create_bars_with_fvgs()
      fvgs = FairValueGap.scan(bars)

      assert length(fvgs) > 0
      assert Enum.all?(fvgs, &(&1.type in [:bullish, :bearish]))
    end

    test "returns empty list for insufficient bars" do
      bars = [
        create_bar(100.0, 105.0, 100.0, 104.0, ~U[2024-01-01 09:30:00Z]),
        create_bar(104.0, 106.0, 103.0, 105.5, ~U[2024-01-01 09:31:00Z])
      ]

      assert FairValueGap.scan(bars) == []
    end

    test "returns empty list for empty bar list" do
      assert FairValueGap.scan([]) == []
    end

    test "respects min_size option" do
      bars = create_bars_with_small_and_large_fvgs()
      # Only get FVGs with size >= 2.0
      fvgs = FairValueGap.scan(bars, min_size: Decimal.new("2.0"))

      assert Enum.all?(fvgs, fn fvg ->
               Decimal.compare(fvg.size, Decimal.new("2.0")) != :lt
             end)
    end

    test "checks mitigation when include_mitigated option is true" do
      bars = create_bars_with_mitigated_fvg()
      fvgs = FairValueGap.scan(bars, include_mitigated: true)

      mitigated_count = Enum.count(fvgs, & &1.mitigated)
      assert mitigated_count > 0
    end
  end

  describe "mitigated?/2" do
    test "bullish FVG is mitigated when bar low enters gap" do
      fvg = %{type: :bullish, top: Decimal.new("106.0"), bottom: Decimal.new("105.0")}
      bar = create_bar(107.0, 108.0, 105.5, 107.5, ~U[2024-01-01 09:35:00Z])

      assert FairValueGap.mitigated?(fvg, bar) == true
    end

    test "bullish FVG is not mitigated when bar low stays above gap" do
      fvg = %{type: :bullish, top: Decimal.new("106.0"), bottom: Decimal.new("105.0")}
      bar = create_bar(107.0, 108.0, 106.5, 107.5, ~U[2024-01-01 09:35:00Z])

      assert FairValueGap.mitigated?(fvg, bar) == false
    end

    test "bearish FVG is mitigated when bar high enters gap" do
      fvg = %{type: :bearish, top: Decimal.new("108.0"), bottom: Decimal.new("106.0")}
      bar = create_bar(105.0, 107.0, 104.5, 106.5, ~U[2024-01-01 09:35:00Z])

      assert FairValueGap.mitigated?(fvg, bar) == true
    end

    test "bearish FVG is not mitigated when bar high stays below gap" do
      fvg = %{type: :bearish, top: Decimal.new("108.0"), bottom: Decimal.new("106.0")}
      bar = create_bar(104.0, 105.0, 103.5, 104.5, ~U[2024-01-01 09:35:00Z])

      assert FairValueGap.mitigated?(fvg, bar) == false
    end
  end

  describe "filled?/2" do
    test "bullish FVG is filled when bar low goes below gap bottom" do
      fvg = %{type: :bullish, top: Decimal.new("106.0"), bottom: Decimal.new("105.0")}
      bar = create_bar(106.0, 107.0, 104.5, 105.5, ~U[2024-01-01 09:35:00Z])

      assert FairValueGap.filled?(fvg, bar) == true
    end

    test "bullish FVG is not filled when bar low stays in gap" do
      fvg = %{type: :bullish, top: Decimal.new("106.0"), bottom: Decimal.new("105.0")}
      bar = create_bar(106.0, 107.0, 105.5, 106.5, ~U[2024-01-01 09:35:00Z])

      assert FairValueGap.filled?(fvg, bar) == false
    end

    test "bearish FVG is filled when bar high goes above gap top" do
      fvg = %{type: :bearish, top: Decimal.new("108.0"), bottom: Decimal.new("106.0")}
      bar = create_bar(107.0, 108.5, 106.5, 108.0, ~U[2024-01-01 09:35:00Z])

      assert FairValueGap.filled?(fvg, bar) == true
    end

    test "bearish FVG is not filled when bar high stays in gap" do
      fvg = %{type: :bearish, top: Decimal.new("108.0"), bottom: Decimal.new("106.0")}
      bar = create_bar(106.0, 107.5, 105.5, 107.0, ~U[2024-01-01 09:35:00Z])

      assert FairValueGap.filled?(fvg, bar) == false
    end
  end

  describe "consequent_encroachment/1" do
    test "calculates 50% level correctly" do
      fvg = %{top: Decimal.new("110.0"), bottom: Decimal.new("100.0")}
      ce = FairValueGap.consequent_encroachment(fvg)

      assert Decimal.equal?(ce, Decimal.new("105.0"))
    end

    test "handles small gaps" do
      fvg = %{top: Decimal.new("100.50"), bottom: Decimal.new("100.00")}
      ce = FairValueGap.consequent_encroachment(fvg)

      assert Decimal.equal?(ce, Decimal.new("100.25"))
    end
  end

  describe "filter_unmitigated/2" do
    test "returns only unmitigated FVGs" do
      fvg1 = %{
        type: :bullish,
        top: Decimal.new("106.0"),
        bottom: Decimal.new("105.0"),
        mitigated: false
      }

      fvg2 = %{
        type: :bearish,
        top: Decimal.new("110.0"),
        bottom: Decimal.new("108.0"),
        mitigated: false
      }

      fvgs = [fvg1, fvg2]

      # Bar that mitigates fvg1 but not fvg2
      bar = create_bar(106.0, 107.0, 105.5, 106.5, ~U[2024-01-01 09:35:00Z])

      unmitigated = FairValueGap.filter_unmitigated(fvgs, [bar])

      assert length(unmitigated) == 1
      assert hd(unmitigated).type == :bearish
    end
  end

  describe "nearest/3" do
    test "returns nearest unmitigated FVG" do
      fvg1 = %{
        type: :bullish,
        top: Decimal.new("106.0"),
        bottom: Decimal.new("105.0"),
        mitigated: false
      }

      fvg2 = %{
        type: :bullish,
        top: Decimal.new("102.0"),
        bottom: Decimal.new("100.0"),
        mitigated: false
      }

      fvgs = [fvg1, fvg2]
      current_price = Decimal.new("103.0")

      nearest = FairValueGap.nearest(fvgs, current_price)

      # fvg2 CE = 101.0, distance = 2.0
      # fvg1 CE = 105.5, distance = 2.5
      assert nearest.bottom == fvg2.bottom
    end

    test "filters by direction" do
      fvg1 = %{
        type: :bullish,
        top: Decimal.new("106.0"),
        bottom: Decimal.new("105.0"),
        mitigated: false
      }

      fvg2 = %{
        type: :bearish,
        top: Decimal.new("110.0"),
        bottom: Decimal.new("108.0"),
        mitigated: false
      }

      fvgs = [fvg1, fvg2]
      current_price = Decimal.new("107.0")

      nearest_bullish = FairValueGap.nearest(fvgs, current_price, :bullish)
      nearest_bearish = FairValueGap.nearest(fvgs, current_price, :bearish)

      assert nearest_bullish.type == :bullish
      assert nearest_bearish.type == :bearish
    end

    test "returns nil when no FVGs match" do
      fvgs = [
        %{
          type: :bullish,
          top: Decimal.new("106.0"),
          bottom: Decimal.new("105.0"),
          mitigated: true
        }
      ]

      assert FairValueGap.nearest(fvgs, Decimal.new("107.0")) == nil
    end
  end

  describe "edge cases" do
    test "handles exact gap boundary (bar3.low == bar1.high)" do
      bar1 = create_bar(100.0, 105.0, 100.0, 104.0, ~U[2024-01-01 09:30:00Z])
      bar2 = create_bar(104.5, 110.0, 104.0, 109.5, ~U[2024-01-01 09:31:00Z])
      bar3 = create_bar(105.0, 107.0, 105.0, 106.0, ~U[2024-01-01 09:32:00Z])

      # bar3.low (105.0) == bar1.high (105.0), no gap
      assert {:error, :no_gap} = FairValueGap.detect(bar1, bar2, bar3)
    end

    test "handles very small gaps" do
      bar1 = create_bar(100.0, 105.0, 100.0, 104.0, ~U[2024-01-01 09:30:00Z])
      bar2 = create_bar(104.5, 110.0, 104.0, 109.5, ~U[2024-01-01 09:31:00Z])
      bar3 = create_bar(105.01, 107.0, 105.01, 106.0, ~U[2024-01-01 09:32:00Z])

      assert {:ok, fvg} = FairValueGap.detect(bar1, bar2, bar3)
      assert Decimal.compare(fvg.size, Decimal.new("0.01")) == :eq
    end

    test "includes displacement bar reference" do
      bar1 = create_bar(100.0, 105.0, 100.0, 104.0, ~U[2024-01-01 09:30:00Z])
      bar2 = create_bar(104.5, 110.0, 104.0, 109.5, ~U[2024-01-01 09:31:00Z])
      bar3 = create_bar(109.0, 112.0, 108.0, 111.0, ~U[2024-01-01 09:32:00Z])

      assert {:ok, fvg} = FairValueGap.detect(bar1, bar2, bar3)
      assert fvg.displacement_bar == bar2
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

  defp create_bars_with_fvgs do
    [
      # Setup bars
      create_bar(100.0, 102.0, 99.0, 101.0, ~U[2024-01-01 09:30:00Z]),
      create_bar(101.0, 103.0, 100.0, 102.5, ~U[2024-01-01 09:31:00Z]),
      # Bullish FVG
      create_bar(102.0, 103.0, 101.0, 102.5, ~U[2024-01-01 09:32:00Z]),
      create_bar(103.0, 108.0, 102.5, 107.5, ~U[2024-01-01 09:33:00Z]),
      create_bar(107.0, 110.0, 105.0, 109.0, ~U[2024-01-01 09:34:00Z]),
      # More bars
      create_bar(109.0, 111.0, 108.0, 110.0, ~U[2024-01-01 09:35:00Z]),
      create_bar(110.0, 112.0, 109.0, 111.0, ~U[2024-01-01 09:36:00Z])
    ]
  end

  defp create_bars_with_small_and_large_fvgs do
    [
      # Small FVG (0.5 gap)
      create_bar(100.0, 101.0, 99.5, 100.5, ~U[2024-01-01 09:30:00Z]),
      create_bar(100.5, 103.0, 100.0, 102.5, ~U[2024-01-01 09:31:00Z]),
      create_bar(102.0, 104.0, 101.5, 103.0, ~U[2024-01-01 09:32:00Z]),
      # Large FVG (3.0 gap)
      create_bar(103.0, 105.0, 102.5, 104.0, ~U[2024-01-01 09:33:00Z]),
      create_bar(105.0, 112.0, 104.5, 111.0, ~U[2024-01-01 09:34:00Z]),
      create_bar(110.0, 113.0, 108.0, 112.0, ~U[2024-01-01 09:35:00Z])
    ]
  end

  defp create_bars_with_mitigated_fvg do
    [
      # Bullish FVG setup
      create_bar(100.0, 102.0, 99.0, 101.0, ~U[2024-01-01 09:30:00Z]),
      create_bar(101.0, 107.0, 100.5, 106.5, ~U[2024-01-01 09:31:00Z]),
      create_bar(106.0, 108.0, 104.0, 107.0, ~U[2024-01-01 09:32:00Z]),
      # Price retraces and mitigates
      create_bar(107.0, 108.0, 105.0, 105.5, ~U[2024-01-01 09:33:00Z]),
      create_bar(105.5, 106.5, 103.0, 103.5, ~U[2024-01-01 09:34:00Z])
    ]
  end
end
