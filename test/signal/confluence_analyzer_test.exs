defmodule Signal.ConfluenceAnalyzerTest do
  use ExUnit.Case, async: true

  alias Signal.ConfluenceAnalyzer
  alias Signal.Strategies.Setup

  describe "analyze/2" do
    test "returns analysis with all factor scores" do
      setup = create_setup(:long)

      assert {:ok, analysis} = ConfluenceAnalyzer.analyze(setup)

      assert is_integer(analysis.total_score)
      assert analysis.max_score == 13
      assert analysis.grade in [:A, :B, :C, :D, :F]
      assert is_map(analysis.factors)
      assert is_binary(analysis.summary)

      # Verify all factors are present
      assert Map.has_key?(analysis.factors, :timeframe_alignment)
      assert Map.has_key?(analysis.factors, :pd_array_confluence)
      assert Map.has_key?(analysis.factors, :key_level_confluence)
      assert Map.has_key?(analysis.factors, :market_structure)
      assert Map.has_key?(analysis.factors, :volume)
      assert Map.has_key?(analysis.factors, :price_action)
      assert Map.has_key?(analysis.factors, :timing)
      assert Map.has_key?(analysis.factors, :risk_reward)
    end

    test "adds timeframe alignment points when HTF aligned" do
      setup = create_setup(:long)
      context = %{higher_timeframe: %{trend: :bullish}}

      {:ok, analysis} = ConfluenceAnalyzer.analyze(setup, context)

      assert analysis.factors.timeframe_alignment.score == 3
      assert analysis.factors.timeframe_alignment.present == true
    end

    test "no timeframe points when HTF not aligned" do
      setup = create_setup(:long)
      context = %{higher_timeframe: %{trend: :bearish}}

      {:ok, analysis} = ConfluenceAnalyzer.analyze(setup, context)

      assert analysis.factors.timeframe_alignment.score == 0
      assert analysis.factors.timeframe_alignment.present == false
    end

    test "adds PD array points when OB and FVG present" do
      setup = create_setup(:long)

      context = %{
        pd_arrays: [
          %{type: :order_block, mitigated: false},
          %{type: :fvg, mitigated: false}
        ]
      }

      {:ok, analysis} = ConfluenceAnalyzer.analyze(setup, context)

      assert analysis.factors.pd_array_confluence.score == 2
    end

    test "adds partial PD array points for single array" do
      setup = create_setup(:long)
      context = %{pd_arrays: [%{type: :order_block, mitigated: false}]}

      {:ok, analysis} = ConfluenceAnalyzer.analyze(setup, context)

      assert analysis.factors.pd_array_confluence.score == 1
    end

    test "no PD array points when mitigated" do
      setup = create_setup(:long)

      context = %{
        pd_arrays: [
          %{type: :order_block, mitigated: true},
          %{type: :fvg, mitigated: true}
        ]
      }

      {:ok, analysis} = ConfluenceAnalyzer.analyze(setup, context)

      assert analysis.factors.pd_array_confluence.score == 0
    end

    test "adds market structure points when trend aligned" do
      setup = create_setup(:short)
      context = %{market_structure: %{trend: :bearish}}

      {:ok, analysis} = ConfluenceAnalyzer.analyze(setup, context)

      assert analysis.factors.market_structure.score == 2
      assert analysis.factors.market_structure.present == true
    end

    test "adds price action points when strong rejection present" do
      setup = create_setup_with_confluence(:long, %{strong_rejection: true})

      {:ok, analysis} = ConfluenceAnalyzer.analyze(setup)

      assert analysis.factors.price_action.score == 1
      assert analysis.factors.price_action.present == true
    end

    test "adds risk reward points for 3:1 or better" do
      setup = create_setup_with_rr(:long, "3.5")

      {:ok, analysis} = ConfluenceAnalyzer.analyze(setup)

      assert analysis.factors.risk_reward.score == 1
      assert analysis.factors.risk_reward.present == true
    end

    test "no risk reward bonus for less than 3:1" do
      setup = create_setup_with_rr(:long, "2.5")

      {:ok, analysis} = ConfluenceAnalyzer.analyze(setup)

      assert analysis.factors.risk_reward.score == 0
      # Still present because it meets minimum 2:1
      assert analysis.factors.risk_reward.present == true
    end

    test "calculates correct total score" do
      setup = create_setup_with_confluence(:long, %{strong_rejection: true})

      context = %{
        higher_timeframe: %{trend: :bullish},
        market_structure: %{trend: :bullish},
        pd_arrays: [%{type: :order_block, mitigated: false}]
      }

      {:ok, analysis} = ConfluenceAnalyzer.analyze(setup, context)

      # Calculate expected score
      # HTF aligned: 3
      # Single PD array: 1
      # Structure aligned: 2
      # Strong rejection: 1
      # Total: 7
      assert analysis.total_score == 7
      assert analysis.grade == :C
    end
  end

  describe "assign_grade/1" do
    test "assigns A for score >= 10" do
      assert ConfluenceAnalyzer.assign_grade(10) == :A
      assert ConfluenceAnalyzer.assign_grade(13) == :A
    end

    test "assigns B for score 8-9" do
      assert ConfluenceAnalyzer.assign_grade(8) == :B
      assert ConfluenceAnalyzer.assign_grade(9) == :B
    end

    test "assigns C for score 6-7" do
      assert ConfluenceAnalyzer.assign_grade(6) == :C
      assert ConfluenceAnalyzer.assign_grade(7) == :C
    end

    test "assigns D for score 4-5" do
      assert ConfluenceAnalyzer.assign_grade(4) == :D
      assert ConfluenceAnalyzer.assign_grade(5) == :D
    end

    test "assigns F for score < 4" do
      assert ConfluenceAnalyzer.assign_grade(0) == :F
      assert ConfluenceAnalyzer.assign_grade(3) == :F
    end
  end

  describe "meets_minimum?/2" do
    test "returns true when grade meets minimum" do
      analysis = %{grade: :A}
      assert ConfluenceAnalyzer.meets_minimum?(analysis, :C) == true
      assert ConfluenceAnalyzer.meets_minimum?(analysis, :B) == true
      assert ConfluenceAnalyzer.meets_minimum?(analysis, :A) == true
    end

    test "returns false when grade below minimum" do
      analysis = %{grade: :D}
      assert ConfluenceAnalyzer.meets_minimum?(analysis, :C) == false
      assert ConfluenceAnalyzer.meets_minimum?(analysis, :B) == false
    end

    test "uses default minimum of C" do
      assert ConfluenceAnalyzer.meets_minimum?(%{grade: :C}) == true
      assert ConfluenceAnalyzer.meets_minimum?(%{grade: :D}) == false
    end
  end

  # Helper Functions

  defp create_setup(direction) do
    %Setup{
      symbol: "AAPL",
      strategy: :break_and_retest,
      direction: direction,
      level_type: :pdh,
      level_price: Decimal.new("175.00"),
      entry_price: Decimal.new("175.50"),
      stop_loss: Decimal.new("174.50"),
      take_profit: Decimal.new("177.50"),
      risk_reward: Decimal.new("2.0"),
      timestamp: DateTime.utc_now(),
      status: :pending,
      confluence: %{}
    }
  end

  defp create_setup_with_confluence(direction, confluence) do
    setup = create_setup(direction)
    %{setup | confluence: confluence}
  end

  defp create_setup_with_rr(direction, rr) do
    setup = create_setup(direction)
    %{setup | risk_reward: Decimal.new(rr)}
  end
end
