defmodule Signal.Preview.WatchlistScreener do
  @moduledoc """
  Screens symbols and classifies them into watchlist categories.

  Categories:
  - **high_conviction**: Strong RS, clear setup, high probability
  - **monitoring**: Potential setup developing, needs confirmation
  - **avoid**: Weak RS, choppy, no clear setup

  ## Usage

      {:ok, watchlist} = WatchlistScreener.screen(symbols, :SPY, date)
      # => %{
      #   high_conviction: [%WatchlistItem{symbol: "GLD", ...}],
      #   monitoring: [%WatchlistItem{symbol: "TSLA", ...}],
      #   avoid: [%WatchlistItem{symbol: "AMD", ...}]
      # }
  """

  alias Signal.Technicals.Levels

  alias Signal.Preview.{
    RelativeStrengthCalculator,
    RelativeStrength,
    PremarketAnalyzer,
    WatchlistItem
  }

  @doc """
  Screens symbols and classifies them into watchlist categories.

  ## Parameters

    * `symbols` - List of symbol atoms to screen
    * `benchmark` - Benchmark symbol for RS calculation
    * `date` - Date for analysis

  ## Returns

    * `{:ok, map}` - Map with :high_conviction, :monitoring, :avoid lists
    * `{:error, atom()}` - Error during screening
  """
  @spec screen([atom()], atom(), Date.t()) ::
          {:ok,
           %{
             high_conviction: [WatchlistItem.t()],
             monitoring: [WatchlistItem.t()],
             avoid: [WatchlistItem.t()]
           }}
          | {:error, atom()}
  def screen(symbols, benchmark, date) do
    with {:ok, rs_results} <- RelativeStrengthCalculator.calculate_all(symbols, benchmark, date) do
      watchlist = classify_symbols(rs_results, date)
      {:ok, watchlist}
    end
  end

  @doc """
  Classifies a single symbol based on RS and levels.

  ## Parameters

    * `symbol` - Symbol atom
    * `rs` - RelativeStrength struct
    * `date` - Date for analysis

  ## Returns

    * `{:ok, {category, %WatchlistItem{}}}` - Category and item
    * `{:error, atom()}` - Error during classification
  """
  @spec classify(atom(), RelativeStrength.t(), Date.t()) ::
          {:ok, {atom(), WatchlistItem.t()}} | {:error, atom()}
  def classify(symbol, rs, date) do
    case build_watchlist_item(symbol, rs, date) do
      {:ok, item} ->
        category = determine_category(rs, item)
        {:ok, {category, item}}

      error ->
        error
    end
  end

  # Private Functions

  defp classify_symbols(rs_results, date) do
    classified =
      rs_results
      |> Enum.map(fn rs ->
        symbol = String.to_atom(rs.symbol)
        {:ok, item} = build_watchlist_item(symbol, rs, date)
        category = determine_category(rs, item)
        {category, item}
      end)

    %{
      high_conviction: get_by_category(classified, :high_conviction),
      monitoring: get_by_category(classified, :monitoring),
      avoid: get_by_category(classified, :avoid)
    }
  end

  defp get_by_category(classified, category) do
    classified
    |> Enum.filter(fn {cat, _item} -> cat == category end)
    |> Enum.map(fn {_cat, item} -> item end)
  end

  defp build_watchlist_item(symbol, rs, _date) do
    case Levels.get_current_levels(symbol) do
      {:ok, levels} ->
        {setup, key_level, bias} = determine_setup(symbol, rs, levels)

        item = %WatchlistItem{
          symbol: to_string(symbol),
          setup: setup,
          key_level: key_level,
          bias: bias,
          conviction: determine_conviction(rs),
          notes: generate_notes(rs, levels)
        }

        {:ok, item}

      {:error, :not_found} ->
        # Create item without levels data
        {setup, bias} = determine_setup_from_rs(rs)

        item = %WatchlistItem{
          symbol: to_string(symbol),
          setup: setup,
          key_level: nil,
          bias: bias,
          conviction: determine_conviction(rs),
          notes: generate_notes_from_rs(rs)
        }

        {:ok, item}
    end
  end

  defp determine_setup(symbol, rs, levels) do
    premarket_result = PremarketAnalyzer.analyze(symbol)

    case premarket_result do
      {:ok, premarket} ->
        determine_setup_with_premarket(rs, levels, premarket)

      _ ->
        determine_setup_without_premarket(rs, levels)
    end
  end

  defp determine_setup_with_premarket(rs, levels, premarket) do
    position = premarket.position_in_range
    rs_status = rs.status

    cond do
      # Breakout setup
      position == :above_prev_day_high and rs_status in [:strong_outperform, :outperform] ->
        {"breakout continuation", levels.previous_day_high, :long}

      # Breakdown setup
      position == :below_prev_day_low and rs_status in [:strong_underperform, :underperform] ->
        {"breakdown continuation", levels.previous_day_low, :short}

      # Bounce setup
      position == :near_prev_day_low and rs_status in [:strong_outperform, :outperform, :inline] ->
        {"bounce at support", levels.previous_day_low, :long}

      # Fade setup
      position == :near_prev_day_high and rs_status in [:strong_underperform, :underperform] ->
        {"fade at resistance", levels.previous_day_high, :short}

      # Range play
      position == :middle_of_range ->
        key_level = levels.equilibrium || levels.previous_day_close
        {"ranging - wait for edge", key_level, :neutral}

      true ->
        {"monitoring", levels.previous_day_close, :neutral}
    end
  end

  defp determine_setup_without_premarket(rs, levels) do
    case rs.status do
      :strong_outperform ->
        {"strong momentum", levels.previous_day_high, :long}

      :outperform ->
        {"relative strength", levels.previous_day_high, :long}

      :strong_underperform ->
        {"weak momentum", levels.previous_day_low, :short}

      :underperform ->
        {"relative weakness", levels.previous_day_low, :short}

      _ ->
        {"no clear setup", levels.previous_day_close, :neutral}
    end
  end

  defp determine_setup_from_rs(rs) do
    case rs.status do
      :strong_outperform -> {"strong momentum", :long}
      :outperform -> {"relative strength", :long}
      :strong_underperform -> {"weak momentum", :short}
      :underperform -> {"relative weakness", :short}
      _ -> {"no clear setup", :neutral}
    end
  end

  defp determine_conviction(rs) do
    case rs.status do
      status when status in [:strong_outperform, :strong_underperform] ->
        :high

      status when status in [:outperform, :underperform] ->
        :medium

      _ ->
        :low
    end
  end

  defp determine_category(rs, item) do
    cond do
      # High conviction: strong RS and clear setup
      rs.status in [:strong_outperform, :strong_underperform] and
          item.setup not in ["no clear setup", "monitoring", "ranging - wait for edge"] ->
        :high_conviction

      # Monitoring: moderate RS or needs confirmation
      rs.status in [:outperform, :underperform, :inline] and
          item.setup not in ["no clear setup"] ->
        :monitoring

      # Avoid: no RS edge or no setup
      true ->
        :avoid
    end
  end

  defp generate_notes(rs, levels) do
    rs_note = "RS 5d: #{format_decimal(rs.rs_5d)}%"

    level_note =
      if levels.equilibrium do
        "Eq: #{format_decimal(levels.equilibrium)}"
      else
        nil
      end

    [rs_note, level_note]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end

  defp generate_notes_from_rs(rs) do
    "RS 5d: #{format_decimal(rs.rs_5d)}%"
  end

  defp format_decimal(nil), do: "N/A"

  defp format_decimal(decimal) do
    decimal
    |> Decimal.round(2)
    |> Decimal.to_string()
  end
end
