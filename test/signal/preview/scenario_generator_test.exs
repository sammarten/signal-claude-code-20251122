defmodule Signal.Preview.ScenarioGeneratorTest do
  use ExUnit.Case, async: true

  alias Signal.Technicals.KeyLevels
  alias Signal.Preview.{ScenarioGenerator, MarketRegime, PremarketSnapshot}

  describe "generate/3 with ranging regime" do
    setup do
      key_levels = %KeyLevels{
        symbol: "SPY",
        date: ~D[2024-12-14],
        previous_day_high: Decimal.new("605.00"),
        previous_day_low: Decimal.new("600.00"),
        previous_day_close: Decimal.new("602.50"),
        last_week_high: Decimal.new("607.00"),
        last_week_low: Decimal.new("598.00"),
        equilibrium: Decimal.new("602.50"),
        all_time_high: Decimal.new("610.00")
      }

      regime = %MarketRegime{
        symbol: "SPY",
        date: ~D[2024-12-14],
        timeframe: "daily",
        regime: :ranging,
        range_high: Decimal.new("607.00"),
        range_low: Decimal.new("598.00"),
        range_duration_days: 5
      }

      premarket = %PremarketSnapshot{
        symbol: "SPY",
        timestamp: DateTime.utc_now(),
        current_price: Decimal.new("602.00"),
        previous_close: Decimal.new("602.50"),
        gap_percent: Decimal.new("-0.08"),
        gap_direction: :down,
        position_in_range: :middle_of_range
      }

      {:ok, key_levels: key_levels, regime: regime, premarket: premarket}
    end

    test "generates bullish and bearish breakout scenarios", %{
      key_levels: key_levels,
      regime: regime,
      premarket: premarket
    } do
      scenarios = ScenarioGenerator.generate(key_levels, regime, premarket)

      assert length(scenarios) >= 2

      bullish = Enum.find(scenarios, &(&1.type == :bullish))
      assert bullish
      assert bullish.trigger_condition == "break above and hold"
      assert Decimal.compare(bullish.trigger_level, regime.range_high) == :eq

      bearish = Enum.find(scenarios, &(&1.type == :bearish))
      assert bearish
      assert bearish.trigger_condition == "break below"
      assert Decimal.compare(bearish.trigger_level, regime.range_low) == :eq
    end

    test "generates bounce scenario when near support", %{key_levels: key_levels, regime: regime} do
      premarket_near_low = %PremarketSnapshot{
        symbol: "SPY",
        timestamp: DateTime.utc_now(),
        current_price: Decimal.new("598.50"),
        previous_close: Decimal.new("602.50"),
        gap_percent: Decimal.new("-0.66"),
        gap_direction: :down,
        position_in_range: :near_prev_day_low
      }

      scenarios = ScenarioGenerator.generate(key_levels, regime, premarket_near_low)

      bounce = Enum.find(scenarios, &(&1.type == :bounce))
      assert bounce
      assert bounce.trigger_condition == "hold above"
    end

    test "generates fade scenario when near resistance", %{key_levels: key_levels, regime: regime} do
      premarket_near_high = %PremarketSnapshot{
        symbol: "SPY",
        timestamp: DateTime.utc_now(),
        current_price: Decimal.new("606.50"),
        previous_close: Decimal.new("602.50"),
        gap_percent: Decimal.new("0.66"),
        gap_direction: :up,
        position_in_range: :near_prev_day_high
      }

      scenarios = ScenarioGenerator.generate(key_levels, regime, premarket_near_high)

      fade = Enum.find(scenarios, &(&1.type == :fade))
      assert fade
      assert fade.trigger_condition == "reject at"
    end

    test "limits scenarios to 4", %{key_levels: key_levels, regime: regime} do
      # Test with price near both levels to potentially generate more scenarios
      premarket = %PremarketSnapshot{
        symbol: "SPY",
        timestamp: DateTime.utc_now(),
        current_price: Decimal.new("598.50"),
        previous_close: Decimal.new("602.50"),
        gap_percent: Decimal.new("-0.66"),
        gap_direction: :down,
        position_in_range: :near_prev_day_low
      }

      scenarios = ScenarioGenerator.generate(key_levels, regime, premarket)
      assert length(scenarios) <= 4
    end
  end

  describe "generate/3 with trending_up regime" do
    setup do
      key_levels = %KeyLevels{
        symbol: "QQQ",
        date: ~D[2024-12-14],
        previous_day_high: Decimal.new("525.00"),
        previous_day_low: Decimal.new("520.00"),
        previous_day_close: Decimal.new("524.00"),
        all_time_high: Decimal.new("530.00")
      }

      regime = %MarketRegime{
        symbol: "QQQ",
        date: ~D[2024-12-14],
        timeframe: "daily",
        regime: :trending_up,
        trend_direction: :up,
        higher_lows_count: 3
      }

      premarket = %PremarketSnapshot{
        symbol: "QQQ",
        timestamp: DateTime.utc_now(),
        current_price: Decimal.new("524.50"),
        previous_close: Decimal.new("524.00"),
        gap_percent: Decimal.new("0.10"),
        gap_direction: :up,
        position_in_range: :middle_of_range
      }

      {:ok, key_levels: key_levels, regime: regime, premarket: premarket}
    end

    test "generates pullback buy scenario", %{
      key_levels: key_levels,
      regime: regime,
      premarket: premarket
    } do
      scenarios = ScenarioGenerator.generate(key_levels, regime, premarket)

      bounce = Enum.find(scenarios, &(&1.type == :bounce))
      assert bounce
      assert bounce.trigger_condition == "dip to and hold"
      assert Decimal.compare(bounce.trigger_level, key_levels.previous_day_low) == :eq
    end

    test "generates continuation scenario", %{
      key_levels: key_levels,
      regime: regime,
      premarket: premarket
    } do
      scenarios = ScenarioGenerator.generate(key_levels, regime, premarket)

      bullish = Enum.find(scenarios, &(&1.type == :bullish))
      assert bullish
      assert bullish.trigger_condition == "break above"
      assert Decimal.compare(bullish.trigger_level, key_levels.previous_day_high) == :eq
    end

    test "generates caution scenario for trend pause", %{
      key_levels: key_levels,
      regime: regime,
      premarket: premarket
    } do
      scenarios = ScenarioGenerator.generate(key_levels, regime, premarket)

      bearish = Enum.find(scenarios, &(&1.type == :bearish))
      assert bearish
      assert String.contains?(bearish.description, "trend pause")
    end
  end

  describe "generate/3 with trending_down regime" do
    setup do
      key_levels = %KeyLevels{
        symbol: "IWM",
        date: ~D[2024-12-14],
        previous_day_high: Decimal.new("220.00"),
        previous_day_low: Decimal.new("215.00"),
        previous_day_close: Decimal.new("216.00")
      }

      regime = %MarketRegime{
        symbol: "IWM",
        date: ~D[2024-12-14],
        timeframe: "daily",
        regime: :trending_down,
        trend_direction: :down,
        lower_highs_count: 4
      }

      premarket = %PremarketSnapshot{
        symbol: "IWM",
        timestamp: DateTime.utc_now(),
        current_price: Decimal.new("216.50"),
        previous_close: Decimal.new("216.00"),
        gap_percent: Decimal.new("0.23"),
        gap_direction: :up,
        position_in_range: :middle_of_range
      }

      {:ok, key_levels: key_levels, regime: regime, premarket: premarket}
    end

    test "generates fade rally scenario", %{
      key_levels: key_levels,
      regime: regime,
      premarket: premarket
    } do
      scenarios = ScenarioGenerator.generate(key_levels, regime, premarket)

      fade = Enum.find(scenarios, &(&1.type == :fade))
      assert fade
      assert fade.trigger_condition == "rally to and reject"
      assert Decimal.compare(fade.trigger_level, key_levels.previous_day_high) == :eq
    end

    test "generates continuation lower scenario", %{
      key_levels: key_levels,
      regime: regime,
      premarket: premarket
    } do
      scenarios = ScenarioGenerator.generate(key_levels, regime, premarket)

      bearish = Enum.find(scenarios, &(&1.type == :bearish))
      assert bearish
      assert bearish.trigger_condition == "break below"
      assert Decimal.compare(bearish.trigger_level, key_levels.previous_day_low) == :eq
    end

    test "generates reversal warning scenario", %{
      key_levels: key_levels,
      regime: regime,
      premarket: premarket
    } do
      scenarios = ScenarioGenerator.generate(key_levels, regime, premarket)

      bullish = Enum.find(scenarios, &(&1.type == :bullish))
      assert bullish
      assert String.contains?(bullish.description, "reversal")
    end
  end

  describe "generate/3 with breakout_pending regime" do
    test "generates same scenarios as ranging" do
      key_levels = %KeyLevels{
        symbol: "SPY",
        date: ~D[2024-12-14],
        previous_day_high: Decimal.new("605.00"),
        previous_day_low: Decimal.new("600.00"),
        previous_day_close: Decimal.new("602.50"),
        last_week_high: Decimal.new("607.00"),
        last_week_low: Decimal.new("598.00")
      }

      breakout_regime = %MarketRegime{
        symbol: "SPY",
        date: ~D[2024-12-14],
        timeframe: "daily",
        regime: :breakout_pending,
        range_high: Decimal.new("607.00"),
        range_low: Decimal.new("598.00")
      }

      premarket = %PremarketSnapshot{
        symbol: "SPY",
        timestamp: DateTime.utc_now(),
        current_price: Decimal.new("602.00"),
        previous_close: Decimal.new("602.50"),
        gap_percent: Decimal.new("-0.08"),
        gap_direction: :down,
        position_in_range: :middle_of_range
      }

      scenarios = ScenarioGenerator.generate(key_levels, breakout_regime, premarket)

      # Should have at least bullish and bearish breakout scenarios
      assert Enum.any?(scenarios, &(&1.type == :bullish))
      assert Enum.any?(scenarios, &(&1.type == :bearish))
    end
  end

  describe "generate_without_premarket/2" do
    test "uses previous_day_close as current price" do
      key_levels = %KeyLevels{
        symbol: "SPY",
        date: ~D[2024-12-14],
        previous_day_high: Decimal.new("605.00"),
        previous_day_low: Decimal.new("600.00"),
        previous_day_close: Decimal.new("602.50"),
        last_week_high: Decimal.new("607.00"),
        last_week_low: Decimal.new("598.00")
      }

      regime = %MarketRegime{
        symbol: "SPY",
        date: ~D[2024-12-14],
        timeframe: "daily",
        regime: :ranging,
        range_high: Decimal.new("607.00"),
        range_low: Decimal.new("598.00")
      }

      scenarios = ScenarioGenerator.generate_without_premarket(key_levels, regime)

      # Should still generate valid scenarios
      assert length(scenarios) >= 2
      assert Enum.any?(scenarios, &(&1.type == :bullish))
      assert Enum.any?(scenarios, &(&1.type == :bearish))
    end

    test "falls back to previous_day_low when close is nil" do
      key_levels = %KeyLevels{
        symbol: "SPY",
        date: ~D[2024-12-14],
        previous_day_high: Decimal.new("605.00"),
        previous_day_low: Decimal.new("600.00"),
        previous_day_close: nil,
        last_week_high: Decimal.new("607.00"),
        last_week_low: Decimal.new("598.00")
      }

      regime = %MarketRegime{
        symbol: "SPY",
        date: ~D[2024-12-14],
        timeframe: "daily",
        regime: :ranging,
        range_high: Decimal.new("607.00"),
        range_low: Decimal.new("598.00")
      }

      # Should not raise an error
      scenarios = ScenarioGenerator.generate_without_premarket(key_levels, regime)
      assert is_list(scenarios)
    end
  end

  describe "scenario descriptions" do
    test "include formatted price levels" do
      key_levels = %KeyLevels{
        symbol: "SPY",
        date: ~D[2024-12-14],
        previous_day_high: Decimal.new("605.50"),
        previous_day_low: Decimal.new("600.25"),
        previous_day_close: Decimal.new("602.50"),
        last_week_high: Decimal.new("607.00"),
        last_week_low: Decimal.new("598.00")
      }

      regime = %MarketRegime{
        symbol: "SPY",
        date: ~D[2024-12-14],
        timeframe: "daily",
        regime: :ranging,
        range_high: Decimal.new("607.00"),
        range_low: Decimal.new("598.00")
      }

      premarket = %PremarketSnapshot{
        symbol: "SPY",
        timestamp: DateTime.utc_now(),
        current_price: Decimal.new("602.00"),
        previous_close: Decimal.new("602.50"),
        gap_percent: Decimal.new("-0.08"),
        gap_direction: :down,
        position_in_range: :middle_of_range
      }

      scenarios = ScenarioGenerator.generate(key_levels, regime, premarket)

      bullish = Enum.find(scenarios, &(&1.type == :bullish))
      # Description should contain the formatted price
      assert String.contains?(bullish.description, "607")
    end
  end
end
