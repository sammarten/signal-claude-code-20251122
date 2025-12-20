defmodule Signal.Preview.ScenarioGenerator do
  @moduledoc """
  Generates trading scenarios based on market regime and key levels.

  Scenario types:
  - **bullish**: Break above resistance, continuation higher
  - **bearish**: Break below support, continuation lower
  - **bounce**: Hold support, rally higher
  - **fade**: Reject resistance, pullback lower

  ## Usage

      scenarios = ScenarioGenerator.generate(key_levels, regime, premarket)
      # => [
      #   %Scenario{type: :bullish, trigger_level: 690.00, ...},
      #   %Scenario{type: :bearish, trigger_level: 685.00, ...}
      # ]
  """

  alias Signal.Technicals.KeyLevels
  alias Signal.Preview.{MarketRegime, PremarketSnapshot, Scenario}

  @doc """
  Generates scenarios based on regime, levels, and premarket position.

  ## Parameters

    * `key_levels` - KeyLevels struct with support/resistance levels
    * `regime` - MarketRegime struct with current regime
    * `premarket` - PremarketSnapshot struct with current position

  ## Returns

  List of Scenario structs (typically 2-4 scenarios).
  """
  @spec generate(KeyLevels.t(), MarketRegime.t(), PremarketSnapshot.t()) :: [Scenario.t()]
  def generate(key_levels, regime, premarket) do
    scenarios = generate_for_regime(key_levels, regime, premarket)
    Enum.take(scenarios, 4)
  end

  @doc """
  Generates scenarios based on regime only (without premarket data).

  Useful for backtesting or when premarket data is unavailable.

  ## Parameters

    * `key_levels` - KeyLevels struct
    * `regime` - MarketRegime struct

  ## Returns

  List of Scenario structs.
  """
  @spec generate_without_premarket(KeyLevels.t(), MarketRegime.t()) :: [Scenario.t()]
  def generate_without_premarket(key_levels, regime) do
    current_price = key_levels.previous_day_close || key_levels.previous_day_low
    generate_for_regime(key_levels, regime, %{current_price: current_price})
  end

  # Private Functions

  defp generate_for_regime(levels, %MarketRegime{regime: :ranging} = regime, premarket) do
    current = Map.get(premarket, :current_price) || levels.previous_day_close

    range_high = regime.range_high || levels.last_week_high
    range_low = regime.range_low || levels.last_week_low
    equilibrium = levels.equilibrium || calculate_midpoint(range_high, range_low)

    scenarios = []

    # Bounce scenario (if near support)
    scenarios =
      if near_level?(current, range_low, Decimal.new("0.01")) do
        [
          %Scenario{
            type: :bounce,
            trigger_level: range_low,
            trigger_condition: "hold above",
            target_level: equilibrium,
            description:
              "Bounce off #{format_price(range_low)}, target equilibrium #{format_price(equilibrium)}"
          }
          | scenarios
        ]
      else
        scenarios
      end

    # Fade scenario (if near resistance)
    scenarios =
      if near_level?(current, range_high, Decimal.new("0.01")) do
        [
          %Scenario{
            type: :fade,
            trigger_level: range_high,
            trigger_condition: "reject at",
            target_level: equilibrium,
            description:
              "Rejection at #{format_price(range_high)}, fade to #{format_price(equilibrium)}"
          }
          | scenarios
        ]
      else
        scenarios
      end

    # Breakout scenarios (always include these for ranging)
    ath = levels.all_time_high || Decimal.mult(range_high, Decimal.new("1.02"))
    breakdown_target = Decimal.mult(range_low, Decimal.new("0.98"))

    scenarios = [
      %Scenario{
        type: :bullish,
        trigger_level: range_high,
        trigger_condition: "break above and hold",
        target_level: ath,
        description: "Break above #{format_price(range_high)}, hold for push toward ATH"
      },
      %Scenario{
        type: :bearish,
        trigger_level: range_low,
        trigger_condition: "break below",
        target_level: breakdown_target,
        description: "Break below #{format_price(range_low)}, continuation lower"
      }
      | scenarios
    ]

    Enum.reverse(scenarios)
  end

  defp generate_for_regime(levels, %MarketRegime{regime: :trending_up}, _premarket) do
    pdh = levels.previous_day_high
    pdl = levels.previous_day_low
    ath = levels.all_time_high || Decimal.mult(pdh, Decimal.new("1.02"))

    [
      # Pullback buy scenario
      %Scenario{
        type: :bounce,
        trigger_level: pdl,
        trigger_condition: "dip to and hold",
        target_level: pdh,
        description: "Buy the dip at #{format_price(pdl)}, target #{format_price(pdh)}"
      },
      # Continuation scenario
      %Scenario{
        type: :bullish,
        trigger_level: pdh,
        trigger_condition: "break above",
        target_level: ath,
        description: "Break above #{format_price(pdh)}, continuation toward ATH"
      },
      # Caution scenario
      %Scenario{
        type: :bearish,
        trigger_level: pdl,
        trigger_condition: "break below and hold",
        target_level: Decimal.mult(pdl, Decimal.new("0.98")),
        description: "Break below #{format_price(pdl)} with conviction signals trend pause"
      }
    ]
  end

  defp generate_for_regime(levels, %MarketRegime{regime: :trending_down}, _premarket) do
    pdh = levels.previous_day_high
    pdl = levels.previous_day_low

    [
      # Rally to short scenario
      %Scenario{
        type: :fade,
        trigger_level: pdh,
        trigger_condition: "rally to and reject",
        target_level: pdl,
        description: "Fade the rally at #{format_price(pdh)}, target #{format_price(pdl)}"
      },
      # Continuation scenario
      %Scenario{
        type: :bearish,
        trigger_level: pdl,
        trigger_condition: "break below",
        target_level: Decimal.mult(pdl, Decimal.new("0.98")),
        description: "Break below #{format_price(pdl)}, continuation lower"
      },
      # Reversal warning
      %Scenario{
        type: :bullish,
        trigger_level: pdh,
        trigger_condition: "break above and hold",
        target_level: Decimal.mult(pdh, Decimal.new("1.02")),
        description: "Break above #{format_price(pdh)} with conviction signals potential reversal"
      }
    ]
  end

  defp generate_for_regime(levels, %MarketRegime{regime: :breakout_pending} = regime, premarket) do
    # Similar to ranging but with more emphasis on breakout
    generate_for_regime(levels, %{regime | regime: :ranging}, premarket)
  end

  defp near_level?(price, level, threshold) when not is_nil(level) do
    pct_diff = Decimal.abs(Decimal.div(Decimal.sub(price, level), level))
    Decimal.compare(pct_diff, threshold) != :gt
  end

  defp near_level?(_, _, _), do: false

  defp calculate_midpoint(high, low) when not is_nil(high) and not is_nil(low) do
    Decimal.div(Decimal.add(high, low), 2)
  end

  defp calculate_midpoint(_, _), do: nil

  defp format_price(nil), do: "N/A"

  defp format_price(price) do
    price
    |> Decimal.round(2)
    |> Decimal.to_string()
  end
end
