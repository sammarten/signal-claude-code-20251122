defmodule Signal.ConfluenceAnalyzer do
  @moduledoc """
  Analyzes trade setups for confluence factors and assigns quality scores.

  Confluence refers to multiple independent factors aligning to support a trade.
  Higher confluence generally indicates higher probability setups.

  ## Confluence Factors

  1. **Multi-timeframe alignment** (+3 points): Daily, 30-min, 1-min all agree
  2. **PD Array confluence** (+2 points): Order block + FVG overlap
  3. **Key level confluence** (+2 points): Multiple levels align (PDH + PMH)
  4. **Market structure** (+2 points): BOS in same direction
  5. **Volume confirmation** (+1 point): Above average volume on break
  6. **Price action quality** (+1 point): Strong rejection candle
  7. **Time window** (+1 point): Within first 30 minutes of open
  8. **Risk-reward** (+1 point): 3:1 or better available

  Maximum score: 13 points

  ## Quality Grades

  - **A** (10-13): Excellent - high confidence setup
  - **B** (8-9): Very good - strong probability
  - **C** (6-7): Good - moderate probability
  - **D** (4-5): Fair - lower probability
  - **F** (0-3): Poor - avoid

  ## Usage

      setup = %Setup{...}
      context = %{market_structure: structure, pd_arrays: arrays, ...}

      {:ok, analysis} = ConfluenceAnalyzer.analyze(setup, context)
      # => %{total_score: 10, grade: :A, factors: %{...}}
  """

  alias Signal.Strategies.Setup

  @max_score 13

  @type factor_result :: %{
          score: integer(),
          max_score: integer(),
          present: boolean(),
          details: String.t() | nil
        }

  @type analysis :: %{
          total_score: integer(),
          max_score: integer(),
          grade: :A | :B | :C | :D | :F,
          factors: map(),
          summary: String.t()
        }

  @doc """
  Analyzes a setup for confluence and returns a quality assessment.

  ## Parameters

    * `setup` - The trade setup to analyze
    * `context` - Map containing additional context data:
      * `:market_structure` - Market structure analysis (optional)
      * `:pd_arrays` - List of PD arrays (optional)
      * `:key_levels` - Key levels struct (optional)
      * `:volume_data` - Volume context (optional)
      * `:higher_timeframe` - Higher timeframe analysis (optional)

  ## Returns

    * `{:ok, analysis}` - Analysis results
    * `{:error, reason}` - If analysis fails
  """
  @spec analyze(Setup.t(), map()) :: {:ok, analysis()} | {:error, atom()}
  def analyze(%Setup{} = setup, context \\ %{}) do
    factors = %{
      timeframe_alignment: check_timeframe_alignment(setup, context),
      pd_array_confluence: check_pd_arrays(setup, context),
      key_level_confluence: check_key_levels(setup, context),
      market_structure: check_structure(setup, context),
      volume: check_volume(setup, context),
      price_action: check_price_action(setup),
      timing: check_timing(setup),
      risk_reward: check_risk_reward(setup)
    }

    total_score =
      factors
      |> Map.values()
      |> Enum.map(& &1.score)
      |> Enum.sum()

    grade = assign_grade(total_score)

    analysis = %{
      total_score: total_score,
      max_score: @max_score,
      grade: grade,
      factors: factors,
      summary: generate_summary(factors, grade)
    }

    {:ok, analysis}
  end

  @doc """
  Returns the quality grade for a given score.

  ## Parameters

    * `score` - Total confluence score

  ## Returns

  Quality grade atom (:A, :B, :C, :D, or :F).
  """
  @spec assign_grade(integer()) :: :A | :B | :C | :D | :F
  def assign_grade(score) when score >= 10, do: :A
  def assign_grade(score) when score >= 8, do: :B
  def assign_grade(score) when score >= 6, do: :C
  def assign_grade(score) when score >= 4, do: :D
  def assign_grade(_score), do: :F

  @doc """
  Checks if a setup meets minimum quality requirements.

  ## Parameters

    * `analysis` - The confluence analysis
    * `min_grade` - Minimum acceptable grade (default: :C)

  ## Returns

  Boolean indicating if setup meets requirements.
  """
  @spec meets_minimum?(analysis(), atom()) :: boolean()
  def meets_minimum?(analysis, min_grade \\ :C) do
    grade_order = %{A: 5, B: 4, C: 3, D: 2, F: 1}
    grade_order[analysis.grade] >= grade_order[min_grade]
  end

  # Factor Checkers

  defp check_timeframe_alignment(%Setup{} = setup, context) do
    htf = Map.get(context, :higher_timeframe)

    cond do
      is_nil(htf) ->
        %{score: 0, max_score: 3, present: false, details: "Higher timeframe data not available"}

      htf_aligned?(setup.direction, htf) ->
        %{
          score: 3,
          max_score: 3,
          present: true,
          details: "All timeframes aligned #{setup.direction}"
        }

      true ->
        %{score: 0, max_score: 3, present: false, details: "Timeframes not aligned"}
    end
  end

  defp check_pd_arrays(%Setup{} = setup, context) do
    confluence = Map.get(setup.confluence, :pd_array_overlap, false)
    pd_arrays = Map.get(context, :pd_arrays, [])

    has_ob = Enum.any?(pd_arrays, &(&1.type == :order_block and not &1.mitigated))
    has_fvg = Enum.any?(pd_arrays, &(&1.type == :fvg and not &1.mitigated))

    cond do
      confluence or (has_ob and has_fvg) ->
        %{score: 2, max_score: 2, present: true, details: "Order block with FVG overlap"}

      has_ob or has_fvg ->
        %{score: 1, max_score: 2, present: true, details: "Single PD array present"}

      true ->
        %{score: 0, max_score: 2, present: false, details: "No PD array confluence"}
    end
  end

  defp check_key_levels(%Setup{} = setup, context) do
    levels = Map.get(context, :key_levels)
    level_type = setup.level_type

    # Check if multiple key levels align near the setup level
    aligned_levels = count_aligned_levels(setup.level_price, levels)

    cond do
      is_nil(levels) ->
        %{score: 0, max_score: 2, present: false, details: "Key levels not available"}

      aligned_levels >= 2 ->
        %{score: 2, max_score: 2, present: true, details: "#{aligned_levels} levels aligned"}

      level_type in [:pdh, :pdl] ->
        %{score: 1, max_score: 2, present: true, details: "Previous day level"}

      true ->
        %{score: 0, max_score: 2, present: false, details: "Single level only"}
    end
  end

  defp check_structure(%Setup{} = setup, context) do
    structure = Map.get(context, :market_structure)

    cond do
      is_nil(structure) ->
        %{score: 0, max_score: 2, present: false, details: "Market structure not available"}

      structure_aligned?(setup.direction, structure) ->
        %{
          score: 2,
          max_score: 2,
          present: true,
          details: "BOS confirms #{setup.direction} direction"
        }

      true ->
        %{score: 0, max_score: 2, present: false, details: "Structure not aligned"}
    end
  end

  defp check_volume(%Setup{} = _setup, context) do
    volume_data = Map.get(context, :volume_data)

    cond do
      is_nil(volume_data) ->
        %{score: 0, max_score: 1, present: false, details: "Volume data not available"}

      above_average_volume?(volume_data) ->
        %{score: 1, max_score: 1, present: true, details: "Above average volume on break"}

      true ->
        %{score: 0, max_score: 1, present: false, details: "Below average volume"}
    end
  end

  defp check_price_action(%Setup{} = setup) do
    strong_rejection = get_in(setup.confluence, [:strong_rejection]) || false

    if strong_rejection do
      %{score: 1, max_score: 1, present: true, details: "Strong rejection candle"}
    else
      %{score: 0, max_score: 1, present: false, details: "No strong rejection"}
    end
  end

  defp check_timing(%Setup{} = setup) do
    timestamp = setup.timestamp

    cond do
      is_nil(timestamp) ->
        %{score: 0, max_score: 1, present: false, details: "Timestamp not available"}

      within_first_30_minutes?(timestamp) ->
        %{score: 1, max_score: 1, present: true, details: "Within first 30 minutes of open"}

      within_trading_window?(timestamp) ->
        %{
          score: 0,
          max_score: 1,
          present: true,
          details: "Within trading window but after first 30 min"
        }

      true ->
        %{score: 0, max_score: 1, present: false, details: "Outside trading window"}
    end
  end

  defp check_risk_reward(%Setup{} = setup) do
    rr = setup.risk_reward

    cond do
      is_nil(rr) ->
        %{score: 0, max_score: 1, present: false, details: "Risk/reward not calculated"}

      Decimal.compare(rr, Decimal.new("3.0")) != :lt ->
        %{score: 1, max_score: 1, present: true, details: "R:R of #{Decimal.round(rr, 1)}:1"}

      Decimal.compare(rr, Decimal.new("2.0")) != :lt ->
        %{
          score: 0,
          max_score: 1,
          present: true,
          details: "R:R of #{Decimal.round(rr, 1)}:1 (meets minimum)"
        }

      true ->
        %{score: 0, max_score: 1, present: false, details: "R:R below 2:1"}
    end
  end

  # Helper Functions

  defp htf_aligned?(direction, htf) do
    case {direction, htf.trend} do
      {:long, :bullish} -> true
      {:short, :bearish} -> true
      _ -> false
    end
  end

  defp count_aligned_levels(_level_price, nil), do: 0

  defp count_aligned_levels(level_price, levels) do
    tolerance = Decimal.mult(level_price, Decimal.new("0.002"))

    all_levels = [
      levels.previous_day_high,
      levels.previous_day_low,
      levels.premarket_high,
      levels.premarket_low,
      levels.opening_range_5m_high,
      levels.opening_range_5m_low,
      levels.opening_range_15m_high,
      levels.opening_range_15m_low
    ]

    all_levels
    |> Enum.reject(&is_nil/1)
    |> Enum.count(fn lvl ->
      diff = Decimal.abs(Decimal.sub(lvl, level_price))
      Decimal.compare(diff, tolerance) != :gt
    end)
  end

  defp structure_aligned?(direction, structure) do
    case {direction, structure.trend} do
      {:long, :bullish} -> true
      {:short, :bearish} -> true
      _ -> false
    end
  end

  defp above_average_volume?(%{break_volume: vol, average_volume: avg}) do
    Decimal.compare(vol, avg) == :gt
  end

  defp above_average_volume?(_), do: false

  defp within_first_30_minutes?(timestamp) do
    case DateTime.shift_zone(timestamp, "America/New_York") do
      {:ok, et_time} ->
        time = DateTime.to_time(et_time)
        # First 30 minutes: 9:30 - 10:00 AM ET
        Time.compare(time, ~T[09:30:00]) != :lt and Time.compare(time, ~T[10:00:00]) == :lt

      {:error, _} ->
        false
    end
  end

  defp within_trading_window?(timestamp) do
    case DateTime.shift_zone(timestamp, "America/New_York") do
      {:ok, et_time} ->
        time = DateTime.to_time(et_time)
        # Trading window: 9:30 - 11:00 AM ET
        Time.compare(time, ~T[09:30:00]) != :lt and Time.compare(time, ~T[11:00:00]) != :gt

      {:error, _} ->
        false
    end
  end

  defp generate_summary(factors, grade) do
    present_factors =
      factors
      |> Enum.filter(fn {_k, v} -> v.present end)
      |> Enum.map(fn {k, _v} -> factor_name(k) end)

    case grade do
      :A ->
        "Excellent setup with #{length(present_factors)} confluence factors: #{Enum.join(present_factors, ", ")}"

      :B ->
        "Strong setup with #{length(present_factors)} factors: #{Enum.join(present_factors, ", ")}"

      :C ->
        "Good setup with #{length(present_factors)} factors: #{Enum.join(present_factors, ", ")}"

      :D ->
        "Fair setup - consider additional confirmation"

      :F ->
        "Weak setup - insufficient confluence"
    end
  end

  defp factor_name(:timeframe_alignment), do: "MTF"
  defp factor_name(:pd_array_confluence), do: "PD Array"
  defp factor_name(:key_level_confluence), do: "Key Level"
  defp factor_name(:market_structure), do: "Structure"
  defp factor_name(:volume), do: "Volume"
  defp factor_name(:price_action), do: "Price Action"
  defp factor_name(:timing), do: "Timing"
  defp factor_name(:risk_reward), do: "R:R"
end
