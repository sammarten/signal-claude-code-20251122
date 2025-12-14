defmodule Signal.Preview.StructsTest do
  use ExUnit.Case, async: true

  alias Signal.Preview.{
    MarketRegime,
    IndexDivergence,
    RelativeStrength,
    PremarketSnapshot,
    Scenario,
    WatchlistItem,
    DailyPreview
  }

  describe "MarketRegime struct" do
    test "creates struct with required fields" do
      regime = %MarketRegime{
        symbol: "SPY",
        date: ~D[2024-12-14],
        timeframe: "daily",
        regime: :ranging
      }

      assert regime.symbol == "SPY"
      assert regime.regime == :ranging
      assert regime.higher_lows_count == 0
      assert regime.lower_highs_count == 0
    end

    test "supports all regime types" do
      for regime_type <- [:trending_up, :trending_down, :ranging, :breakout_pending] do
        regime = %MarketRegime{regime: regime_type}
        assert regime.regime == regime_type
      end
    end
  end

  describe "IndexDivergence struct" do
    test "creates struct with all fields" do
      divergence = %IndexDivergence{
        date: ~D[2024-12-14],
        spy_status: :leading,
        qqq_status: :lagging,
        dia_status: :neutral,
        spy_1d_pct: Decimal.new("0.5"),
        qqq_1d_pct: Decimal.new("-0.2"),
        dia_1d_pct: Decimal.new("0.3"),
        spy_5d_pct: Decimal.new("1.5"),
        qqq_5d_pct: Decimal.new("-0.5"),
        dia_5d_pct: Decimal.new("1.0"),
        spy_from_ath_pct: Decimal.new("1.0"),
        qqq_from_ath_pct: Decimal.new("5.0"),
        dia_from_ath_pct: Decimal.new("0.5"),
        leader: "SPY",
        laggard: "QQQ",
        implication: "Tech lagging"
      }

      assert divergence.spy_status == :leading
      assert divergence.qqq_status == :lagging
      assert divergence.leader == "SPY"
      assert divergence.laggard == "QQQ"
    end
  end

  describe "RelativeStrength struct" do
    test "creates struct with required fields" do
      rs = %RelativeStrength{
        symbol: "NVDA",
        date: ~D[2024-12-14],
        benchmark: "SPY",
        rs_1d: Decimal.new("0.5"),
        rs_5d: Decimal.new("2.5"),
        rs_20d: Decimal.new("5.0"),
        status: :outperform
      }

      assert rs.symbol == "NVDA"
      assert rs.benchmark == "SPY"
      assert rs.status == :outperform
    end

    test "supports all status types" do
      statuses = [:strong_outperform, :outperform, :inline, :underperform, :strong_underperform]

      for status <- statuses do
        rs = %RelativeStrength{status: status}
        assert rs.status == status
      end
    end
  end

  describe "PremarketSnapshot struct" do
    test "creates struct with gap analysis fields" do
      snapshot = %PremarketSnapshot{
        symbol: "AAPL",
        timestamp: DateTime.utc_now(),
        current_price: Decimal.new("175.50"),
        previous_close: Decimal.new("173.00"),
        gap_percent: Decimal.new("1.45"),
        gap_direction: :up,
        position_in_range: :above_prev_day_high
      }

      assert snapshot.gap_direction == :up
      assert snapshot.position_in_range == :above_prev_day_high
    end

    test "supports all gap directions" do
      for direction <- [:up, :down, :flat] do
        snapshot = %PremarketSnapshot{gap_direction: direction}
        assert snapshot.gap_direction == direction
      end
    end

    test "supports all range positions" do
      positions = [
        :above_prev_day_high,
        :near_prev_day_high,
        :middle_of_range,
        :near_prev_day_low,
        :below_prev_day_low
      ]

      for position <- positions do
        snapshot = %PremarketSnapshot{position_in_range: position}
        assert snapshot.position_in_range == position
      end
    end
  end

  describe "Scenario struct" do
    test "creates struct with trading scenario" do
      scenario = %Scenario{
        type: :bullish,
        trigger_level: Decimal.new("690.00"),
        trigger_condition: "break above and hold",
        target_level: Decimal.new("695.00"),
        description: "Break above 690, target 695"
      }

      assert scenario.type == :bullish
      assert scenario.trigger_condition == "break above and hold"
    end

    test "supports all scenario types" do
      for scenario_type <- [:bullish, :bearish, :bounce, :fade] do
        scenario = %Scenario{type: scenario_type}
        assert scenario.type == scenario_type
      end
    end
  end

  describe "WatchlistItem struct" do
    test "creates struct with watchlist fields" do
      item = %WatchlistItem{
        symbol: "PLTR",
        setup: "breakout continuation",
        key_level: Decimal.new("75.00"),
        bias: :long,
        conviction: :high,
        notes: "Strong momentum"
      }

      assert item.symbol == "PLTR"
      assert item.bias == :long
      assert item.conviction == :high
    end

    test "supports all bias types" do
      for bias <- [:long, :short, :neutral] do
        item = %WatchlistItem{bias: bias}
        assert item.bias == bias
      end
    end

    test "supports all conviction levels" do
      for conviction <- [:high, :medium, :low] do
        item = %WatchlistItem{conviction: conviction}
        assert item.conviction == conviction
      end
    end
  end

  describe "DailyPreview struct" do
    test "creates struct with default values" do
      preview = %DailyPreview{
        date: ~D[2024-12-14],
        generated_at: DateTime.utc_now()
      }

      assert preview.date == ~D[2024-12-14]
      assert preview.key_events == []
      assert preview.expected_volatility == :normal
      assert preview.spy_scenarios == []
      assert preview.qqq_scenarios == []
      assert preview.high_conviction == []
      assert preview.monitoring == []
      assert preview.avoid == []
      assert preview.stance == :normal
      assert preview.position_size == :full
      assert preview.risk_notes == []
    end

    test "supports all stance types" do
      for stance <- [:aggressive, :normal, :cautious, :hands_off] do
        preview = %DailyPreview{stance: stance}
        assert preview.stance == stance
      end
    end

    test "supports all position sizes" do
      for size <- [:full, :half, :quarter] do
        preview = %DailyPreview{position_size: size}
        assert preview.position_size == size
      end
    end

    test "supports all volatility levels" do
      for volatility <- [:high, :normal, :low] do
        preview = %DailyPreview{expected_volatility: volatility}
        assert preview.expected_volatility == volatility
      end
    end
  end
end
