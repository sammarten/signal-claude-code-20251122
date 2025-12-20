defmodule Signal.Preview.Generator do
  @moduledoc """
  Orchestrates the generation of daily market previews.

  Combines all analysis components:
  - Index divergence analysis (SPY/QQQ/DIA)
  - Market regime detection for indices
  - Relative strength screening for all symbols
  - Scenario generation based on regime
  - Watchlist classification

  ## Usage

      {:ok, preview} = Generator.generate()
      # => %DailyPreview{
      #   date: ~D[2024-12-14],
      #   spy_regime: %MarketRegime{regime: :ranging, ...},
      #   high_conviction: [...],
      #   ...
      # }

      # Generate with custom date
      {:ok, preview} = Generator.generate(date: ~D[2024-12-13])
  """

  alias Signal.Technicals.Levels

  alias Signal.Preview.{
    DailyPreview,
    DivergenceAnalyzer,
    RegimeDetector,
    RelativeStrengthCalculator,
    ScenarioGenerator,
    WatchlistScreener
  }

  @default_symbols [
    # Indices
    :SPY,
    :QQQ,
    :DIA,
    :IWM,
    # Mag 7
    :AAPL,
    :MSFT,
    :GOOGL,
    :AMZN,
    :NVDA,
    :META,
    :TSLA,
    # Semiconductors
    :AMD,
    :AVGO,
    :MU,
    # Commodities
    :GLD,
    :SLV
  ]

  @doc """
  Generates a complete daily market preview.

  ## Options

    * `:date` - Date to generate preview for (default: today)
    * `:symbols` - List of symbols to analyze (default: configured symbols)
    * `:benchmark` - Benchmark for RS calculation (default: :SPY)

  ## Returns

    * `{:ok, %DailyPreview{}}` - Complete preview
    * `{:error, atom()}` - Error during generation
  """
  @spec generate(keyword()) :: {:ok, DailyPreview.t()} | {:error, atom()}
  def generate(opts \\ []) do
    date = Keyword.get(opts, :date, Date.utc_today())
    symbols = Keyword.get(opts, :symbols, get_configured_symbols())
    benchmark = Keyword.get(opts, :benchmark, :SPY)

    with {:ok, {divergence, divergence_history}} <- analyze_divergence_with_history(date),
         {:ok, spy_regime} <- detect_regime(:SPY, date),
         {:ok, qqq_regime} <- detect_regime(:QQQ, date),
         {:ok, spy_scenarios} <- generate_scenarios(:SPY, spy_regime, date),
         {:ok, qqq_scenarios} <- generate_scenarios(:QQQ, qqq_regime, date),
         {:ok, watchlist} <- screen_watchlist(symbols, benchmark, date),
         {:ok, rs_results} <- get_rs_rankings(symbols, benchmark, date) do
      preview =
        build_preview(
          date,
          divergence,
          divergence_history,
          spy_regime,
          qqq_regime,
          spy_scenarios,
          qqq_scenarios,
          watchlist,
          rs_results
        )

      {:ok, preview}
    end
  end

  @doc """
  Generates a preview with minimal data (useful when some data sources fail).
  """
  @spec generate_partial(keyword()) :: {:ok, DailyPreview.t()}
  def generate_partial(opts \\ []) do
    date = Keyword.get(opts, :date, Date.utc_today())
    symbols = Keyword.get(opts, :symbols, get_configured_symbols())
    benchmark = Keyword.get(opts, :benchmark, :SPY)

    {divergence, divergence_history} =
      case analyze_divergence_with_history(date) do
        {:ok, {d, h}} -> {d, h}
        _ -> {nil, nil}
      end

    spy_regime =
      case detect_regime(:SPY, date) do
        {:ok, r} -> r
        _ -> nil
      end

    qqq_regime =
      case detect_regime(:QQQ, date) do
        {:ok, r} -> r
        _ -> nil
      end

    spy_scenarios =
      case generate_scenarios(:SPY, spy_regime, date) do
        {:ok, s} -> s
        _ -> []
      end

    qqq_scenarios =
      case generate_scenarios(:QQQ, qqq_regime, date) do
        {:ok, s} -> s
        _ -> []
      end

    watchlist =
      case screen_watchlist(symbols, benchmark, date) do
        {:ok, w} -> w
        _ -> %{high_conviction: [], monitoring: [], avoid: []}
      end

    rs_results =
      case get_rs_rankings(symbols, benchmark, date) do
        {:ok, r} -> r
        _ -> []
      end

    preview =
      build_preview(
        date,
        divergence,
        divergence_history,
        spy_regime,
        qqq_regime,
        spy_scenarios,
        qqq_scenarios,
        watchlist,
        rs_results
      )

    {:ok, preview}
  end

  # Private Functions

  defp get_configured_symbols do
    Application.get_env(:signal, :symbols, [])
    |> Enum.map(&String.to_atom/1)
    |> case do
      [] -> @default_symbols
      symbols -> symbols
    end
  end

  defp analyze_divergence_with_history(date) do
    DivergenceAnalyzer.analyze_with_history(date)
  end

  defp detect_regime(symbol, date) do
    RegimeDetector.detect(symbol, date)
  end

  defp generate_scenarios(_symbol, nil, _date), do: {:ok, []}

  defp generate_scenarios(symbol, regime, _date) do
    case Levels.get_current_levels(symbol) do
      {:ok, levels} ->
        # Use a simple premarket map if we don't have full premarket data
        premarket = %{current_price: levels.previous_day_close}
        scenarios = ScenarioGenerator.generate(levels, regime, premarket)
        {:ok, scenarios}

      {:error, :not_found} ->
        {:ok, []}
    end
  end

  defp screen_watchlist(symbols, benchmark, date) do
    WatchlistScreener.screen(symbols, benchmark, date)
  end

  defp get_rs_rankings(symbols, benchmark, date) do
    RelativeStrengthCalculator.calculate_all(symbols, benchmark, date)
  end

  defp build_preview(
         date,
         divergence,
         divergence_history,
         spy_regime,
         qqq_regime,
         spy_scenarios,
         qqq_scenarios,
         watchlist,
         rs_results
       ) do
    {stance, position_size, focus} = determine_stance(spy_regime, divergence)
    risk_notes = generate_risk_notes(spy_regime, qqq_regime, divergence)
    expected_volatility = determine_volatility(spy_regime, qqq_regime)

    leaders = RelativeStrengthCalculator.get_leaders(rs_results, 5)
    laggards = RelativeStrengthCalculator.get_laggards(rs_results, 5)

    # Sort RS results by 5-day RS for full rankings display
    sorted_rs_results = Enum.sort_by(rs_results, &Decimal.to_float(&1.rs_5d), :desc)

    %DailyPreview{
      date: date,
      generated_at: DateTime.utc_now(),
      market_context: generate_context(spy_regime, divergence),
      key_events: [],
      expected_volatility: expected_volatility,
      index_divergence: divergence,
      divergence_history: divergence_history,
      spy_regime: spy_regime,
      qqq_regime: qqq_regime,
      spy_scenarios: spy_scenarios,
      qqq_scenarios: qqq_scenarios,
      high_conviction: watchlist.high_conviction,
      monitoring: watchlist.monitoring,
      avoid: watchlist.avoid,
      relative_strength_leaders: Enum.map(leaders, & &1.symbol),
      relative_strength_laggards: Enum.map(laggards, & &1.symbol),
      full_rs_rankings: sorted_rs_results,
      stance: stance,
      position_size: position_size,
      focus: focus,
      risk_notes: risk_notes
    }
  end

  defp determine_stance(nil, _divergence),
    do: {:cautious, :half, "Insufficient data for analysis"}

  defp determine_stance(regime, divergence) do
    cond do
      # Ranging for extended period
      regime.regime == :ranging and (regime.range_duration_days || 0) > 5 ->
        {:cautious, :half, "Play range extremes only, no mid-range trades"}

      # Trending up with aligned divergence
      regime.regime == :trending_up and (divergence == nil or divergence.qqq_status != :lagging) ->
        {:normal, :full, "Buy pullbacks, look for continuation setups"}

      # Tech lagging
      divergence != nil and divergence.qqq_status == :lagging ->
        {:cautious, :half, "Tech lagging - be selective, consider SPY names"}

      # Trending down
      regime.regime == :trending_down ->
        {:cautious, :half, "Downtrend - look for shorts or wait for reversal signal"}

      true ->
        {:normal, :full, "Standard playbook"}
    end
  end

  defp generate_risk_notes(spy_regime, _qqq_regime, divergence) do
    notes = []

    notes =
      if spy_regime && spy_regime.regime == :ranging && (spy_regime.range_duration_days || 0) > 7 do
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

    notes =
      if Date.day_of_week(Date.utc_today()) == 5 do
        ["Friday - expect lower volume into close" | notes]
      else
        notes
      end

    Enum.reverse(notes)
  end

  defp determine_volatility(spy_regime, qqq_regime) do
    cond do
      (spy_regime && spy_regime.regime == :breakout_pending) or
          (qqq_regime && qqq_regime.regime == :breakout_pending) ->
        :high

      (spy_regime && spy_regime.regime == :ranging) and
          (qqq_regime && qqq_regime.regime == :ranging) ->
        :low

      true ->
        :normal
    end
  end

  defp generate_context(nil, _divergence), do: "Insufficient data"

  defp generate_context(regime, divergence) do
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
