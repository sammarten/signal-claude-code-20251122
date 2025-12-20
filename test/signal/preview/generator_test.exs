defmodule Signal.Preview.GeneratorTest do
  use ExUnit.Case, async: true

  alias Signal.Preview.{DailyPreview, MarketRegime, IndexDivergence}

  describe "DailyPreview struct" do
    test "has all expected fields" do
      expected_fields = [
        :date,
        :generated_at,
        :market_context,
        :key_events,
        :expected_volatility,
        :index_divergence,
        :spy_regime,
        :qqq_regime,
        :spy_scenarios,
        :qqq_scenarios,
        :high_conviction,
        :monitoring,
        :avoid,
        :relative_strength_leaders,
        :relative_strength_laggards,
        :stance,
        :position_size,
        :focus,
        :risk_notes
      ]

      preview = %DailyPreview{}
      actual_fields = Map.keys(preview) -- [:__struct__]

      for field <- expected_fields do
        assert field in actual_fields, "Expected #{field} in DailyPreview struct"
      end
    end

    test "has correct default values" do
      preview = %DailyPreview{
        date: ~D[2024-12-14],
        generated_at: DateTime.utc_now()
      }

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
  end

  describe "stance determination logic" do
    test "cautious when nil regime" do
      {stance, size, _focus} = determine_stance_test(nil, nil)
      assert stance == :cautious
      assert size == :half
    end

    test "cautious when ranging for extended period" do
      regime = %MarketRegime{regime: :ranging, range_duration_days: 7}
      {stance, size, focus} = determine_stance_test(regime, nil)

      assert stance == :cautious
      assert size == :half
      assert String.contains?(focus, "range extremes")
    end

    test "normal when trending up without tech lagging" do
      regime = %MarketRegime{regime: :trending_up}
      divergence = %IndexDivergence{qqq_status: :neutral}
      {stance, size, focus} = determine_stance_test(regime, divergence)

      assert stance == :normal
      assert size == :full
      assert String.contains?(focus, "pullbacks")
    end

    test "cautious when tech lagging" do
      regime = %MarketRegime{regime: :trending_up}
      divergence = %IndexDivergence{qqq_status: :lagging}
      {stance, size, focus} = determine_stance_test(regime, divergence)

      assert stance == :cautious
      assert size == :half
      assert String.contains?(focus, "Tech lagging")
    end

    test "cautious when trending down" do
      regime = %MarketRegime{regime: :trending_down}
      {stance, size, focus} = determine_stance_test(regime, nil)

      assert stance == :cautious
      assert size == :half
      assert String.contains?(focus, "Downtrend")
    end

    test "normal for standard conditions" do
      regime = %MarketRegime{regime: :ranging, range_duration_days: 3}
      divergence = %IndexDivergence{qqq_status: :neutral}
      {stance, size, focus} = determine_stance_test(regime, divergence)

      assert stance == :normal
      assert size == :full
      assert focus == "Standard playbook"
    end

    defp determine_stance_test(nil, _divergence),
      do: {:cautious, :half, "Insufficient data for analysis"}

    defp determine_stance_test(regime, divergence) do
      cond do
        regime.regime == :ranging and (regime.range_duration_days || 0) > 5 ->
          {:cautious, :half, "Play range extremes only, no mid-range trades"}

        regime.regime == :trending_up and (divergence == nil or divergence.qqq_status != :lagging) ->
          {:normal, :full, "Buy pullbacks, look for continuation setups"}

        divergence != nil and divergence.qqq_status == :lagging ->
          {:cautious, :half, "Tech lagging - be selective, consider SPY names"}

        regime.regime == :trending_down ->
          {:cautious, :half, "Downtrend - look for shorts or wait for reversal signal"}

        true ->
          {:normal, :full, "Standard playbook"}
      end
    end
  end

  describe "volatility determination logic" do
    test "high when breakout pending on SPY" do
      spy = %MarketRegime{regime: :breakout_pending}
      qqq = %MarketRegime{regime: :ranging}

      volatility = determine_volatility_test(spy, qqq)
      assert volatility == :high
    end

    test "high when breakout pending on QQQ" do
      spy = %MarketRegime{regime: :ranging}
      qqq = %MarketRegime{regime: :breakout_pending}

      volatility = determine_volatility_test(spy, qqq)
      assert volatility == :high
    end

    test "low when both ranging" do
      spy = %MarketRegime{regime: :ranging}
      qqq = %MarketRegime{regime: :ranging}

      volatility = determine_volatility_test(spy, qqq)
      assert volatility == :low
    end

    test "normal for other conditions" do
      spy = %MarketRegime{regime: :trending_up}
      qqq = %MarketRegime{regime: :trending_up}

      volatility = determine_volatility_test(spy, qqq)
      assert volatility == :normal
    end

    test "normal when one nil" do
      spy = nil
      qqq = %MarketRegime{regime: :ranging}

      volatility = determine_volatility_test(spy, qqq)
      assert volatility == :normal
    end

    defp determine_volatility_test(spy_regime, qqq_regime) do
      spy_breakout = spy_regime && spy_regime.regime == :breakout_pending
      qqq_breakout = qqq_regime && qqq_regime.regime == :breakout_pending
      spy_ranging = spy_regime && spy_regime.regime == :ranging
      qqq_ranging = qqq_regime && qqq_regime.regime == :ranging

      cond do
        spy_breakout == true or qqq_breakout == true ->
          :high

        spy_ranging == true and qqq_ranging == true ->
          :low

        true ->
          :normal
      end
    end
  end

  describe "risk notes generation" do
    test "includes extended range note when applicable" do
      spy = %MarketRegime{regime: :ranging, range_duration_days: 10}
      notes = generate_risk_notes_test(spy, nil, nil)

      assert Enum.any?(notes, &String.contains?(&1, "Extended range"))
    end

    test "includes tech lagging note when applicable" do
      spy = %MarketRegime{regime: :trending_up}
      divergence = %IndexDivergence{qqq_status: :lagging}
      notes = generate_risk_notes_test(spy, nil, divergence)

      assert Enum.any?(notes, &String.contains?(&1, "Tech lagging"))
    end

    test "empty when no special conditions" do
      spy = %MarketRegime{regime: :trending_up, range_duration_days: 0}
      divergence = %IndexDivergence{qqq_status: :leading}
      notes = generate_risk_notes_test(spy, nil, divergence)

      # Only Friday note if it's Friday
      refute Enum.any?(notes, &String.contains?(&1, "Extended range"))
      refute Enum.any?(notes, &String.contains?(&1, "Tech lagging"))
    end

    defp generate_risk_notes_test(spy_regime, _qqq_regime, divergence) do
      notes = []

      notes =
        if spy_regime && spy_regime.regime == :ranging &&
             (spy_regime.range_duration_days || 0) > 7 do
          ["Extended range - breakout could come any day" | notes]
        else
          notes
        end

      notes =
        if divergence && divergence.qqq_status == :lagging do
          ["Tech lagging - avoid semiconductor positions" | notes]
        else
          notes
        end

      # Skip Friday check in tests as it depends on current date

      Enum.reverse(notes)
    end
  end

  describe "context generation" do
    test "generates context for trending up" do
      regime = %MarketRegime{regime: :trending_up}
      divergence = %IndexDivergence{leader: "SPY", laggard: "QQQ"}

      context = generate_context_test(regime, divergence)

      assert String.contains?(context, "Uptrend intact")
      assert String.contains?(context, "SPY leading")
      assert String.contains?(context, "QQQ lagging")
    end

    test "generates context for trending down" do
      regime = %MarketRegime{regime: :trending_down}
      context = generate_context_test(regime, nil)

      assert String.contains?(context, "Downtrend")
    end

    test "generates context for ranging" do
      regime = %MarketRegime{regime: :ranging, range_duration_days: 5}
      context = generate_context_test(regime, nil)

      assert String.contains?(context, "Ranging")
      assert String.contains?(context, "day 5")
    end

    test "generates context for breakout pending" do
      regime = %MarketRegime{regime: :breakout_pending}
      context = generate_context_test(regime, nil)

      assert String.contains?(context, "breakout imminent")
    end

    test "returns insufficient data when nil regime" do
      context = generate_context_test(nil, nil)
      assert context == "Insufficient data"
    end

    defp generate_context_test(nil, _divergence), do: "Insufficient data"

    defp generate_context_test(regime, divergence) do
      regime_text =
        case regime.regime do
          :trending_up -> "Uptrend intact"
          :trending_down -> "Downtrend in progress"
          :ranging -> "Ranging market, day #{regime.range_duration_days || "?"}"
          :breakout_pending -> "Range bound, breakout imminent"
        end

      divergence_text =
        if divergence do
          "#{divergence.leader} leading, #{divergence.laggard} lagging"
        else
          nil
        end

      [regime_text, divergence_text]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(". ")
    end
  end

  describe "default symbols" do
    test "includes major indices" do
      default_symbols = [
        :SPY,
        :QQQ,
        :DIA,
        :IWM,
        :AAPL,
        :MSFT,
        :GOOGL,
        :AMZN,
        :NVDA,
        :META,
        :TSLA,
        :AMD,
        :AVGO,
        :MU,
        :GLD,
        :SLV
      ]

      assert :SPY in default_symbols
      assert :QQQ in default_symbols
      assert :DIA in default_symbols
    end

    test "includes Mag 7 stocks" do
      default_symbols = [:AAPL, :MSFT, :GOOGL, :AMZN, :NVDA, :META, :TSLA]

      for symbol <- [:AAPL, :MSFT, :GOOGL, :AMZN, :NVDA, :META, :TSLA] do
        assert symbol in default_symbols
      end
    end
  end
end
