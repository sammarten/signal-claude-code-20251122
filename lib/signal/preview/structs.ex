defmodule Signal.Preview.MarketRegime do
  @moduledoc """
  Represents the current market regime for a symbol.

  Regimes:
  - :trending_up - Higher highs and higher lows
  - :trending_down - Lower highs and lower lows
  - :ranging - Price oscillating within a defined range
  - :breakout_pending - At range extremes, breakout imminent
  """

  @type regime :: :trending_up | :trending_down | :ranging | :breakout_pending
  @type trend_direction :: :up | :down | :neutral

  @type t :: %__MODULE__{
          symbol: String.t(),
          date: Date.t(),
          timeframe: String.t(),
          regime: regime(),
          range_high: Decimal.t() | nil,
          range_low: Decimal.t() | nil,
          range_duration_days: non_neg_integer() | nil,
          distance_from_ath_percent: Decimal.t() | nil,
          trend_direction: trend_direction() | nil,
          higher_lows_count: non_neg_integer(),
          lower_highs_count: non_neg_integer()
        }

  defstruct [
    :symbol,
    :date,
    :timeframe,
    :regime,
    :range_high,
    :range_low,
    :range_duration_days,
    :distance_from_ath_percent,
    :trend_direction,
    higher_lows_count: 0,
    lower_highs_count: 0
  ]
end

defmodule Signal.Preview.IndexDivergence do
  @moduledoc """
  Represents divergence analysis between major indices (SPY, QQQ, DIA).

  Used to identify which index is leading/lagging and market implications.
  """

  @type index_status :: :leading | :lagging | :neutral

  @type t :: %__MODULE__{
          date: Date.t(),
          spy_status: index_status(),
          qqq_status: index_status(),
          dia_status: index_status(),
          spy_1d_pct: Decimal.t(),
          qqq_1d_pct: Decimal.t(),
          dia_1d_pct: Decimal.t(),
          spy_5d_pct: Decimal.t(),
          qqq_5d_pct: Decimal.t(),
          dia_5d_pct: Decimal.t(),
          spy_from_ath_pct: Decimal.t(),
          qqq_from_ath_pct: Decimal.t(),
          dia_from_ath_pct: Decimal.t(),
          leader: String.t(),
          laggard: String.t(),
          implication: String.t()
        }

  defstruct [
    :date,
    :spy_status,
    :qqq_status,
    :dia_status,
    :spy_1d_pct,
    :qqq_1d_pct,
    :dia_1d_pct,
    :spy_5d_pct,
    :qqq_5d_pct,
    :dia_5d_pct,
    :spy_from_ath_pct,
    :qqq_from_ath_pct,
    :dia_from_ath_pct,
    :leader,
    :laggard,
    :implication
  ]
end

defmodule Signal.Preview.RelativeStrength do
  @moduledoc """
  Represents relative strength of a symbol vs benchmark.

  Status levels:
  - :strong_outperform - RS > 3%
  - :outperform - RS between 1% and 3%
  - :inline - RS between -1% and 1%
  - :underperform - RS between -3% and -1%
  - :strong_underperform - RS < -3%
  """

  @type status ::
          :strong_outperform
          | :outperform
          | :inline
          | :underperform
          | :strong_underperform

  @type t :: %__MODULE__{
          symbol: String.t(),
          date: Date.t(),
          benchmark: String.t(),
          rs_1d: Decimal.t(),
          rs_5d: Decimal.t(),
          rs_20d: Decimal.t(),
          status: status()
        }

  defstruct [
    :symbol,
    :date,
    :benchmark,
    :rs_1d,
    :rs_5d,
    :rs_20d,
    :status
  ]
end

defmodule Signal.Preview.PremarketSnapshot do
  @moduledoc """
  Represents premarket position and gap analysis for a symbol.
  """

  @type gap_direction :: :up | :down | :flat

  @type range_position ::
          :above_prev_day_high
          | :near_prev_day_high
          | :middle_of_range
          | :near_prev_day_low
          | :below_prev_day_low

  @type t :: %__MODULE__{
          symbol: String.t(),
          timestamp: DateTime.t(),
          current_price: Decimal.t(),
          previous_close: Decimal.t(),
          gap_percent: Decimal.t(),
          gap_direction: gap_direction(),
          premarket_high: Decimal.t() | nil,
          premarket_low: Decimal.t() | nil,
          premarket_volume: non_neg_integer() | nil,
          position_in_range: range_position()
        }

  defstruct [
    :symbol,
    :timestamp,
    :current_price,
    :previous_close,
    :gap_percent,
    :gap_direction,
    :premarket_high,
    :premarket_low,
    :premarket_volume,
    :position_in_range
  ]
end

defmodule Signal.Preview.Scenario do
  @moduledoc """
  Represents a potential trading scenario for the day.
  """

  @type scenario_type :: :bullish | :bearish | :bounce | :fade

  @type t :: %__MODULE__{
          type: scenario_type(),
          trigger_level: Decimal.t(),
          trigger_condition: String.t(),
          target_level: Decimal.t(),
          description: String.t()
        }

  defstruct [
    :type,
    :trigger_level,
    :trigger_condition,
    :target_level,
    :description
  ]
end

defmodule Signal.Preview.WatchlistItem do
  @moduledoc """
  Represents a symbol on the watchlist with setup details.
  """

  @type bias :: :long | :short | :neutral
  @type conviction :: :high | :medium | :low

  @type t :: %__MODULE__{
          symbol: String.t(),
          setup: String.t(),
          key_level: Decimal.t(),
          bias: bias(),
          conviction: conviction(),
          notes: String.t() | nil
        }

  defstruct [
    :symbol,
    :setup,
    :key_level,
    :bias,
    :conviction,
    :notes
  ]
end

defmodule Signal.Preview.DailyPreview do
  @moduledoc """
  The complete daily market preview containing all analysis components.
  """

  @type stance :: :aggressive | :normal | :cautious | :hands_off
  @type position_size :: :full | :half | :quarter
  @type expected_volatility :: :high | :normal | :low

  @type t :: %__MODULE__{
          date: Date.t(),
          generated_at: DateTime.t(),
          market_context: String.t() | nil,
          key_events: [String.t()],
          expected_volatility: expected_volatility(),
          index_divergence: Signal.Preview.IndexDivergence.t() | nil,
          spy_regime: Signal.Preview.MarketRegime.t() | nil,
          qqq_regime: Signal.Preview.MarketRegime.t() | nil,
          spy_scenarios: [Signal.Preview.Scenario.t()],
          qqq_scenarios: [Signal.Preview.Scenario.t()],
          high_conviction: [Signal.Preview.WatchlistItem.t()],
          monitoring: [Signal.Preview.WatchlistItem.t()],
          avoid: [Signal.Preview.WatchlistItem.t()],
          relative_strength_leaders: [String.t()],
          relative_strength_laggards: [String.t()],
          stance: stance(),
          position_size: position_size(),
          focus: String.t() | nil,
          risk_notes: [String.t()]
        }

  defstruct [
    :date,
    :generated_at,
    :market_context,
    :index_divergence,
    :spy_regime,
    :qqq_regime,
    :focus,
    key_events: [],
    expected_volatility: :normal,
    spy_scenarios: [],
    qqq_scenarios: [],
    high_conviction: [],
    monitoring: [],
    avoid: [],
    relative_strength_leaders: [],
    relative_strength_laggards: [],
    stance: :normal,
    position_size: :full,
    risk_notes: []
  ]
end
