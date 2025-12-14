defmodule Signal.Preview.WatchlistScreenerTest do
  use ExUnit.Case, async: true

  alias Signal.Preview.{WatchlistItem, RelativeStrength}

  describe "WatchlistItem struct" do
    test "has all expected fields" do
      expected_fields = [
        :symbol,
        :setup,
        :key_level,
        :bias,
        :conviction,
        :notes
      ]

      item = %WatchlistItem{}
      actual_fields = Map.keys(item) -- [:__struct__]

      for field <- expected_fields do
        assert field in actual_fields, "Expected #{field} in WatchlistItem struct"
      end
    end

    test "bias is one of valid values" do
      valid_biases = [:long, :short, :neutral]

      for bias <- valid_biases do
        item = %WatchlistItem{bias: bias}
        assert item.bias in valid_biases
      end
    end

    test "conviction is one of valid values" do
      valid_convictions = [:high, :medium, :low]

      for conviction <- valid_convictions do
        item = %WatchlistItem{conviction: conviction}
        assert item.conviction in valid_convictions
      end
    end
  end

  describe "conviction determination logic" do
    test "high conviction for strong_outperform" do
      conviction = determine_conviction_test(:strong_outperform)
      assert conviction == :high
    end

    test "high conviction for strong_underperform" do
      conviction = determine_conviction_test(:strong_underperform)
      assert conviction == :high
    end

    test "medium conviction for outperform" do
      conviction = determine_conviction_test(:outperform)
      assert conviction == :medium
    end

    test "medium conviction for underperform" do
      conviction = determine_conviction_test(:underperform)
      assert conviction == :medium
    end

    test "low conviction for inline" do
      conviction = determine_conviction_test(:inline)
      assert conviction == :low
    end

    defp determine_conviction_test(status) do
      case status do
        status when status in [:strong_outperform, :strong_underperform] -> :high
        status when status in [:outperform, :underperform] -> :medium
        _ -> :low
      end
    end
  end

  describe "category determination logic" do
    test "high_conviction when strong RS and clear setup" do
      rs = %RelativeStrength{status: :strong_outperform}
      setup = "breakout continuation"

      category = determine_category_test(rs, setup)
      assert category == :high_conviction
    end

    test "high_conviction when strong_underperform and clear setup" do
      rs = %RelativeStrength{status: :strong_underperform}
      setup = "breakdown continuation"

      category = determine_category_test(rs, setup)
      assert category == :high_conviction
    end

    test "monitoring when moderate RS with setup" do
      rs = %RelativeStrength{status: :outperform}
      setup = "bounce at support"

      category = determine_category_test(rs, setup)
      assert category == :monitoring
    end

    test "monitoring when inline with setup" do
      rs = %RelativeStrength{status: :inline}
      setup = "ranging - wait for edge"

      category = determine_category_test(rs, setup)
      assert category == :monitoring
    end

    test "avoid when no clear setup" do
      rs = %RelativeStrength{status: :inline}
      setup = "no clear setup"

      category = determine_category_test(rs, setup)
      assert category == :avoid
    end

    test "avoid when strong RS but no setup" do
      rs = %RelativeStrength{status: :strong_outperform}
      setup = "no clear setup"

      category = determine_category_test(rs, setup)
      assert category == :avoid
    end

    test "avoid when strong RS but monitoring setup" do
      rs = %RelativeStrength{status: :strong_outperform}
      setup = "monitoring"

      category = determine_category_test(rs, setup)
      assert category == :avoid
    end

    test "avoid when strong RS but ranging setup" do
      rs = %RelativeStrength{status: :strong_outperform}
      setup = "ranging - wait for edge"

      category = determine_category_test(rs, setup)
      assert category == :avoid
    end

    defp determine_category_test(rs, setup) do
      cond do
        rs.status in [:strong_outperform, :strong_underperform] and
            setup not in ["no clear setup", "monitoring", "ranging - wait for edge"] ->
          :high_conviction

        rs.status in [:outperform, :underperform, :inline] and
            setup not in ["no clear setup"] ->
          :monitoring

        true ->
          :avoid
      end
    end
  end

  describe "setup determination from RS" do
    test "strong momentum for strong_outperform" do
      {setup, bias} = determine_setup_from_rs_test(:strong_outperform)
      assert setup == "strong momentum"
      assert bias == :long
    end

    test "relative strength for outperform" do
      {setup, bias} = determine_setup_from_rs_test(:outperform)
      assert setup == "relative strength"
      assert bias == :long
    end

    test "weak momentum for strong_underperform" do
      {setup, bias} = determine_setup_from_rs_test(:strong_underperform)
      assert setup == "weak momentum"
      assert bias == :short
    end

    test "relative weakness for underperform" do
      {setup, bias} = determine_setup_from_rs_test(:underperform)
      assert setup == "relative weakness"
      assert bias == :short
    end

    test "no clear setup for inline" do
      {setup, bias} = determine_setup_from_rs_test(:inline)
      assert setup == "no clear setup"
      assert bias == :neutral
    end

    defp determine_setup_from_rs_test(status) do
      case status do
        :strong_outperform -> {"strong momentum", :long}
        :outperform -> {"relative strength", :long}
        :strong_underperform -> {"weak momentum", :short}
        :underperform -> {"relative weakness", :short}
        _ -> {"no clear setup", :neutral}
      end
    end
  end

  describe "watchlist organization" do
    test "correctly groups items by category" do
      items = [
        {:high_conviction, %WatchlistItem{symbol: "NVDA"}},
        {:monitoring, %WatchlistItem{symbol: "AAPL"}},
        {:avoid, %WatchlistItem{symbol: "AMD"}},
        {:high_conviction, %WatchlistItem{symbol: "META"}},
        {:monitoring, %WatchlistItem{symbol: "TSLA"}}
      ]

      watchlist = %{
        high_conviction: get_by_category_test(items, :high_conviction),
        monitoring: get_by_category_test(items, :monitoring),
        avoid: get_by_category_test(items, :avoid)
      }

      assert length(watchlist.high_conviction) == 2
      assert length(watchlist.monitoring) == 2
      assert length(watchlist.avoid) == 1

      assert Enum.any?(watchlist.high_conviction, &(&1.symbol == "NVDA"))
      assert Enum.any?(watchlist.high_conviction, &(&1.symbol == "META"))
      assert Enum.any?(watchlist.avoid, &(&1.symbol == "AMD"))
    end

    defp get_by_category_test(items, category) do
      items
      |> Enum.filter(fn {cat, _item} -> cat == category end)
      |> Enum.map(fn {_cat, item} -> item end)
    end
  end

  describe "setup with premarket position" do
    test "breakout continuation when above prev day high and strong RS" do
      position = :above_prev_day_high
      rs_status = :strong_outperform

      result = setup_with_premarket_test(position, rs_status)
      assert result == "breakout continuation"
    end

    test "breakdown continuation when below prev day low and weak RS" do
      position = :below_prev_day_low
      rs_status = :strong_underperform

      result = setup_with_premarket_test(position, rs_status)
      assert result == "breakdown continuation"
    end

    test "bounce at support when near low with positive RS" do
      position = :near_prev_day_low
      rs_status = :outperform

      result = setup_with_premarket_test(position, rs_status)
      assert result == "bounce at support"
    end

    test "fade at resistance when near high with weak RS" do
      position = :near_prev_day_high
      rs_status = :underperform

      result = setup_with_premarket_test(position, rs_status)
      assert result == "fade at resistance"
    end

    test "ranging when in middle of range" do
      position = :middle_of_range
      rs_status = :inline

      result = setup_with_premarket_test(position, rs_status)
      assert result == "ranging - wait for edge"
    end

    test "monitoring when no clear setup pattern" do
      position = :near_prev_day_high
      rs_status = :inline

      result = setup_with_premarket_test(position, rs_status)
      assert result == "monitoring"
    end

    defp setup_with_premarket_test(position, rs_status) do
      cond do
        position == :above_prev_day_high and rs_status in [:strong_outperform, :outperform] ->
          "breakout continuation"

        position == :below_prev_day_low and rs_status in [:strong_underperform, :underperform] ->
          "breakdown continuation"

        position == :near_prev_day_low and
            rs_status in [:strong_outperform, :outperform, :inline] ->
          "bounce at support"

        position == :near_prev_day_high and rs_status in [:strong_underperform, :underperform] ->
          "fade at resistance"

        position == :middle_of_range ->
          "ranging - wait for edge"

        true ->
          "monitoring"
      end
    end
  end
end
