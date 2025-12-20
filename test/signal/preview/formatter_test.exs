defmodule Signal.Preview.FormatterTest do
  use ExUnit.Case, async: true

  alias Signal.Preview.{
    Formatter,
    DailyPreview,
    MarketRegime,
    IndexDivergence,
    Scenario,
    WatchlistItem
  }

  describe "to_markdown/1" do
    setup do
      preview = build_complete_preview()
      {:ok, preview: preview}
    end

    test "includes header with date", %{preview: preview} do
      output = Formatter.to_markdown(preview)

      assert String.contains?(output, "DAILY MARKET PREVIEW")
      assert String.contains?(output, "Saturday, December 14, 2024")
    end

    test "includes generated timestamp in ET", %{preview: preview} do
      output = Formatter.to_markdown(preview)

      assert String.contains?(output, "Generated:")
      assert String.contains?(output, "ET")
    end

    test "includes overnight summary section", %{preview: preview} do
      output = Formatter.to_markdown(preview)

      assert String.contains?(output, "OVERNIGHT SUMMARY")
      assert String.contains?(output, "Futures slightly lower")
    end

    test "includes market regime", %{preview: preview} do
      output = Formatter.to_markdown(preview)

      assert String.contains?(output, "MARKET REGIME:")
      assert String.contains?(output, "RANGING")
    end

    test "includes expected volatility", %{preview: preview} do
      output = Formatter.to_markdown(preview)

      assert String.contains?(output, "Expected Volatility:")
      assert String.contains?(output, "NORMAL")
    end

    test "includes index divergence section", %{preview: preview} do
      output = Formatter.to_markdown(preview)

      assert String.contains?(output, "INDEX DIVERGENCE")
      assert String.contains?(output, "SPY")
      assert String.contains?(output, "QQQ")
      assert String.contains?(output, "DIA")
      assert String.contains?(output, "LEADING")
      assert String.contains?(output, "LAGGING")
    end

    test "includes SPY key levels section", %{preview: preview} do
      output = Formatter.to_markdown(preview)

      assert String.contains?(output, "SPY KEY LEVELS")
      assert String.contains?(output, "Resistance:")
      assert String.contains?(output, "Support:")
    end

    test "includes SPY scenarios section", %{preview: preview} do
      output = Formatter.to_markdown(preview)

      assert String.contains?(output, "SCENARIOS")
      assert String.contains?(output, "BULLISH")
      assert String.contains?(output, "BEARISH")
    end

    test "includes QQQ key levels section", %{preview: preview} do
      output = Formatter.to_markdown(preview)

      assert String.contains?(output, "QQQ KEY LEVELS")
    end

    test "includes watchlist section with categories", %{preview: preview} do
      output = Formatter.to_markdown(preview)

      assert String.contains?(output, "WATCHLIST")
      assert String.contains?(output, "HIGH CONVICTION:")
      assert String.contains?(output, "MONITORING:")
      assert String.contains?(output, "AVOID/CAUTIOUS:")
    end

    test "includes watchlist items with details", %{preview: preview} do
      output = Formatter.to_markdown(preview)

      assert String.contains?(output, "NVDA")
      assert String.contains?(output, "breakout continuation")
      assert String.contains?(output, "LONG bias")
    end

    test "includes sector notes section", %{preview: preview} do
      output = Formatter.to_markdown(preview)

      assert String.contains?(output, "SECTOR NOTES")
      assert String.contains?(output, "Relative Strength:")
      assert String.contains?(output, "Relative Weakness:")
    end

    test "includes game plan section", %{preview: preview} do
      output = Formatter.to_markdown(preview)

      assert String.contains?(output, "GAME PLAN")
      assert String.contains?(output, "Stance:")
      assert String.contains?(output, "Size:")
      assert String.contains?(output, "Focus:")
    end

    test "includes risk notes", %{preview: preview} do
      output = Formatter.to_markdown(preview)

      assert String.contains?(output, "Risk Notes:")
      assert String.contains?(output, "FOMC next week")
    end

    test "uses double line separators for header and footer", %{preview: preview} do
      output = Formatter.to_markdown(preview)

      # Double line character
      assert String.contains?(output, "═")
    end

    test "uses single line separators for sections", %{preview: preview} do
      output = Formatter.to_markdown(preview)

      # Single line character
      assert String.contains?(output, "─")
    end
  end

  describe "to_markdown/1 with minimal data" do
    test "handles nil index divergence" do
      preview = %DailyPreview{
        date: ~D[2024-12-14],
        generated_at: DateTime.utc_now(),
        index_divergence: nil
      }

      output = Formatter.to_markdown(preview)

      # Should not crash and should not include divergence section
      refute String.contains?(output, "INDEX DIVERGENCE")
    end

    test "handles nil spy_regime" do
      preview = %DailyPreview{
        date: ~D[2024-12-14],
        generated_at: DateTime.utc_now(),
        spy_regime: nil
      }

      output = Formatter.to_markdown(preview)

      # Should show UNKNOWN regime
      assert String.contains?(output, "MARKET REGIME: UNKNOWN")
    end

    test "handles empty scenarios" do
      preview = %DailyPreview{
        date: ~D[2024-12-14],
        generated_at: DateTime.utc_now(),
        spy_regime: %MarketRegime{
          regime: :ranging,
          range_high: Decimal.new("600.00"),
          range_low: Decimal.new("590.00")
        },
        spy_scenarios: [],
        qqq_scenarios: []
      }

      output = Formatter.to_markdown(preview)

      assert String.contains?(output, "No scenarios available")
    end

    test "handles empty watchlist" do
      preview = %DailyPreview{
        date: ~D[2024-12-14],
        generated_at: DateTime.utc_now(),
        high_conviction: [],
        monitoring: [],
        avoid: []
      }

      output = Formatter.to_markdown(preview)

      assert String.contains?(output, "(none)")
    end

    test "handles empty risk notes" do
      preview = %DailyPreview{
        date: ~D[2024-12-14],
        generated_at: DateTime.utc_now(),
        risk_notes: []
      }

      output = Formatter.to_markdown(preview)

      assert String.contains?(output, "No specific risk notes")
    end
  end

  describe "to_markdown/1 formatting" do
    test "formats percentages with sign" do
      preview = build_complete_preview()
      output = Formatter.to_markdown(preview)

      # Positive percentage should have + sign
      assert String.contains?(output, "+")
    end

    test "formats regime with range duration" do
      preview = %DailyPreview{
        date: ~D[2024-12-14],
        generated_at: DateTime.utc_now(),
        spy_regime: %MarketRegime{
          regime: :ranging,
          range_duration_days: 5
        }
      }

      output = Formatter.to_markdown(preview)

      assert String.contains?(output, "RANGING (Day 5)")
    end

    test "formats different stance values" do
      for {stance, expected} <- [
            {:aggressive, "AGGRESSIVE"},
            {:normal, "NORMAL"},
            {:cautious, "CAUTIOUS"},
            {:hands_off, "HANDS OFF"}
          ] do
        preview = %DailyPreview{
          date: ~D[2024-12-14],
          generated_at: DateTime.utc_now(),
          stance: stance
        }

        output = Formatter.to_markdown(preview)
        assert String.contains?(output, expected)
      end
    end

    test "formats different position sizes" do
      for {size, expected} <- [
            {:full, "FULL"},
            {:half, "HALF"},
            {:quarter, "QUARTER"}
          ] do
        preview = %DailyPreview{
          date: ~D[2024-12-14],
          generated_at: DateTime.utc_now(),
          position_size: size
        }

        output = Formatter.to_markdown(preview)
        assert String.contains?(output, expected)
      end
    end

    test "formats different volatility levels" do
      for {vol, expected} <- [
            {:high, "HIGH"},
            {:normal, "NORMAL"},
            {:low, "LOW"}
          ] do
        preview = %DailyPreview{
          date: ~D[2024-12-14],
          generated_at: DateTime.utc_now(),
          expected_volatility: vol
        }

        output = Formatter.to_markdown(preview)
        assert String.contains?(output, "Expected Volatility: #{expected}")
      end
    end
  end

  describe "to_json/1" do
    setup do
      preview = build_complete_preview()
      {:ok, preview: preview}
    end

    test "returns valid JSON", %{preview: preview} do
      json = Formatter.to_json(preview)

      assert {:ok, _} = Jason.decode(json)
    end

    test "includes date in ISO format", %{preview: preview} do
      json = Formatter.to_json(preview)
      {:ok, decoded} = Jason.decode(json)

      assert decoded["date"] == "2024-12-14"
    end

    test "includes generated_at in ISO format", %{preview: preview} do
      json = Formatter.to_json(preview)
      {:ok, decoded} = Jason.decode(json)

      assert is_binary(decoded["generated_at"])
      # Should be parseable as ISO 8601
      assert {:ok, _, _} = DateTime.from_iso8601(decoded["generated_at"])
    end

    test "includes market context", %{preview: preview} do
      json = Formatter.to_json(preview)
      {:ok, decoded} = Jason.decode(json)

      assert decoded["market_context"] == "Futures slightly lower"
    end

    test "includes index divergence", %{preview: preview} do
      json = Formatter.to_json(preview)
      {:ok, decoded} = Jason.decode(json)

      div = decoded["index_divergence"]
      assert div["spy"]["status"] == "leading"
      assert div["qqq"]["status"] == "lagging"
      assert div["leader"] == "SPY"
      assert div["laggard"] == "QQQ"
    end

    test "includes spy regime", %{preview: preview} do
      json = Formatter.to_json(preview)
      {:ok, decoded} = Jason.decode(json)

      regime = decoded["spy_regime"]
      assert regime["regime"] == "ranging"
      assert is_number(regime["range_high"])
      assert is_number(regime["range_low"])
    end

    test "includes scenarios", %{preview: preview} do
      json = Formatter.to_json(preview)
      {:ok, decoded} = Jason.decode(json)

      spy_scenarios = decoded["spy_scenarios"]
      assert length(spy_scenarios) == 2

      first = hd(spy_scenarios)
      assert first["type"] == "bullish"
      assert is_number(first["trigger_level"])
      assert is_binary(first["trigger_condition"])
    end

    test "includes watchlist categories", %{preview: preview} do
      json = Formatter.to_json(preview)
      {:ok, decoded} = Jason.decode(json)

      watchlist = decoded["watchlist"]
      assert is_list(watchlist["high_conviction"])
      assert is_list(watchlist["monitoring"])
      assert is_list(watchlist["avoid"])

      high = hd(watchlist["high_conviction"])
      assert high["symbol"] == "NVDA"
      assert high["bias"] == "long"
    end

    test "includes relative strength", %{preview: preview} do
      json = Formatter.to_json(preview)
      {:ok, decoded} = Jason.decode(json)

      rs = decoded["relative_strength"]
      assert is_list(rs["leaders"])
      assert is_list(rs["laggards"])
    end

    test "includes game plan", %{preview: preview} do
      json = Formatter.to_json(preview)
      {:ok, decoded} = Jason.decode(json)

      plan = decoded["game_plan"]
      assert plan["stance"] == "normal"
      assert plan["position_size"] == "full"
      assert is_binary(plan["focus"])
      assert is_list(plan["risk_notes"])
    end

    test "converts decimal values to floats", %{preview: preview} do
      json = Formatter.to_json(preview)
      {:ok, decoded} = Jason.decode(json)

      regime = decoded["spy_regime"]
      # Should be a float, not a string
      assert is_float(regime["range_high"]) or is_integer(regime["range_high"])
    end
  end

  describe "to_json/1 with nil values" do
    test "handles nil index divergence" do
      preview = %DailyPreview{
        date: ~D[2024-12-14],
        generated_at: DateTime.utc_now(),
        index_divergence: nil
      }

      json = Formatter.to_json(preview)
      {:ok, decoded} = Jason.decode(json)

      assert is_nil(decoded["index_divergence"])
    end

    test "handles nil regime" do
      preview = %DailyPreview{
        date: ~D[2024-12-14],
        generated_at: DateTime.utc_now(),
        spy_regime: nil,
        qqq_regime: nil
      }

      json = Formatter.to_json(preview)
      {:ok, decoded} = Jason.decode(json)

      assert is_nil(decoded["spy_regime"])
      assert is_nil(decoded["qqq_regime"])
    end
  end

  # Helper Functions

  defp build_complete_preview do
    %DailyPreview{
      date: ~D[2024-12-14],
      generated_at: ~U[2024-12-14 11:30:00Z],
      market_context: "Futures slightly lower",
      expected_volatility: :normal,
      index_divergence: %IndexDivergence{
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
        implication: "Tech lagging broad market"
      },
      spy_regime: %MarketRegime{
        symbol: "SPY",
        date: ~D[2024-12-14],
        timeframe: "daily",
        regime: :ranging,
        range_high: Decimal.new("607.00"),
        range_low: Decimal.new("598.00"),
        range_duration_days: 5,
        distance_from_ath_percent: Decimal.new("1.5")
      },
      qqq_regime: %MarketRegime{
        symbol: "QQQ",
        date: ~D[2024-12-14],
        timeframe: "daily",
        regime: :ranging,
        range_high: Decimal.new("525.00"),
        range_low: Decimal.new("515.00")
      },
      spy_scenarios: [
        %Scenario{
          type: :bullish,
          trigger_level: Decimal.new("607.00"),
          trigger_condition: "break above and hold",
          target_level: Decimal.new("610.00"),
          description: "Break above 607, target ATH"
        },
        %Scenario{
          type: :bearish,
          trigger_level: Decimal.new("598.00"),
          trigger_condition: "break below",
          target_level: Decimal.new("595.00"),
          description: "Break below 598, continuation lower"
        }
      ],
      qqq_scenarios: [
        %Scenario{
          type: :bullish,
          trigger_level: Decimal.new("525.00"),
          trigger_condition: "break above",
          target_level: Decimal.new("530.00"),
          description: "Break above 525"
        }
      ],
      high_conviction: [
        %WatchlistItem{
          symbol: "NVDA",
          setup: "breakout continuation",
          key_level: Decimal.new("140.00"),
          bias: :long,
          conviction: :high,
          notes: "Strong momentum"
        }
      ],
      monitoring: [
        %WatchlistItem{
          symbol: "TSLA",
          setup: "bounce at support",
          key_level: Decimal.new("250.00"),
          bias: :long,
          conviction: :medium,
          notes: "Needs confirmation"
        }
      ],
      avoid: [
        %WatchlistItem{
          symbol: "AMD",
          setup: "no clear setup",
          key_level: nil,
          bias: :neutral,
          conviction: :low,
          notes: "Choppy price action"
        }
      ],
      relative_strength_leaders: ["NVDA", "META"],
      relative_strength_laggards: ["AMD", "INTC"],
      stance: :normal,
      position_size: :full,
      focus: "Range plays near edges",
      risk_notes: ["FOMC next week", "Triple witching Friday"]
    }
  end
end
